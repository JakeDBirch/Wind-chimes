import Foundation

/// Turns one strike into synth voices: a set of inharmonic partials with a
/// velocity-dependent attack, decay and filter sweep, the metal tube sound of the
/// original web version.
enum ChimeVoices {
    // Inharmonic series characteristic of hollow metal cylinders
    static let partialRatios = [1, 2.756, 5.404, 8.933]
    static let partialGains = [1.0, 0.55, 0.28, 0.10]
    static let partialDecays = [1.0, 0.55, 0.30, 0.15]

    static func make(for strike: ChimeStrike, sample: UserSample?, sampleRate sr: Double) -> [SynthVoice] {
        func rand() -> Double { Double.random(in: 0..<1) }

        var voices: [SynthVoice] = []
        let freq = strike.frequency
        let velNorm = min(1.0, strike.velocity)
        let isClapper = strike.isClapper

        // ── Timbre by strike type: clapper hits ring bright and long, tube-on-tube is warmer
        let bright = isClapper ? 0.55 : 0.30
        let gainScale = isClapper ? 1.0 : 0.75
        let partialRolloff = isClapper ? 1.0 : 0.55
        let attackMult = isClapper ? 1.0 : 2.2
        let decayMult = isClapper ? 1.0 : 0.75

        let vel = gainScale * (0.05 + pow(velNorm, 2.2) * 0.95)
        let freqNorm = max(0, min(1, log2(freq / 220) / 3))
        let baseDecay = decayMult * (1.2 + pow(velNorm, 0.7) * 24.0) * (1 - freqNorm * 0.4)
        let velBright = bright * (0.20 + velNorm * velNorm * 0.80)
        let startCutoffMult = 3.0 + velBright * 7.0
        let endCutoffMult = 0.85 + velBright * 0.4

        let pitchWobble = 1 + (rand() - 0.5) * 0.001 * (1 - velNorm * 0.5)
        let now = 0.006

        // ── Recorded sound: the user's sample looped at the tube's pitch. A sample has a
        // fixed spectrum, so the hit's character comes from the filter and amplifier:
        // soft hits are short, dark taps; hard hits open the filter, bend sharp for a
        // moment, bring in an octave layer and ring on with a long tail.
        if let sample {
            let ratio = sample.pitch > 0 ? freq / sample.pitch : freq / 440
            let hit = pow(velNorm, 1.3)
            let decay = decayMult * (0.25 + pow(velNorm, 0.8) * 9.0) * (0.85 + rand() * 0.3) * (1 - freqNorm * 0.3)
            let attack = attackMult * (0.014 - velNorm * 0.012)
            let level = vel * 0.55

            func layer(octave: Double, gainScale: Double, decayScale: Double, cutoffScale: Double) -> SynthVoice {
                let v = SynthVoice()
                v.startTime = now
                v.sample = sample.samples
                let detuneCents = (rand() - 0.5) * 8
                v.sampleStep = ratio * octave * pow(2, detuneCents / 1200) * sample.sampleRate / sr
                // Hard hits start a little sharp and settle, as a struck object does
                v.pitchBend.setValue(1 + hit * 0.012, at: now)
                v.pitchBend.exponentialRamp(to: 1, at: now + 0.06 + hit * 0.04)

                // VCF: dark when soft, wide open when hard; closes faster than the amplitude
                let startMult = (1.5 + hit * 10.5) * bright / 0.55 * cutoffScale
                let endMult = 0.7 + hit * 0.5
                let filterDecay = decay * decayScale * (0.35 + hit * 0.15)
                var cutoff = Automation(freq * startMult * 0.5)
                cutoff.setValue(freq * startMult, at: now + attack)
                cutoff.exponentialRamp(to: freq * endMult, at: now + attack + filterDecay)
                v.filterFrequency = cutoff
                v.filter = Biquad(.lowpass, q: 0.5 + hit * 4.0) // Q in dB: some bite on hard hits

                // VCA: fast drop into a quieter tail that rings for the rest of the decay
                let peak = level * gainScale
                let d = decay * decayScale
                v.gain.setValue(0, at: now)
                v.gain.linearRamp(to: peak, at: now + attack)
                v.gain.exponentialRamp(to: peak * (0.18 + hit * 0.17), at: now + attack + d * 0.12)
                v.gain.exponentialRamp(to: 0.0001, at: now + attack + d)
                v.stopTime = now + attack + d + 0.1
                return v
            }

            voices.append(layer(octave: 1, gainScale: 1, decayScale: 1, cutoffScale: 1))
            // Octave layer only on firmer hits, like the upper partials of a tube
            if velNorm > 0.35 {
                let presence = (velNorm - 0.35) / 0.65
                voices.append(layer(octave: 2, gainScale: 0.28 * pow(presence, 0.7), decayScale: 0.45, cutoffScale: 0.8))
            }
            return voices
        }

        for i in 0..<partialRatios.count {
            let di = Double(i)
            let pFreq = freq * partialRatios[i] * pitchWobble
            if pFreq > 16000 { continue }

            // Higher partials only emerge on harder strikes
            let threshold = di * 0.12
            if velNorm < threshold { continue }
            let partialVel = max(0, (velNorm - threshold) / (1 - threshold))

            let detuneCents = (rand() - 0.5) * 4
            let pFreqD = pFreq * pow(2, detuneCents / 1200)
            let pDecay = baseDecay * partialDecays[i]
            let gainVar = 0.90 + rand() * 0.20
            let pGain = vel * partialGains[i] * gainVar * pow(partialRolloff, di) * pow(partialVel, 0.6) * 0.65
            let attack = attackMult * (0.006 + di * (0.006 + velNorm * 0.008))

            let v = SynthVoice()
            v.startTime = now
            v.frequency = Automation(pFreqD)

            // Lowpass sweep from bright to dark as the note decays
            var cutoff = Automation(350) // BiquadFilterNode default until the sweep starts
            cutoff.setValue(pFreq * startCutoffMult, at: now + attack)
            cutoff.exponentialRamp(to: pFreq * endCutoffMult, at: now + attack + pDecay)
            v.filterFrequency = cutoff
            v.filter = Biquad(.lowpass, q: 0.5)

            v.gain.setValue(0, at: now)
            v.gain.linearRamp(to: pGain, at: now + attack)
            v.gain.exponentialRamp(to: 0.0001, at: now + attack + pDecay)
            v.stopTime = now + attack + pDecay + 0.1
            voices.append(v)
        }

        return voices
    }
}
