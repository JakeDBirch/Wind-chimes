import Foundation

/// Turns one strike into synth voices. A port of playTubeStrike() from the original
/// web version: inharmonic partials per material, plus an attack layer for wood.
enum ChimeVoices {
    // Metal tube partials — inharmonic series characteristic of hollow metal cylinders
    static let metalRatios = [1, 2.756, 5.404, 8.933]
    static let metalGains = [1.0, 0.55, 0.28, 0.10]
    static let metalDecays = [1.0, 0.55, 0.30, 0.15]

    // Wood partials — free bar modes with a near-fundamental doublet (1.5% sharp) for beating.
    // Wood damps upper partials very fast: mostly fundamental with a brief overtone shimmer.
    static let woodRatios = [1, 1.015, 1.67, 2.76, 4.47]
    static let woodGains = [1.0, 0.45, 0.55, 0.28, 0.10]
    static let woodDecays = [1.0, 0.80, 0.58, 0.26, 0.10]

    static func make(for strike: ChimeStrike, sampleRate sr: Double) -> [SynthVoice] {
        func rand() -> Double { Double.random(in: 0..<1) }

        var voices: [SynthVoice] = []
        let freq = strike.frequency
        let velNorm = min(1.0, strike.velocity)
        let isWood = strike.isWood
        let isClapper = strike.isClapper

        let ratios = isWood ? woodRatios : metalRatios
        let gains = isWood ? woodGains : metalGains
        let decays = isWood ? woodDecays : metalDecays

        // ── Timbre by strike type + material
        let bright, gainScale, partialRolloff, attackMult, decayMult: Double
        if isWood {
            // Short, dark, thunk character
            bright = isClapper ? 0.30 : 0.18
            gainScale = isClapper ? 1.80 : 1.25
            partialRolloff = isClapper ? 0.80 : 0.50
            attackMult = isClapper ? 1.0 : 1.8
            decayMult = isClapper ? 0.55 : 0.35
        } else {
            bright = isClapper ? 0.55 : 0.30
            gainScale = isClapper ? 1.0 : 0.75
            partialRolloff = isClapper ? 1.0 : 0.55
            attackMult = isClapper ? 1.0 : 2.2
            decayMult = isClapper ? 1.0 : 0.75
        }

        let vel = gainScale * (0.05 + pow(velNorm, 2.2) * 0.95)
        let freqNorm = max(0, min(1, log2(freq / 220) / 3))

        let baseDecay, velBright, startCutoffMult, endCutoffMult: Double
        if isWood {
            // Much shorter decay, narrower filter sweep — wood doesn't ring
            baseDecay = decayMult * (0.14 + pow(velNorm, 1.5) * 2.2) * (1 - freqNorm * 0.3)
            velBright = bright * (0.30 + velNorm * 0.70)
            startCutoffMult = 3.0 + velBright * 5.5
            endCutoffMult = 0.80 + velBright * 0.20
        } else {
            baseDecay = decayMult * (1.2 + pow(velNorm, 0.7) * 24.0) * (1 - freqNorm * 0.4)
            velBright = bright * (0.20 + velNorm * velNorm * 0.80)
            startCutoffMult = 3.0 + velBright * 7.0
            endCutoffMult = 0.85 + velBright * 0.4
        }

        // ── Wood attack layer
        if isWood {
            if isClapper {
                // Hard rubber on wood: smooth, focused impact with a strong thud
                let rubberLen = 0.018 + velNorm * 0.022
                voices.append(noiseBurst(whiteNoise(seconds: rubberLen, sampleRate: sr), sampleRate: sr,
                                         bandpass: freq * 1.05, q: 4.0,
                                         level: vel * (0.20 + velNorm * 0.55), decayAt: rubberLen))
                // Sub thud
                voices.append(sine(freq * 0.50, stop: 0.15,
                                   level: vel * (0.45 + velNorm * 1.10), decayAt: 0.05 + velNorm * 0.06))
                // Mid thud — the body impact
                voices.append(sine(freq * (0.80 + (rand() - 0.5) * 0.04), stop: 0.10,
                                   level: vel * (0.35 + velNorm * 0.80), decayAt: 0.030 + velNorm * 0.025))
                // FM burst — lower index than wood-on-wood, rubber is smoother
                voices.append(fmBurst(carrier: freq * (1 + (rand() - 0.5) * 0.015),
                                      modulator: freq * (1.52 + (rand() - 0.5) * 0.05),
                                      depth: vel * velNorm * freq * 2.0, depthDecayAt: 0.020,
                                      level: vel * 0.22 * velNorm, decayAt: 0.035, stop: 0.05))
            } else {
                // Wood on wood: scrappy, noisy, spread across inharmonic frequencies
                let noiseLen = 0.035 + velNorm * 0.04
                let buffer = whiteNoise(seconds: noiseLen, sampleRate: sr)
                let bands: [(ratio: Double, q: Double, gain: Double, decay: Double)] = [
                    (1.15, 2.0, 0.45, noiseLen * 0.6),
                    (1.83, 2.5, 0.32, noiseLen * 0.4),
                    (3.10, 3.0, 0.20, noiseLen * 0.25),
                ]
                for band in bands {
                    voices.append(noiseBurst(buffer, sampleRate: sr,
                                             bandpass: freq * band.ratio * (0.97 + rand() * 0.06), q: band.q,
                                             level: vel * band.gain * (0.18 + velNorm * 0.75), decayAt: band.decay))
                }
                // FM burst — higher index, more chaotic than rubber
                voices.append(fmBurst(carrier: freq * (1 + (rand() - 0.5) * 0.02),
                                      modulator: freq * (1.67 + (rand() - 0.5) * 0.08),
                                      depth: vel * velNorm * freq * 4.0, depthDecayAt: 0.025 + velNorm * 0.02,
                                      level: vel * 0.30 * velNorm, decayAt: 0.04 + velNorm * 0.03, stop: 0.06))
                // Sub knock
                voices.append(sine(freq * 0.52, stop: 0.12,
                                   level: vel * (0.22 + velNorm * 0.90), decayAt: 0.04 + velNorm * 0.06))
                // Mid-body knock
                voices.append(sine(freq * (0.83 + (rand() - 0.5) * 0.06), stop: 0.08,
                                   level: vel * (0.18 + velNorm * 0.60), decayAt: 0.025 + velNorm * 0.03))
            }
        }

        // ── Partials
        let pitchWobble = 1 + (rand() - 0.5) * (isWood ? 0.012 : 0.001) * (1 - velNorm * 0.5)
        let now = 0.006

        for i in 0..<ratios.count {
            let di = Double(i)
            var ratio = ratios[i]
            if isWood && i > 0 {
                // Scatter upper partials per strike: small for the doublet, wider above
                let scatter = i == 1 ? 0.008 : 0.10 * di
                ratio *= 1 + (rand() - 0.5) * scatter
            }
            let pFreq = freq * ratio * pitchWobble
            if pFreq > 16000 { continue }

            // Higher partials only emerge on harder strikes
            let threshold = isWood ? di * 0.30 : di * 0.12
            if velNorm < threshold { continue }
            let partialVel = max(0, (velNorm - threshold) / (1 - threshold))

            let detuneCents = (rand() - 0.5) * (isWood ? (i == 0 ? 8 : 20) : 4)
            let pFreqD = pFreq * pow(2, detuneCents / 1200)

            let decayVar = isWood ? (0.80 + rand() * 0.40) : 1.0
            let pDecay = baseDecay * decays[i] * decayVar
            let gainVar = isWood ? (0.75 + rand() * 0.50) : (0.90 + rand() * 0.20)
            let pGain = vel * gains[i] * gainVar * pow(partialRolloff, di) * pow(partialVel, 0.6) * 0.65

            // Low velocity = rounder attack; high velocity = sharp transient
            let velAttack = isWood ? (0.018 - velNorm * 0.014) : 0.006
            let attack = attackMult * (velAttack + di * (0.006 + velNorm * 0.008))

            let v = SynthVoice()
            v.startTime = now
            v.frequency = Automation(pFreqD)

            // Static cutoff for wood (a sweep reads as pitch bend); sweep for metal
            var filter = Biquad(.lowpass, q: 0.5)
            if isWood {
                filter.setFrequency(pFreq * (endCutoffMult + velNorm * (startCutoffMult - endCutoffMult) * 0.4),
                                    sampleRate: sr)
            } else {
                var cutoff = Automation(350) // BiquadFilterNode default until the sweep starts
                cutoff.setValue(pFreq * startCutoffMult, at: now + attack)
                cutoff.exponentialRamp(to: pFreq * endCutoffMult, at: now + attack + pDecay)
                v.filterFrequency = cutoff
            }
            v.filter = filter

            v.gain.setValue(0, at: now)
            v.gain.linearRamp(to: pGain, at: now + attack)

            if isWood {
                // Two-stage release: fast dump to a tail level, then an RC-curve tail
                let dumpFrac = 0.32 + velNorm * 0.38
                let dumpTime = pDecay * (0.12 + velNorm * 0.08)
                let tailLevel = pGain * (1 - dumpFrac)
                let tailTime = pDecay * (0.90 - velNorm * 0.48 + rand() * 0.12)
                v.gain.exponentialRamp(to: max(0.0001, tailLevel), at: now + attack + dumpTime)
                v.gain.setTarget(0.0001, startingAt: now + attack + dumpTime, timeConstant: tailTime / 5.5)
                v.stopTime = now + attack + dumpTime + tailTime + 0.1

                let ringTime = tailTime != 0 ? tailTime : pDecay

                // A. Detuned ghost — subtle beating, a different rate per partial
                let ghostDetune = (rand() - 0.5) * 0.022 * (1 + di * 0.5)
                v.ghostFrequency = pFreqD * (1 + ghostDetune)
                var ghost = Automation(1)
                ghost.setValue(0, at: now)
                ghost.linearRamp(to: pGain * 0.22, at: now + attack)
                ghost.setTarget(0.0001, startingAt: now + attack, timeConstant: ringTime / 4)
                v.ghostGain = ghost
                v.ghostStopTime = now + attack + ringTime + 0.1

                // B. Tiny slow frequency drift in the tail — material settling
                let driftAmt = pFreqD * (rand() - 0.5) * 0.003
                let driftTime = ringTime * (0.3 + rand() * 0.5)
                v.frequency.setValue(pFreqD, at: now + attack)
                v.frequency.linearRamp(to: pFreqD + driftAmt, at: now + attack + driftTime)

                // C. Mode coupling — amplitude flutter on the doublet partial
                if i == 1 {
                    v.flutterRate = 2.5 + rand() * 4.0
                    v.flutterDepth = pGain * 0.08
                    var flutter = Automation(1)
                    flutter.setValue(1, at: now + attack)
                    flutter.setTarget(0.0001, startingAt: now + attack, timeConstant: ringTime / 3.5)
                    v.flutterEnvelope = flutter
                    v.flutterStopTime = now + attack + ringTime + 0.1
                }
            } else {
                v.gain.exponentialRamp(to: 0.0001, at: now + attack + pDecay)
                v.stopTime = now + attack + pDecay + 0.1
            }
            voices.append(v)
        }

        return voices
    }

    // MARK: - Building blocks

    private static func sine(_ frequency: Double, stop: Double, level: Double, decayAt end: Double) -> SynthVoice {
        let v = SynthVoice()
        v.frequency = Automation(frequency)
        v.stopTime = stop
        v.gain.setValue(level, at: 0)
        v.gain.exponentialRamp(to: 0.0001, at: end)
        return v
    }

    private static func fmBurst(carrier: Double, modulator: Double, depth: Double, depthDecayAt depthEnd: Double,
                                level: Double, decayAt end: Double, stop: Double) -> SynthVoice {
        let v = sine(carrier, stop: stop, level: level, decayAt: end)
        v.fmFrequency = modulator
        var d = Automation(1)
        d.setValue(depth, at: 0)
        d.exponentialRamp(to: 0.0001, at: depthEnd)
        v.fmDepth = d
        return v
    }

    private static func noiseBurst(_ buffer: [Float], sampleRate: Double, bandpass frequency: Double, q: Double,
                                   level: Double, decayAt end: Double) -> SynthVoice {
        let v = SynthVoice()
        v.noise = buffer
        v.stopTime = Double(buffer.count) / sampleRate
        var filter = Biquad(.bandpass, q: q)
        filter.setFrequency(frequency, sampleRate: sampleRate)
        v.filter = filter
        v.gain.setValue(level, at: 0)
        v.gain.exponentialRamp(to: 0.0001, at: end)
        return v
    }

    private static func whiteNoise(seconds: Double, sampleRate: Double) -> [Float] {
        let count = Int((sampleRate * seconds).rounded(.up))
        return (0..<count).map { _ in Float.random(in: -1..<1) }
    }
}
