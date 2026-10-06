import AVFoundation
import CoreMotion
import Foundation
import QuartzCore

/// Runs the chime natively so it keeps going in the background and with the screen
/// locked: physics on its own clock, motion from CoreMotion, sound from AVAudioEngine.
/// The app's "audio" background mode keeps the process alive while the engine plays.
/// All state lives on `queue`.
final class ChimeEngine {
    static let shared = ChimeEngine()

    private let queue = DispatchQueue(label: "com.jakedbirch.windchimes.engine", qos: .userInteractive)
    private let physics = ChimePhysics()
    private let synth = ChimeSynth(sampleRate: 48_000)
    private var audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let motion = CMMotionManager()
    private var physicsTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private var lastStepTime: UInt64 = 0
    private var accumulator = 0.0
    private var physicsOn = false
    private var resumeAfterInterruption = false // physics was on when another app took the audio

    // Shake control: each shake is one swing of the phone past ~0.9 g of its own
    // acceleration, and how hard it is sets the wind's strength. See detectShake.
    private var inShake = false
    private var shakePeak = 0.0
    private var lastShakeEnd = 0.0
    private var shakesInBurst = 0
    private var shakeStrength = 0.0     // 0–1, the page's Strength slider
    private var lastShakeAt = 0.0       // CACurrentMediaTime of the last shake, 0 if none
    private var windSoundEnvelope = 0.0
    private var source = "wind"
    private var sound = "metal" // "metal" | "recorded"
    private var voiceParams = SampleVoiceParams()
    private var userSample = SampleBank.loadTake() // the sample strikes play when sound == "recorded"
    private var takeUnsaved = SampleBank.loadTake() != nil

    // Recording: idle → standby (mic open, level meter) → armed (waiting for the
    // level to cross the threshold) → recording (until stopped or capped) → idle
    enum RecordState: String { case idle, standby, armed, recording }
    private(set) var recordState = RecordState.idle
    private var micLevel = -60.0          // dBFS meter: instant rise, steady fall, see handleInput
    private var triggerLevel = -30.0      // dBFS
    private var preRoll: [Float] = []     // last ~150 ms of input while armed
    private var recording: [Float] = []
    private var recordingSampleRate = 48_000.0
    private var recordingStart = 0.0
    private var recordCapTimer: DispatchSourceTimer?
    static let maxRecordSeconds = 10.0

    /// Called when a recording finishes on its own (cap reached), or fails.
    var onRecordingEvent: ((String, [String: Any]) -> Void)?

    enum RecordError: Error { case permissionDenied, noInput, busy, tooQuiet, notRecording }

    private init() {
        physics.onStrike = { [unowned self] strike in
            guard self.recordState == .idle else { return } // the mic has the room to itself
            let sample = self.sound == "recorded" ? self.userSample : nil
            self.synth.enqueue(ChimeVoices.make(for: strike, sample: sample, tuning: self.voiceParams, sampleRate: self.synth.sampleRate))
        }

        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            self.queue.async {
                switch type {
                case .began: self.interruptionBegan()
                case .ended: self.interruptionEnded(shouldResume: shouldResume)
                @unknown default: break
                }
            }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.restartAudioIfNeeded() }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.rebuildAudio() }
        }
    }

    // MARK: - Controls (callable from any thread)

    func updateParams(_ change: @escaping (inout ChimeParams) -> Void) {
        queue.async {
            var params = self.physics.params
            change(&params)
            self.physics.apply(params)
        }
    }

    func setPhysics(_ on: Bool) {
        queue.async { self.applyPhysics(on) }
    }

    /// Wind drives the chimes unless the phone hangs upside down (top edge toward the
    /// ground), which switches to the phone's own motion. Checked from the physics step.
    private var invertedSince: Double?
    private var uprightSince: Double?

    private func updateSourceFromOrientation(_ data: CMDeviceMotion) {
        let now = CACurrentMediaTime()
        // gravity.y is -1 upright in portrait and +1 inverted
        let inverted = data.gravity.y > 0.6
        let upright = data.gravity.y < 0.3
        invertedSince = inverted ? (invertedSince ?? now) : nil
        uprightSince = upright ? (uprightSince ?? now) : nil

        if source == "wind", let t = invertedSince, now - t > 1.0 {
            source = "phone"
            physics.selectMotion()
        } else if source == "phone", let t = uprightSince, now - t > 2.0 {
            source = "wind"
            physics.selectWind(physicsOn: physicsOn)
        }
    }

    func gust() {
        queue.async {
            self.physics.gust()
            if !self.physicsOn { self.applyPhysics(true) }
        }
    }

    func setVoiceParams(_ values: [String: Double]) {
        queue.async { self.voiceParams.apply(values) }
    }

    func setSound(_ mode: String) {
        queue.async {
            self.sound = (mode == "recorded" && self.userSample != nil) ? "recorded" : "metal"
        }
    }

    // MARK: - Sample bank

    func listSamples() -> [[String: Any]] {
        SampleBank.list().map { $0.info }
    }

    /// Saves the current sample (the last take, or a bank sample being renamed) under `name`.
    func saveSample(name: String, completion: @escaping ([String: Any]?) -> Void) {
        queue.async {
            guard var sample = self.userSample else { return completion(nil) }
            sample.name = name
            let meta = SampleBank.save(sample)
            self.userSample = sample
            self.takeUnsaved = false
            completion(meta.info)
        }
    }

    func selectSample(id: String, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard let sample = SampleBank.load(id: id) else { return completion(false) }
            self.userSample = sample
            self.takeUnsaved = false
            self.sound = "recorded"
            completion(true)
        }
    }

    func deleteSample(id: String) {
        queue.async {
            SampleBank.delete(id: id)
            // Keep playing it if it's the active one; it just isn't in the bank any more
            if self.userSample?.id == id { self.takeUnsaved = true }
        }
    }

    func snapshot() -> [String: Any] {
        queue.sync {
            var state = physics.snapshot()
            state["physicsOn"] = physicsOn
            state["source"] = source
            state["sound"] = sound
            state["recordState"] = recordState.rawValue
            state["micLevel"] = micLevel
            state["triggerLevel"] = triggerLevel
            state["recordSeconds"] = recordState == .recording ? CACurrentMediaTime() - recordingStart : 0
            state["motionAvailable"] = motion.isDeviceMotionAvailable
            state["windStrength"] = physics.params.windStrength
            state["lastShakeAgo"] = lastShakeAt > 0 ? CACurrentMediaTime() - lastShakeAt : -1
            if let sample = userSample {
                state["sample"] = sample.info
                state["takeUnsaved"] = takeUnsaved
            }
            return state
        }
    }

    // MARK: - Recording

    /// Opens the microphone and starts the level meter. Completion runs on an arbitrary queue.
    func startStandby(completion: @escaping (Error?) -> Void) {
        requestMicrophone { [self] granted in
            guard granted else { return completion(RecordError.permissionDenied) }
            queue.async {
                guard self.recordState == .idle else { return completion(nil) }
                do {
                    try self.openMicrophone()
                    self.recordState = .standby
                    completion(nil)
                } catch {
                    self.closeMicrophone()
                    completion(error)
                }
            }
        }
    }

    func setTriggerLevel(_ dB: Double) {
        queue.async { self.triggerLevel = min(0, max(-60, dB)) }
    }

    /// Recording begins the moment the input level crosses the trigger.
    func arm() {
        queue.async {
            guard self.recordState == .standby else { return }
            self.preRoll = []
            self.recordState = .armed
        }
    }

    func disarm() {
        queue.async {
            if self.recordState == .armed { self.recordState = .standby }
        }
    }

    /// Stops a recording in progress and turns it into the chime's voice.
    func stopRecording(completion: @escaping (Result<UserSample, Error>) -> Void) {
        queue.async { completion(self.finishRecording()) }
    }

    /// Leaves standby, armed or recording without keeping anything.
    func cancelRecording() {
        queue.async { self.closeMicrophone() }
    }

    private func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { completion($0) }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { completion($0) }
        }
    }

    private func openMicrophone() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        // Small input buffers so the level meter and the trigger see the sound promptly
        try? session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)

        // Nothing else sounds while the mic is open: no chimes, no wind
        synth.muted = true

        // A fresh engine, because an engine that has used its input node can't run
        // again on a playback-only session later
        replaceEngine()
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecordError.noInput }
        recordingSampleRate = format.sampleRate
        micLevel = -60
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            self.queue.async { self.handleInput(chunk) }
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    /// The meter is measured in 5 ms blocks: it jumps up to the loudest block in the
    /// chunk and falls back at a steady 40 dB/s, so it reads the same whether iOS
    /// delivers the input in 10 ms or 100 ms pieces. The trigger looks at the loudest
    /// block too, so a short transient fires it.
    private func handleInput(_ chunk: [Float]) {
        let block = max(1, Int(recordingSampleRate * 0.005))
        var loudest = -60.0
        var start = 0
        while start < chunk.count {
            let end = min(chunk.count, start + block)
            var sum = 0.0
            for i in start..<end { sum += Double(chunk[i] * chunk[i]) }
            let rms = (sum / Double(end - start)).squareRoot()
            loudest = max(loudest, 20 * log10(max(rms, 1e-6)))
            start = end
        }
        loudest = min(0, loudest)
        let elapsed = Double(chunk.count) / recordingSampleRate
        micLevel = max(loudest, max(-60, micLevel - 40 * elapsed))

        switch recordState {
        case .armed:
            preRoll.append(contentsOf: chunk)
            let keep = Int(recordingSampleRate * 0.15)
            if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
            if loudest >= triggerLevel {
                recording = preRoll
                recording.reserveCapacity(Int(recordingSampleRate * Self.maxRecordSeconds) + chunk.count)
                preRoll = []
                recordState = .recording
                recordingStart = CACurrentMediaTime()
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + Self.maxRecordSeconds)
                timer.setEventHandler { [weak self] in
                    guard let self, self.recordState == .recording else { return }
                    switch self.finishRecording() {
                    case .success(let sample):
                        self.onRecordingEvent?("recordingFinished", sample.info)
                    case .failure:
                        self.onRecordingEvent?("recordingFailed", ["code": "tooQuiet"])
                    }
                }
                timer.resume()
                recordCapTimer = timer
            }
        case .recording:
            recording.append(contentsOf: chunk)
        default:
            break
        }
    }

    private func finishRecording() -> Result<UserSample, Error> {
        guard recordState == .recording else { return .failure(RecordError.notRecording) }
        let raw = recording
        closeMicrophone()
        do {
            let sample = try UserSample.prepare(raw, sampleRate: recordingSampleRate)
            SampleBank.saveTake(sample)
            userSample = sample
            takeUnsaved = true
            sound = "recorded"
            return .success(sample)
        } catch {
            return .failure(RecordError.tooQuiet)
        }
    }

    /// Closes the mic, returns the session to playback-only and rebuilds the engine
    /// so chimes keep sounding afterwards.
    private func closeMicrophone() {
        recordCapTimer?.cancel()
        recordCapTimer = nil
        if recordState != .idle { audioEngine.inputNode.removeTap(onBus: 0) }
        recordState = .idle
        recording = []
        preRoll = []
        micLevel = -60
        audioEngine.stop()
        synth.muted = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        replaceEngine()
        restartAudioIfNeeded()
    }

    // MARK: - Interruptions

    /// Another app (a call, music, a video) has taken the audio. A recording in progress
    /// is lost, and the chimes stop; physics turns off so the app reads as paused and
    /// can go idle, remembering whether to come back.
    private func interruptionBegan() {
        if recordState != .idle {
            closeMicrophone()
            onRecordingEvent?("recordingFailed", ["code": "interrupted"])
        }
        resumeAfterInterruption = physicsOn
        if physicsOn { applyPhysics(false) }
        idleTimer?.cancel()
        idleTimer = nil
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// iOS says to resume after a transient interruption such as a call. When another
    /// app simply kept the audio, it doesn't, and the chimes stay off until tapped.
    private func interruptionEnded(shouldResume: Bool) {
        let resume = resumeAfterInterruption
        resumeAfterInterruption = false
        guard shouldResume else { return }
        if resume { applyPhysics(true) } else { restartAudioIfNeeded() }
    }

    // MARK: - Physics

    private func applyPhysics(_ on: Bool) {
        physicsOn = on
        if on {
            idleTimer?.cancel()
            idleTimer = nil
            if source == "wind" { physics.startWind(resetState: true) }
            startMotion() // for motion drive and to notice the phone being flipped
            startAudio()
            startPhysicsTimer()
        } else {
            stopPhysicsTimer()
            physics.stopWind()
            windSoundEnvelope = 0
            synth.windLevel = 0
            stopMotion()
            stopAudioWhenIdle()
        }
    }

    private func startPhysicsTimer() {
        guard physicsTimer == nil else { return }
        lastStepTime = DispatchTime.now().uptimeNanoseconds
        accumulator = 0
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 120), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.step() }
        timer.resume()
        physicsTimer = timer
    }

    private func stopPhysicsTimer() {
        physicsTimer?.cancel()
        physicsTimer = nil
    }

    /// Fixed-step physics driven by elapsed time, so it stays real-time even if
    /// the timer fires late (capped at 100 ms of catch-up).
    private func step() {
        let now = DispatchTime.now().uptimeNanoseconds
        accumulator = min(accumulator + Double(now &- lastStepTime) / 1e9, 0.1)
        lastStepTime = now

        if let data = motion.deviceMotion {
            updateSourceFromOrientation(data)
            if physics.params.shakeControl && source == "wind" { detectShake(data.userAcceleration) }
            if physics.motionOn {
                // Same units and axes as the web's accelerationIncludingGravity on iOS
                physics.motionRawX = (data.gravity.x + data.userAcceleration.x) * ChimePhysics.g
                physics.motionRawY = (data.gravity.y + data.userAcceleration.y) * ChimePhysics.g
            }
        }

        while accumulator >= ChimePhysics.dt {
            physics.tick()
            accumulator -= ChimePhysics.dt
        }
        synth.windSoundGain = physics.params.windSoundGain
        synth.windTightness = physics.params.windTightness
        // The audible wind follows an envelope of the wind vector. Tightness sets how
        // closely: smooth (0.7 s up, 2 s down, turbulence averaged out) to almost direct
        // (50 ms up, 250 ms down, every jiggle the chimes feel).
        // The sound follows the mean wind (gusts, sub-gusts, drops); tightness blends in
        // the turbulence the chimes feel on top of it
        let t = physics.params.windTightness
        let vector = physics.windOn ? (physics.windX * physics.windX + physics.windY * physics.windY).squareRoot() : 0
        let magnitude = physics.windOn ? physics.windSurge + t * max(0, vector - physics.windSurge) : 0
        let tau = magnitude > windSoundEnvelope ? 0.7 + (0.05 - 0.7) * t : 2.0 + (0.25 - 2.0) * t
        windSoundEnvelope += (magnitude - windSoundEnvelope) * (1 - exp(-ChimePhysics.dt / tau))
        synth.windLevel = windSoundEnvelope
    }

    // MARK: - Shake control

    /// A shake begins when the phone's own acceleration passes 0.9 g and ends when it
    /// drops under 0.4 g. Its peak sets Strength: 1 g is a light shake, 3 g a hard one.
    /// Within a burst of shakes the value settles toward the burst's average, so one
    /// odd shake doesn't throw it; a burst ends after a second of stillness.
    private func detectShake(_ a: CMAcceleration) {
        let g = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        let now = CACurrentMediaTime()
        if inShake {
            shakePeak = max(shakePeak, g)
            guard g < 0.4 else { return }
            inShake = false
            let gap = now - lastShakeEnd
            lastShakeEnd = now
            shakesInBurst = gap < 1.0 ? shakesInBurst + 1 : 1
            let blend = shakesInBurst == 1 ? 1.0 : 2.0 / Double(shakesInBurst + 1)

            let strength = min(1, max(0, (shakePeak - 0.8) / 2.2))
            shakeStrength = shakesInBurst == 1 ? strength : shakeStrength + (strength - shakeStrength) * blend
            lastShakeAt = now

            var params = physics.params
            params.windStrength = 0.10 + shakeStrength * 0.40 // the page's Strength mapping
            physics.apply(params)
        } else if g > 0.9 {
            inShake = true
            shakePeak = g
        }
    }

    // MARK: - Motion

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical)
    }

    private func stopMotion() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }

    // MARK: - Audio

    private func startAudio() {
        if recordState == .idle {
            do {
                // .playback ignores the silent switch and keeps playing when locked.
                // No mixing: starting the chimes pauses whatever else was playing, and
                // another app starting playback interrupts the chimes.
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
            } catch {
                NSLog("Pocket Chimes: audio session error: \(error)")
            }
        }
        attachSourceNode()
        if !audioEngine.isRunning {
            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                NSLog("Pocket Chimes: audio engine failed to start: \(error)")
            }
        }
    }

    private func attachSourceNode() {
        guard sourceNode == nil else { return }
        let synth = self.synth
        guard let format = AVAudioFormat(standardFormatWithSampleRate: synth.sampleRate, channels: 2) else { return }
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            synth.render(frameCount: Int(frameCount), buffers: UnsafeMutableAudioBufferListPointer(bufferList))
            return noErr
        }
        audioEngine.attach(node)
        audioEngine.connect(node, to: audioEngine.mainMixerNode, format: format)
        sourceNode = node
    }

    /// Throws the engine away and builds a new one with the synth attached, stopped.
    private func replaceEngine() {
        audioEngine.stop()
        if let node = sourceNode { audioEngine.detach(node) }
        sourceNode = nil
        audioEngine = AVAudioEngine()
        attachSourceNode()
    }

    private func restartAudioIfNeeded() {
        if physicsOn || synth.isActive || recordState != .idle { startAudio() }
    }

    /// Media services reset: the engine is gone. A recording in progress is lost.
    private func rebuildAudio() {
        if recordState != .idle {
            closeMicrophone()
            onRecordingEvent?("recordingFailed", ["code": "interrupted"])
        } else {
            replaceEngine()
            restartAudioIfNeeded()
        }
    }

    /// After physics stops, let the last notes ring out, then stop the engine so
    /// the app can suspend and stop using battery.
    private func stopAudioWhenIdle() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.physicsOn || !self.synth.isActive {
                if !self.physicsOn {
                    self.audioEngine.stop()
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
                self.idleTimer?.cancel()
                self.idleTimer = nil
            }
        }
        timer.resume()
        idleTimer = timer
    }
}
