import AVFoundation
import os

/// A parameter curve with the same semantics as a Web Audio AudioParam
/// (setValueAtTime, linear/exponential ramps, setTargetAtTime), so the
/// envelopes from the original web version carry over exactly.
/// Times are seconds relative to the strike.
struct Automation {
    enum Kind { case set, linear, exponential, target(timeConstant: Double) }

    struct Event {
        let kind: Kind
        let time: Double
        let value: Double
        let startValue: Double // curve value where a setTarget begins
    }

    let defaultValue: Double
    private var events: [Event] = []
    private var cursor = 0 // number of events at or before the last queried time

    init(_ defaultValue: Double) { self.defaultValue = defaultValue }

    mutating func setValue(_ value: Double, at time: Double) { add(.set, value, time) }
    mutating func linearRamp(to value: Double, at time: Double) { add(.linear, value, time) }
    mutating func exponentialRamp(to value: Double, at time: Double) { add(.exponential, value, time) }
    mutating func setTarget(_ value: Double, startingAt time: Double, timeConstant: Double) {
        add(.target(timeConstant: timeConstant), value, time)
    }

    /// Value at `time`. Queries must not go backwards in time.
    mutating func value(at time: Double) -> Double {
        while cursor < events.count && events[cursor].time <= time { cursor += 1 }
        return Automation.evaluate(events, cursor - 1, defaultValue, time)
    }

    private mutating func add(_ kind: Kind, _ value: Double, _ time: Double) {
        var k = events.count - 1
        while k >= 0 && events[k].time > time { k -= 1 }
        let start = Automation.evaluate(events, k, defaultValue, time)
        events.append(Event(kind: kind, time: time, value: value, startValue: start))
    }

    private static func level(_ e: Event) -> Double {
        if case .target = e.kind { return e.startValue }
        return e.value
    }

    /// `k` is the index of the last event at or before `time`, or -1.
    private static func evaluate(_ events: [Event], _ k: Int, _ defaultValue: Double, _ time: Double) -> Double {
        if k + 1 < events.count {
            let next = events[k + 1]
            let t0 = k >= 0 ? events[k].time : 0
            let v0 = k >= 0 ? level(events[k]) : defaultValue
            switch next.kind {
            case .linear:
                if next.time <= t0 { return next.value }
                return v0 + (next.value - v0) * (time - t0) / (next.time - t0)
            case .exponential:
                if next.time <= t0 { return next.value }
                if v0 == 0 || (v0 > 0) != (next.value > 0) { return v0 }
                return v0 * pow(next.value / v0, (time - t0) / (next.time - t0))
            default:
                break
            }
        }
        if k < 0 { return defaultValue }
        let e = events[k]
        if case .target(let tc) = e.kind {
            if tc <= 0 { return e.value }
            return e.value + (e.startValue - e.value) * exp(-(time - e.time) / tc)
        }
        return e.value
    }
}

/// Biquad matching the Web Audio BiquadFilterNode formulas
/// (lowpass Q is in dB, bandpass Q is linear).
struct Biquad {
    enum Kind { case lowpass, bandpass }

    let kind: Kind
    let q: Double
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    private var lastFrequency = -1.0

    init(_ kind: Kind, q: Double) {
        self.kind = kind
        self.q = q
    }

    mutating func setFrequency(_ frequency: Double, sampleRate: Double) {
        if frequency == lastFrequency { return }
        lastFrequency = frequency
        let nyquist = sampleRate / 2
        let f = min(max(frequency, 0), nyquist)
        if f <= 0 {
            b0 = 0; b1 = 0; b2 = 0; a1 = 0; a2 = 0
            return
        }
        if f >= nyquist {
            b0 = kind == .lowpass ? 1 : 0; b1 = 0; b2 = 0; a1 = 0; a2 = 0
            return
        }
        let w0 = 2 * Double.pi * f / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha: Double
        switch kind {
        case .lowpass: alpha = sw / (2 * pow(10, q / 20))
        case .bandpass: alpha = sw / (2 * max(q, 0.0001))
        }
        let a0 = 1 + alpha
        switch kind {
        case .lowpass:
            b0 = (1 - cw) / 2 / a0
            b1 = (1 - cw) / a0
            b2 = b0
        case .bandpass:
            b0 = alpha / a0
            b1 = 0
            b2 = -alpha / a0
        }
        a1 = -2 * cw / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

/// One component of a strike: a sine, or a looped recorded sample, through a lowpass
/// sweep and a gain envelope. Built on the engine queue, then rendered on the audio thread.
final class SynthVoice {
    static let blockSize = 32 // envelopes and filter sweeps update every 32 samples

    var startTime = 0.0
    var stopTime = 0.0
    var frequency = Automation(440)
    var sample: [Float]?     // when set, replaces the sine
    var sampleStep = 1.0     // source samples advanced per output sample (pitch shift)
    var pitchBend = Automation(1) // multiplier on sampleStep, for a settling bend after the hit
    var filter: Biquad?
    var filterFrequency: Automation? // nil = cutoff fixed when the voice was built
    var gain = Automation(1)

    private var time = 0.0
    private var phase = 0.0
    private var samplePos = 0.0

    /// Adds this voice into `out`. Returns false once the voice has finished.
    func render(into out: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Double) -> Bool {
        let invSr = 1.0 / sampleRate
        let w = 2.0 * Double.pi * invSr
        let hasFilter = filter != nil
        let sweepsFilter = filterFrequency != nil
        var flt = filter ?? Biquad(.lowpass, q: 0)
        let sampleBuf = sample ?? []
        let sampleCount = sampleBuf.count
        let isSample = sampleCount > 1

        var offset = 0
        while offset < frames {
            let n = min(SynthVoice.blockSize, frames - offset)
            let t0 = time
            let t1 = t0 + Double(n) * invSr
            time = t1
            if t1 <= startTime { offset += n; continue }
            if t0 >= stopTime { break }

            // Interpolate control values across the audible part of this block
            let ta = max(t0, startTime)
            let invSpan = t1 > ta ? 1.0 / (t1 - ta) : 0
            let g0 = gain.value(at: ta), gD = gain.value(at: t1) - g0
            let f0 = frequency.value(at: ta), fD = frequency.value(at: t1) - f0
            if sweepsFilter { flt.setFrequency(filterFrequency!.value(at: ta), sampleRate: sampleRate) }
            let step = isSample ? sampleStep * pitchBend.value(at: ta) : 0

            for k in 0..<n {
                let ts = t0 + Double(k) * invSr
                if ts < startTime { continue }
                if ts >= stopTime { break }
                let frac = (ts - ta) * invSpan
                let x: Double
                if isSample {
                    // Linear interpolation through the loop
                    let i0 = Int(samplePos)
                    let i1 = i0 + 1 < sampleCount ? i0 + 1 : 0
                    let t = samplePos - Double(i0)
                    x = Double(sampleBuf[i0]) * (1 - t) + Double(sampleBuf[i1]) * t
                    samplePos += step
                    if samplePos >= Double(sampleCount) { samplePos -= Double(sampleCount) }
                } else {
                    x = sin(phase)
                    phase += w * (f0 + fD * frac)
                }
                let y = hasFilter ? flt.process(x) : x
                out[offset + k] += Float(y * (g0 + gD * frac))
            }
            offset += n
        }

        if hasFilter { filter = flt }
        phase = phase.truncatingRemainder(dividingBy: 2.0 * Double.pi)
        return time < stopTime
    }
}

/// Mixes strike voices on the audio thread. Voices are built elsewhere and handed
/// over through `enqueue`; the render thread only ever try-locks, so it never blocks.
final class ChimeSynth {
    let sampleRate: Double
    private let masterGain: Float = 0.9

    /// Wind sound: a bed of brown-noise rumble, a pink-noise mid layer that brightens on
    /// gust fronts, and three slowly wandering resonant "whoosh" bands, all breathing with
    /// a slow random flutter. `windLevel` is written from the physics step
    /// (0 = calm, ~0.45 = strong gust); `windSoundGain` is the slider, 0 = off.
    var windLevel = 0.0
    var windSoundGain = 0.1
    var windTightness = 0.6 // see ChimeParams.windTightness
    private var windSmoothed = 0.0
    private var windFront = 0.0
    private var noiseState: UInt32 = 0x1234_5678
    private var brown = 0.0, dcIn = 0.0, dcOut = 0.0
    private var pink0 = 0.0, pink1 = 0.0, pink2 = 0.0
    private var rumbleLP = Biquad(.lowpass, q: 3), rumbleLP2 = Biquad(.lowpass, q: 0)
    private var bodyLP = Biquad(.lowpass, q: 1)
    private struct WhooshBand {
        var base: Double
        var filter = Biquad(.bandpass, q: 6)
        var wander = 1.0, wanderTarget = 1.0
        var level = 0.7, levelTarget = 0.7
    }
    private var bands = [WhooshBand(base: 150), WhooshBand(base: 260), WhooshBand(base: 420)]
    private var flutter = 1.0, flutterTarget = 1.0
    private var bodyDrift = 1.0, bodyDriftTarget = 1.0
    private var compEnvelope = 0.0, compGain = 1.0 // gentle compressor evens out the surges

    private static let maxVoices = 384

    /// While the microphone is open nothing else may sound: the output is silence and
    /// every voice, ringing or waiting, is dropped so nothing bursts out afterwards.
    var muted = false

    private var voices: [SynthVoice] = []
    private var pending: [SynthVoice] = []
    private var incoming: [SynthVoice] = []
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var renderedVoiceCount = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        voices.reserveCapacity(512)
        pending.reserveCapacity(128)
        incoming.reserveCapacity(128)
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func enqueue(_ newVoices: [SynthVoice]) {
        os_unfair_lock_lock(lock)
        pending.append(contentsOf: newVoices)
        os_unfair_lock_unlock(lock)
    }

    /// True while anything is still sounding or waiting to sound.
    var isActive: Bool {
        os_unfair_lock_lock(lock)
        let hasPending = !pending.isEmpty
        os_unfair_lock_unlock(lock)
        return hasPending || renderedVoiceCount > 0
    }

    func render(frameCount: Int, buffers: UnsafeMutableAudioBufferListPointer) {
        guard buffers.count > 0, let raw = buffers[0].mData else { return }
        let out = raw.assumingMemoryBound(to: Float.self)
        out.update(repeating: 0, count: frameCount)

        if muted {
            if os_unfair_lock_trylock(lock) {
                pending.removeAll(keepingCapacity: true)
                os_unfair_lock_unlock(lock)
            }
            voices.removeAll(keepingCapacity: true)
            incoming.removeAll(keepingCapacity: true)
            renderedVoiceCount = 0
            windSmoothed = 0
            windFront = 0
            for b in 1..<max(1, buffers.count) {
                if let dst = buffers[b].mData {
                    dst.copyMemory(from: raw, byteCount: frameCount * MemoryLayout<Float>.size)
                }
            }
            return
        }

        if os_unfair_lock_trylock(lock) {
            if !pending.isEmpty { swap(&pending, &incoming) }
            os_unfair_lock_unlock(lock)
        }
        if !incoming.isEmpty {
            voices.append(contentsOf: incoming)
            incoming.removeAll(keepingCapacity: true)
            if voices.count > ChimeSynth.maxVoices {
                voices.removeFirst(voices.count - ChimeSynth.maxVoices)
            }
        }

        var i = 0
        while i < voices.count {
            if voices[i].render(into: out, frames: frameCount, sampleRate: sampleRate) {
                i += 1
            } else {
                voices.swapAt(i, voices.count - 1)
                voices.removeLast()
            }
        }
        renderedVoiceCount = voices.count

        renderWind(into: out, frames: frameCount)

        for j in 0..<frameCount {
            out[j] = max(-1, min(1, out[j] * masterGain))
        }
        for b in 1..<max(1, buffers.count) {
            if let dst = buffers[b].mData {
                dst.copyMemory(from: raw, byteCount: frameCount * MemoryLayout<Float>.size)
            }
        }
    }

    private func whiteNoise() -> Double {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 17
        noiseState ^= noiseState << 5
        return Double(noiseState) / Double(UInt32.max) * 2 - 1
    }

    /// Mixes the wind layer into `out`. Same DSP as the Node prototype used to audition it.
    private func renderWind(into out: UnsafeMutablePointer<Float>, frames: Int) {
        var target = windSoundGain > 0 ? min(1, max(0, windLevel / 0.45)) : 0
        // Expander: below ~0.12 the level falls away to true silence instead of idling as hiss
        let gate = min(1, max(0, (target - 0.03) / (0.14 - 0.03)))
        target *= gate * gate * (3 - 2 * gate)
        if target <= 0 && windSmoothed < 0.002 { windSmoothed = 0; return }
        let block = 64
        let blockD = Double(block)
        let tight = min(1, max(0, windTightness))
        let smoothUp = 1 - exp(-blockD / ((0.7 + (0.03 - 0.7) * tight) * sampleRate))   // the audible swell lags the gust...
        let smoothDown = 1 - exp(-blockD / ((2.0 + (0.15 - 2.0) * tight) * sampleRate)) // ...unless tightness says otherwise
        let frontDecay = exp(-blockD / (1.5 * sampleRate))
        let walk = 1 - exp(-blockD / (1.8 * sampleRate))       // ~1.8 s wander smoothing
        let brownCoef = 1 - exp(-2 * Double.pi * 70 / sampleRate) // brown corner ~70 Hz
        let dcCoef = 1 - exp(-2 * Double.pi * 55 / sampleRate)    // highpass ~55 Hz: below this a phone only pumps
        let master = 0.42 // pre-compressor level
        let compAttack = 1 - exp(-blockD / (0.01 * sampleRate))
        let compRelease = 1 - exp(-blockD / (0.25 * sampleRate))
        let compThreshold = 0.055, makeup = 2.0 // ≈ -25 dBFS RMS
        let compRatio = 5.0 + (1.3 - 5.0) * tight // 5:1 when smooth, nearly off when tight

        var offset = 0
        while offset < frames {
            let n = min(block, frames - offset)
            let before = windSmoothed
            windSmoothed += (target - windSmoothed) * (target > windSmoothed ? smoothUp : smoothDown)
            let w = windSmoothed
            // Rising wind brightens briefly: a gust front
            let rise = max(0, w - before) * sampleRate / blockD
            windFront = max(windFront * frontDecay, min(1, rise * 0.9))
            if w < 0.002 && target <= 0 { windSmoothed = 0; break }

            // Slow random walks, retargeted now and then
            if (whiteNoise() + 1) / 2 < blockD / (2.5 * sampleRate) { flutterTarget = 0.6 + (whiteNoise() + 1) / 2 * 0.4 } // slow breathing, ±2 dB
            flutter += (flutterTarget - flutter) * walk
            if (whiteNoise() + 1) / 2 < blockD / (3.0 * sampleRate) { bodyDriftTarget = 0.7 + (whiteNoise() + 1) / 2 * 0.6 } // colour drifts
            bodyDrift += (bodyDriftTarget - bodyDrift) * walk
            for i in bands.indices {
                if (whiteNoise() + 1) / 2 < blockD / (1.5 * sampleRate) {
                    bands[i].wanderTarget = 0.75 + (whiteNoise() + 1) / 2 * 0.5
                    bands[i].levelTarget = 0.15 + (whiteNoise() + 1) / 2 * 0.85
                }
                bands[i].wander += (bands[i].wanderTarget - bands[i].wander) * walk
                bands[i].level += (bands[i].levelTarget - bands[i].level) * walk
                bands[i].filter.setFrequency(bands[i].base * (0.9 + w * 1.4) * bands[i].wander, sampleRate: sampleRate)
            }
            rumbleLP.setFrequency(110 + w * 160, sampleRate: sampleRate)
            rumbleLP2.setFrequency(160 + w * 220, sampleRate: sampleRate)
            bodyLP.setFrequency((140 + w * 700) * bodyDrift + windFront * 350, sampleRate: sampleRate)

            let shape = pow(w, 1.3) * flutter
            let gRumble = shape * 1.0
            let gBody = shape * (0.25 + windFront * 0.25)
            let gWhoosh = pow(w, 1.6) * 0.5

            var blockSum = 0.0
            for k in 0..<n {
                let white = whiteNoise()
                // Brown: leaky integrator, DC-blocked
                brown += (white - brown) * brownCoef
                let dc = brown - dcIn + (1 - dcCoef) * dcOut
                dcIn = brown
                dcOut = dc
                let brownOut = dc * 6.0
                // Pink (Kellet economy)
                pink0 = 0.99765 * pink0 + white * 0.0990460
                pink1 = 0.96300 * pink1 + white * 0.2965164
                pink2 = 0.57000 * pink2 + white * 1.0526913
                let pink = (pink0 + pink1 + pink2 + white * 0.1848) * 0.25

                let rumble = rumbleLP2.process(rumbleLP.process(brownOut))
                let body = bodyLP.process(pink)
                var whoosh = 0.0
                for i in bands.indices { whoosh += bands[i].filter.process(pink) * bands[i].level }

                let y = (rumble * gRumble + body * gBody + whoosh * gWhoosh) * master * compGain
                blockSum += y * y
                // Soft clip tames what the compressor misses
                out[offset + k] += Float(tanh(y * makeup * 1.6) / 1.6 * windSoundGain)
            }
            // Detector on this block's level before gain, applied from the next block
            let rms = (blockSum / Double(n)).squareRoot() / max(compGain, 1e-6)
            compEnvelope += (rms - compEnvelope) * (rms > compEnvelope ? compAttack : compRelease)
            let over = compEnvelope / compThreshold
            let wanted = over > 1 ? pow(over, 1 / compRatio - 1) : 1
            compGain += (wanted - compGain) * (wanted < compGain ? compAttack : compRelease)
            offset += n
        }
    }
}
