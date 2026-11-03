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
    var loopStart = 0        // after the end of `sample`, playback continues from here
    var pitchBend = Automation(1) // multiplier on sampleStep, for a settling bend after the hit
    var filter: Biquad?
    var filterFrequency: Automation? // nil = cutoff fixed when the voice was built
    var gain = Automation(1)
    /// Left-right position, -1 to +1. Constant-power gains, scaled so a centred voice
    /// is as loud in each channel as it was in mono.
    var pan = 0.0 {
        didSet {
            let th = (max(-1, min(1, pan)) + 1) * .pi / 4
            gainL = Float(2.0.squareRoot() * cos(th)); gainR = Float(2.0.squareRoot() * sin(th))
        }
    }
    private var gainL: Float = 1, gainR: Float = 1

    // Modal fast path: one mode of a struck tube, a damped sine that starts at full
    // amplitude the instant the strike lands and decays at `modalDecay` per second.
    // Rendered as a decaying complex rotation, four multiplies and two adds a sample.
    var modal = false
    var modalAmp = 0.0, modalFreq = 0.0, modalDecay = 0.0
    var modalRise = 0.0004   // seconds: a strike's contact lasts about this, so a mode rises over it rather than at once
    private var mre = 0.0, mim = 0.0, rotC = 0.0, rotS = 0.0, modalReady = false, riseLeft = 0, riseN = 1

    private var time = 0.0
    private var phase = 0.0
    private var samplePos = 0.0

    /// Adds this voice into the two channels. Returns false once the voice has finished.
    func render(into outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Double) -> Bool {
        let invSr = 1.0 / sampleRate
        let gL = gainL, gR = gainR
        if modal {
            if !modalReady {
                modalReady = true
                let g = exp(-modalDecay * invSr)
                let w = 2.0 * Double.pi * modalFreq * invSr
                rotC = cos(w) * g; rotS = sin(w) * g
                mre = modalAmp; mim = 0           // the sine starts from zero
                riseN = max(1, Int(modalRise * sampleRate)); riseLeft = riseN
            }
            let t0 = time
            time = t0 + Double(frames) * invSr
            let first = t0 < startTime ? min(frames, Int((startTime - t0) * sampleRate)) : 0
            var re = mre, im = mim
            let c = rotC, sn = rotS
            var left = riseLeft
            let n = Double(riseN)
            for k in first..<frames {
                let nre = re * c - im * sn
                im = re * sn + im * c
                re = nre
                if left > 0 {
                    // Raised-cosine rise over the contact time: no edge at the onset
                    let x = Double(riseN - left + 1) / n
                    let v = Float(im * 0.5 * (1 - cos(.pi * x)))
                    outL[k] += v * gL; outR[k] += v * gR
                    left -= 1
                } else {
                    let v = Float(im)
                    outL[k] += v * gL; outR[k] += v * gR
                }
            }
            riseLeft = left
            mre = re; mim = im
            return modalAmp * exp(-modalDecay * max(0, time - startTime)) > 2e-5
        }
        let w = 2.0 * Double.pi * invSr
        let hasFilter = filter != nil
        let sweepsFilter = filterFrequency != nil
        var flt = filter ?? Biquad(.lowpass, q: 0)
        let sampleBuf = sample ?? []
        let sampleCount = sampleBuf.count
        let isSample = sampleCount > 1
        let loopFrom = max(0, min(loopStart, sampleCount - 1))
        let loopLen = Double(sampleCount - loopFrom)

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
                    let i1 = i0 + 1 < sampleCount ? i0 + 1 : loopFrom
                    let t = samplePos - Double(i0)
                    x = Double(sampleBuf[i0]) * (1 - t) + Double(sampleBuf[i1]) * t
                    samplePos += step
                    if samplePos >= Double(sampleCount) { samplePos -= loopLen }
                } else {
                    x = sin(phase)
                    phase += w * (f0 + fD * frac)
                }
                let y = hasFilter ? flt.process(x) : x
                let v = Float(y * (g0 + gD * frac))
                outL[offset + k] += v * gL; outR[offset + k] += v * gR
            }
            offset += n
        }

        if hasFilter { filter = flt }
        phase = phase.truncatingRemainder(dividingBy: 2.0 * Double.pi)
        return time < stopTime
    }
}

/// A little outdoors around the chimes. Outside there is no hall, but there is a ground
/// bounce, a wall or two and the air, so the chimes get a handful of early reflections,
/// darkened as a wall and the ground darken a sound, and a short, dark tail: enough to
/// hang somewhere rather than in an anechoic chamber. On the chime bus only; the wind is
/// already diffuse. `amount` scales the whole thing, 1 as shipped, 0 dry.
final class OutdoorSpace {
    var amount: Float = 1

    private let mask = 4095
    private let bufL, bufR, l0, l1, l2, l3: UnsafeMutablePointer<Float>
    private var pos = 0
    private struct Tap { let delay: Int; let gain: Float; let cross: Bool }
    private let tapsL: [Tap], tapsR: [Tap]
    private let n0, n1, n2, n3: Int
    private let g0, g1, g2, g3: Float
    private let earlyCoef: Float, dampCoef: Float
    private let earlyLevel: Float = 0.7, tailLevel: Float = 0.3
    private var eL: Float = 0, eR: Float = 0
    private var d0: Float = 0, d1: Float = 0, d2: Float = 0, d3: Float = 0

    init(sampleRate sr: Double) {
        func alloc() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
            p.initialize(repeating: 0, count: 4096)
            return p
        }
        bufL = alloc(); bufR = alloc(); l0 = alloc(); l1 = alloc(); l2 = alloc(); l3 = alloc()
        func samples(_ ms: Double) -> Int { max(1, min(4095, Int(ms / 1000 * sr))) }
        // Milliseconds and gains of the reflections: the ground under the chimes first,
        // then a near wall, then something farther off. Each side hears the other's too
        tapsL = [Tap(delay: samples(9.1), gain: 0.28, cross: false), Tap(delay: samples(17.3), gain: 0.20, cross: false),
                 Tap(delay: samples(26.9), gain: 0.14, cross: false), Tap(delay: samples(43.7), gain: 0.09, cross: false),
                 Tap(delay: samples(13.7), gain: 0.16, cross: true), Tap(delay: samples(31.1), gain: 0.10, cross: true),
                 Tap(delay: samples(52.3), gain: 0.06, cross: true)]
        tapsR = [Tap(delay: samples(9.7), gain: 0.28, cross: false), Tap(delay: samples(18.9), gain: 0.20, cross: false),
                 Tap(delay: samples(25.1), gain: 0.14, cross: false), Tap(delay: samples(46.3), gain: 0.09, cross: false),
                 Tap(delay: samples(12.3), gain: 0.16, cross: true), Tap(delay: samples(33.7), gain: 0.10, cross: true),
                 Tap(delay: samples(49.9), gain: 0.06, cross: true)]
        // The tail: four delay lines fed back through a Householder mix, each damped,
        // dying away in about 0.8 s
        n0 = samples(31.7); n1 = samples(37.9); n2 = samples(43.1); n3 = samples(47.3)
        let rt60 = 0.8
        func fb(_ n: Int) -> Float { Float(pow(10.0, -3.0 * Double(n) / (rt60 * sr))) }
        g0 = fb(n0); g1 = fb(n1); g2 = fb(n2); g3 = fb(n3)
        earlyCoef = Float(1 - exp(-2 * Double.pi * 4500 / sr))
        dampCoef = Float(1 - exp(-2 * Double.pi * 3000 / sr))
    }

    deinit {
        for p in [bufL, bufR, l0, l1, l2, l3] { p.deallocate() }
    }

    func process(_ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, frames: Int) {
        let amt = amount
        if amt <= 0 { return }
        let mask = self.mask
        var pos = self.pos
        var eL = self.eL, eR = self.eR
        var d0 = self.d0, d1 = self.d1, d2 = self.d2, d3 = self.d3
        for k in 0..<frames {
            let inL = outL[k], inR = outR[k]
            bufL[pos] = inL; bufR[pos] = inR
            var sumL: Float = 0, sumR: Float = 0
            for t in tapsL { sumL += (t.cross ? bufR : bufL)[(pos - t.delay) & mask] * t.gain }
            for t in tapsR { sumR += (t.cross ? bufL : bufR)[(pos - t.delay) & mask] * t.gain }
            eL += (sumL - eL) * earlyCoef
            eR += (sumR - eR) * earlyCoef
            d0 += (l0[(pos - n0) & mask] - d0) * dampCoef
            d1 += (l1[(pos - n1) & mask] - d1) * dampCoef
            d2 += (l2[(pos - n2) & mask] - d2) * dampCoef
            d3 += (l3[(pos - n3) & mask] - d3) * dampCoef
            let s = (d0 + d1 + d2 + d3) * 0.5
            let injL = (inL + eL) * 0.25, injR = (inR + eR) * 0.25
            l0[pos] = (d0 - s) * g0 + injL
            l1[pos] = (d1 - s) * g1 + injR
            l2[pos] = (d2 - s) * g2 + injL
            l3[pos] = (d3 - s) * g3 + injR
            outL[k] = inL + amt * (eL * earlyLevel + (d0 + d2) * 0.5 * tailLevel)
            outR[k] = inR + amt * (eR * earlyLevel + (d1 + d3) * 0.5 * tailLevel)
            pos = (pos + 1) & mask
        }
        self.pos = pos
        self.eL = eL; self.eR = eR
        self.d0 = d0; self.d1 = d1; self.d2 = d2; self.d3 = d3
    }
}

/// Mixes strike voices on the audio thread. Voices are built elsewhere and handed
/// over through `enqueue`; the render thread only ever try-locks, so it never blocks.
final class ChimeSynth {
    let sampleRate: Double
    private let masterGain: Float = 0.9

    /// Makeup gain on the chimes (not the wind), ahead of a soft limiter. Left as it was,
    /// a day of ordinary wind sat around -40 dBFS RMS with peaks near -21, some 20 dB under
    /// a podcast; +21 dB with a limiter from 0.6 flattened the loud end, so this is +15 dB
    /// (5.6×) with the limiter linear up to 0.85, where only the hardest strikes and a
    /// gust's cluster are rounded off. Set from the Workshop's Output level.
    var outputGain: Float = 5.6
    /// The outdoors around the chimes; its `amount` is the Workshop's Space slider
    let space: OutdoorSpace

    @inline(__always) private static func softLimit(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.85 { return x }
        let y = 0.85 + 0.15 * tanhf((a - 0.85) / 0.15)
        return x < 0 ? -y : y
    }

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
        var home: Double         // its place in the stereo field, which it wanders about
        var filter = Biquad(.bandpass, q: 6)
        var wander = 1.0, wanderTarget = 1.0
        var level = 0.7, levelTarget = 0.7
        var pan = 0.0, panTarget = 0.0, gainL = 1.0, gainR = 1.0
    }
    private var bands = [WhooshBand(base: 150, home: -0.5), WhooshBand(base: 260, home: 0), WhooshBand(base: 420, home: 0.5)]
    /// Right channel when the output has only one: mixed down into it afterwards
    private let scratch: UnsafeMutablePointer<Float>
    private static let scratchFrames = 8192
    private var flutter = 1.0, flutterTarget = 1.0
    private var bodyDrift = 1.0, bodyDriftTarget = 1.0
    private var compEnvelope = 0.0, compGain = 1.0 // gentle compressor evens out the surges

    private static let maxVoices = 1024

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
        space = OutdoorSpace(sampleRate: sampleRate)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        scratch = .allocate(capacity: ChimeSynth.scratchFrames)
        scratch.initialize(repeating: 0, count: ChimeSynth.scratchFrames)
        voices.reserveCapacity(1280)
        pending.reserveCapacity(128)
        incoming.reserveCapacity(128)
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
        scratch.deallocate()
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
        let outL = raw.assumingMemoryBound(to: Float.self)
        outL.update(repeating: 0, count: frameCount)
        // Stereo: strikes are placed by where their tube hangs, the wind's whoosh bands
        // sit left, centre and right. With a single output channel the two are averaged
        let stereo = buffers.count > 1 && buffers[1].mData != nil
        guard stereo || frameCount <= ChimeSynth.scratchFrames else { return }
        let outR: UnsafeMutablePointer<Float> = stereo ? buffers[1].mData!.assumingMemoryBound(to: Float.self) : scratch
        outR.update(repeating: 0, count: frameCount)

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
                // Over the limit, shed the voices that end soonest (a ting's modes, a
                // note's last partials), never the oldest: those are the long ring tails,
                // and dropping them cut sustains off short in a gust's cluster
                let over = voices.count - ChimeSynth.maxVoices
                voices.sort { $0.stopTime > $1.stopTime }
                voices.removeLast(over)
            }
        }

        var i = 0
        while i < voices.count {
            if voices[i].render(into: outL, outR, frames: frameCount, sampleRate: sampleRate) {
                i += 1
            } else {
                voices.swapAt(i, voices.count - 1)
                voices.removeLast()
            }
        }
        renderedVoiceCount = voices.count

        let gain = outputGain
        if gain != 1 {
            for j in 0..<frameCount {
                outL[j] = ChimeSynth.softLimit(outL[j] * gain)
                outR[j] = ChimeSynth.softLimit(outR[j] * gain)
            }
        }

        space.process(outL, outR, frames: frameCount)
        renderWind(into: outL, outR, frames: frameCount)

        for j in 0..<frameCount {
            outL[j] = max(-1, min(1, outL[j] * masterGain))
            outR[j] = max(-1, min(1, outR[j] * masterGain))
        }
        if !stereo {
            for j in 0..<frameCount { outL[j] = 0.5 * (outL[j] + outR[j]) }
        }
        for b in 2..<max(2, buffers.count) {
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

    /// Mixes the wind layer into both channels. Same DSP as the Node prototype used to
    /// audition it, with the three whoosh bands spread across the field.
    private func renderWind(into outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, frames: Int) {
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
                    bands[i].panTarget = bands[i].home + whiteNoise() * 0.3
                }
                bands[i].wander += (bands[i].wanderTarget - bands[i].wander) * walk
                bands[i].level += (bands[i].levelTarget - bands[i].level) * walk
                bands[i].pan += (bands[i].panTarget - bands[i].pan) * walk
                let th = (max(-1, min(1, bands[i].pan)) + 1) * .pi / 4
                bands[i].gainL = 2.0.squareRoot() * cos(th); bands[i].gainR = 2.0.squareRoot() * sin(th)
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
                var whooshL = 0.0, whooshR = 0.0
                for i in bands.indices {
                    let s = bands[i].filter.process(pink) * bands[i].level
                    whooshL += s * bands[i].gainL; whooshR += s * bands[i].gainR
                }

                let mid = (rumble * gRumble + body * gBody) * master * compGain
                let yL = mid + whooshL * gWhoosh * master * compGain
                let yR = mid + whooshR * gWhoosh * master * compGain
                let y = 0.5 * (yL + yR)
                blockSum += y * y
                // Soft clip tames what the compressor misses
                outL[offset + k] += Float(tanh(yL * makeup * 1.6) / 1.6 * windSoundGain)
                outR[offset + k] += Float(tanh(yR * makeup * 1.6) / 1.6 * windSoundGain)
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
