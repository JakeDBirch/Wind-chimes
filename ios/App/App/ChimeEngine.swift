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

    /// The Wind switch. Off, the wind stops blowing but the world goes on: the chimes
    /// swing down and settle, strikes still ring, a gust still pushes, and hanging the
    /// phone still works. Once everything has settled the engine goes dormant to save
    /// battery, and wakes for a gust, the switch, or the phone being hung.
    private(set) var windEnabled = false
    func setWind(_ on: Bool) {
        queue.async {
            self.windEnabled = on
            if !on {
                self.sleepTimer?.cancel()
                self.sleepTimer = nil
                self.sleepAt = 0
            }
            if on && !self.physicsOn { self.applyPhysics(true); return }
            if !self.physicsOn { self.watchForHang(); return }
            if self.physicsOn && self.source == "wind" {
                if on { self.physics.startWind(resetState: false) } else { self.physics.stopWind() }
            }
        }
    }

    // Whenever the physics is stopped (never started, settled with the wind off, or put to
    // sleep) a slow watch on the motion sensor wakes the engine when the phone is turned
    // over, so hanging it works from any state.
    private var dormantWatch: DispatchSourceTimer?
    private var settledSince: Double?

    private func watchForHang() {
        guard dormantWatch == nil else { return }
        startMotion()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, let g = self.motion.deviceMotion?.gravity else { return }
            if g.y > 0.6 { self.applyPhysics(true) }
        }
        timer.resume()
        dormantWatch = timer
    }

    private func goDormant() {
        applyPhysics(false)
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
            phoneSince = now
            physics.selectMotion()
        } else if source == "phone", let t = uprightSince, now - t > 2.0 {
            source = "wind"
            longestPhoneSpell = max(longestPhoneSpell, now - phoneSince)
            physics.selectWind(physicsOn: physicsOn && windEnabled)
        }
    }

    // The longest unbroken spell spent hanging, in seconds. Kept here rather than on the
    // page so it still counts while the screen is locked in a tree.
    private var phoneSince = 0.0
    private var longestPhoneSpell = 0.0
    private var phoneSpell: Double {
        max(longestPhoneSpell, source == "phone" ? CACurrentMediaTime() - phoneSince : 0)
    }

    func gust() {
        queue.async {
            if !self.physicsOn { self.applyPhysics(true) }
            self.physics.gust()
        }
    }

    // MARK: - Sleep timer

    private var sleepTimer: DispatchSourceTimer?
    private var sleepAt = 0.0 // CACurrentMediaTime when the chimes go quiet, 0 if no timer

    /// Turns the chimes off after `seconds`; 0 cancels. Runs on the engine's own queue,
    /// so it fires with the screen locked, which the page's own timers would not.
    func setSleepTimer(seconds: Double) {
        queue.async {
            self.sleepTimer?.cancel()
            self.sleepTimer = nil
            self.sleepAt = 0
            guard seconds > 0 else { return }
            self.sleepAt = CACurrentMediaTime() + seconds
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + seconds)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.sleepTimer = nil
                self.sleepAt = 0
                self.setWind(false) // the chimes settle and the engine goes quiet on its own
            }
            timer.resume()
            self.sleepTimer = timer
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
            state["windOn"] = windEnabled
            state["sleepRemaining"] = sleepAt > 0 ? max(0, sleepAt - CACurrentMediaTime()) : -1
            state["source"] = source
            state["phoneSpell"] = phoneSpell
            state["sound"] = sound
            state["recordState"] = recordState.rawValue
            state["micLevel"] = micLevel
            state["triggerLevel"] = triggerLevel
            state["recordSeconds"] = recordState == .recording ? CACurrentMediaTime() - recordingStart : 0
            state["motionAvailable"] = motion.isDeviceMotionAvailable
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
        dormantWatch?.cancel()
        dormantWatch = nil
        settledSince = nil
        if on {
            idleTimer?.cancel()
            idleTimer = nil
            if source == "wind" && windEnabled { physics.startWind(resetState: true) }
            startMotion() // for motion drive and to notice the phone being flipped
            startAudio()
            startPhysicsTimer()
        } else {
            stopPhysicsTimer()
            physics.stopWind()
            windSoundEnvelope = 0
            synth.windLevel = 0
            stopAudioWhenIdle()
            watchForHang() // keeps the motion sensor running
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

        // With the wind off, once everything has been still for a few seconds, go quiet
        if !windEnabled && source == "wind" && physics.isSettled && !synth.isActive {
            let t = CACurrentMediaTime()
            if settledSince == nil { settledSince = t }
            if t - settledSince! > 3 { goDormant(); return }
        } else {
            settledSince = nil
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

    // MARK: - Motion

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical)
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
