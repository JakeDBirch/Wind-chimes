import AVFoundation
import CoreMotion
import Foundation

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
    private var source = "wind"

    private init() {
        let synth = self.synth
        physics.onStrike = { strike in
            synth.enqueue(ChimeVoices.make(for: strike, sampleRate: synth.sampleRate))
        }

        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.queue.async { self?.restartAudioIfNeeded() }
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

    func setSource(_ newSource: String) {
        queue.async {
            if newSource == "phone" {
                self.source = "phone"
                self.physics.selectMotion()
                if self.physicsOn { self.startMotion() } else { self.applyPhysics(true) }
            } else {
                self.source = "wind"
                self.stopMotion()
                self.physics.selectWind(physicsOn: self.physicsOn)
            }
        }
    }

    func gust() {
        queue.async {
            self.physics.gust()
            if !self.physicsOn { self.applyPhysics(true) }
        }
    }

    func snapshot() -> [String: Any] {
        queue.sync {
            var state = physics.snapshot()
            state["physicsOn"] = physicsOn
            state["source"] = source
            state["motionAvailable"] = motion.isDeviceMotionAvailable
            return state
        }
    }

    // MARK: - Physics

    private func applyPhysics(_ on: Bool) {
        physicsOn = on
        if on {
            idleTimer?.cancel()
            idleTimer = nil
            if source == "wind" { physics.startWind(resetState: true) } else { startMotion() }
            startAudio()
            startPhysicsTimer()
        } else {
            stopPhysicsTimer()
            physics.stopWind()
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

        if physics.motionOn, let data = motion.deviceMotion {
            // Same units and axes as the web's accelerationIncludingGravity on iOS
            physics.motionRawX = (data.gravity.x + data.userAcceleration.x) * ChimePhysics.g
            physics.motionRawY = (data.gravity.y + data.userAcceleration.y) * ChimePhysics.g
        }

        while accumulator >= ChimePhysics.dt {
            physics.tick()
            accumulator -= ChimePhysics.dt
        }
    }

    // MARK: - Motion

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates()
    }

    private func stopMotion() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }

    // MARK: - Audio

    private func startAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback ignores the silent switch and keeps playing when locked;
            // .mixWithOthers lets music or podcasts keep playing alongside.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            NSLog("Pocket Chimes: audio session error: \(error)")
        }

        if sourceNode == nil {
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

        if !audioEngine.isRunning {
            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                NSLog("Pocket Chimes: audio engine failed to start: \(error)")
            }
        }
    }

    private func restartAudioIfNeeded() {
        if physicsOn || synth.isActive { startAudio() }
    }

    private func rebuildAudio() {
        audioEngine.stop()
        if let node = sourceNode { audioEngine.detach(node) }
        sourceNode = nil
        audioEngine = AVAudioEngine()
        restartAudioIfNeeded()
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
