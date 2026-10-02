import Foundation

/// Turns one strike into synth voices: a set of inharmonic partials with a
/// velocity-dependent attack, decay and filter sweep, the metal tube sound of the
/// original web version.
enum ChimeVoices {
    // Inharmonic series characteristic of hollow metal cylinders
    static let partialRatios = [1, 2.756, 5.404, 8.933]
    static let partialGains = [1.0, 0.55, 0.28, 0.10]
    static let partialDecays = [1.0, 0.55, 0.30, 0.15]

    static func make(for strike: ChimeStrike, sampleRate sr: Double) -> [SynthVoice] {
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
