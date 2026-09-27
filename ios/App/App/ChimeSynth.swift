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

/// One sounding component of a strike: a sine (optionally FM-modulated, with an
/// optional detuned "ghost") or a one-shot noise burst, through an optional filter
/// and a gain envelope. Built on the engine queue, then rendered on the audio thread.
final class SynthVoice {
    static let blockSize = 32 // envelopes and filter sweeps update every 32 samples

    var startTime = 0.0
    var stopTime = 0.0

    var frequency = Automation(440)
    var noise: [Float]?
    var fmFrequency = 0.0
    var fmDepth: Automation?
    var ghostFrequency = 0.0
    var ghostStopTime = 0.0
    var ghostGain: Automation?

    var filter: Biquad?
    var filterFrequency: Automation? // nil = cutoff fixed when the voice was built
    var gain = Automation(1)
    var flutterRate = 0.0
    var flutterDepth = 0.0
    var flutterStopTime = 0.0
    var flutterEnvelope: Automation?

    private var time = 0.0
    private var phase = 0.0, fmPhase = 0.0, ghostPhase = 0.0, flutterPhase = 0.0
    private var noiseIndex = 0

    /// Adds this voice into `out`. Returns false once the voice has finished.
    func render(into out: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Double) -> Bool {
        let invSr = 1.0 / sampleRate
        let w = 2.0 * Double.pi * invSr
        let hasFM = fmDepth != nil
        let hasGhost = ghostGain != nil
        let hasFlutter = flutterEnvelope != nil
        let hasFilter = filter != nil
        let sweepsFilter = filterFrequency != nil
        var flt = filter ?? Biquad(.lowpass, q: 0)
        let isNoise = noise != nil
        let noiseBuf = noise ?? []
        let noiseCount = noiseBuf.count

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
            var d0 = 0.0, dD = 0.0
            if hasFM { d0 = fmDepth!.value(at: ta); dD = fmDepth!.value(at: t1) - d0 }
            var h0 = 0.0, hD = 0.0
            if hasGhost { h0 = ghostGain!.value(at: ta); hD = ghostGain!.value(at: t1) - h0 }
            var e0 = 0.0, eD = 0.0
            if hasFlutter { e0 = flutterEnvelope!.value(at: ta); eD = flutterEnvelope!.value(at: t1) - e0 }
            if sweepsFilter { flt.setFrequency(filterFrequency!.value(at: ta), sampleRate: sampleRate) }

            for k in 0..<n {
                let ts = t0 + Double(k) * invSr
                if ts < startTime { continue }
                if ts >= stopTime { break }
                let frac = (ts - ta) * invSpan

                var x: Double
                if isNoise {
                    x = noiseIndex < noiseCount ? Double(noiseBuf[noiseIndex]) : 0
                    noiseIndex += 1
                } else {
                    var f = f0 + fD * frac
                    if hasFM {
                        f += (d0 + dD * frac) * sin(fmPhase)
                        fmPhase += w * fmFrequency
                    }
                    x = sin(phase)
                    phase += w * f
                    if hasGhost && ts < ghostStopTime {
                        x += sin(ghostPhase)
                        ghostPhase += w * ghostFrequency
                    }
                }

                let y = hasFilter ? flt.process(x) : x
                var g = g0 + gD * frac
                if hasFlutter && ts < flutterStopTime {
                    g += flutterDepth * (e0 + eD * frac) * sin(flutterPhase)
                    flutterPhase += w * flutterRate
                }
                var s = y * g
                if hasGhost { s += y * (h0 + hD * frac) }
                out[offset + k] += Float(s)
            }
            offset += n
        }

        if hasFilter { filter = flt }
        let twoPi = 2.0 * Double.pi
        phase = phase.truncatingRemainder(dividingBy: twoPi)
        fmPhase = fmPhase.truncatingRemainder(dividingBy: twoPi)
        ghostPhase = ghostPhase.truncatingRemainder(dividingBy: twoPi)
        flutterPhase = flutterPhase.truncatingRemainder(dividingBy: twoPi)
        return time < stopTime
    }
}

/// Mixes strike voices on the audio thread. Voices are built elsewhere and handed
/// over through `enqueue`; the render thread only ever try-locks, so it never blocks.
final class ChimeSynth {
    let sampleRate: Double
    private let masterGain: Float = 0.9
    private static let maxVoices = 384

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

        for j in 0..<frameCount {
            out[j] = max(-1, min(1, out[j] * masterGain))
        }
        for b in 1..<max(1, buffers.count) {
            if let dst = buffers[b].mData {
                dst.copyMemory(from: raw, byteCount: frameCount * MemoryLayout<Float>.size)
            }
        }
    }
}
