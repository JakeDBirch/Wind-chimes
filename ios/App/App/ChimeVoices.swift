import Foundation

/// Everything about how a recorded sample responds to a strike. The defaults were found
/// by ear with the live sliders on the sample-tuning branch.
struct SampleVoiceParams {
    var level = 0.81            // overall gain
    var hitCurve = 1.9          // hit = velocity^hitCurve drives most of the velocity response
    // VCA
    var attackSoftMs = 14.0
    var attackHardMs = 2.0
    var decayMin = 3.0         // seconds at zero velocity
    var decayMax = 12.2          // seconds added at full velocity
    var decayCurve = 0.75        // velocity^decayCurve shapes how fast decay grows
    var decayVariation = 0.15   // ± random per hit
    var kneeTime = 0.12         // fraction of the decay at which the fast drop ends
    var kneeLevelSoft = 0.18    // level (× peak) at the knee for soft hits
    var kneeLevelHard = 0.35    // ... for hard hits
    // VCF
    var cutoffSoft = 0.5        // start cutoff × fundamental, soft hit
    var cutoffHard = 12.0       // ... hard hit
    var cutoffEndSoft = 0.3     // end cutoff × fundamental, soft hit
    var cutoffEndHard = 1.2
    var filterDecaySoft = 1.1  // filter close time as a fraction of the decay
    var filterDecayHard = 1.05
    var resonanceSoft = 0.0     // lowpass Q in dB
    var resonanceHard = 0.0
    // Pitch
    var bendCents = 12.0        // how sharp a full-velocity hit starts
    var bendTimeSoftMs = 60.0   // how long the bend takes to settle
    var bendTimeHardMs = 100.0
    var detuneCents = 8.0       // random spread per hit
    // Octave layer
    var octaveThreshold = 0.49  // velocity above which the octave layer appears
    var octaveGain = 0.18
    var octaveDecay = 0.45      // × the main decay
    var octaveCutoff = 0.8      // × the main cutoff

    /// Apply any matching numeric keys from the page.
    mutating func apply(_ values: [String: Double]) {
        for (key, value) in values {
            switch key {
            case "level": level = value
            case "hitCurve": hitCurve = value
            case "attackSoftMs": attackSoftMs = value
            case "attackHardMs": attackHardMs = value
            case "decayMin": decayMin = value
            case "decayMax": decayMax = value
            case "decayCurve": decayCurve = value
            case "decayVariation": decayVariation = value
            case "kneeTime": kneeTime = value
            case "kneeLevelSoft": kneeLevelSoft = value
            case "kneeLevelHard": kneeLevelHard = value
            case "cutoffSoft": cutoffSoft = value
            case "cutoffHard": cutoffHard = value
            case "cutoffEndSoft": cutoffEndSoft = value
            case "cutoffEndHard": cutoffEndHard = value
            case "filterDecaySoft": filterDecaySoft = value
            case "filterDecayHard": filterDecayHard = value
            case "resonanceSoft": resonanceSoft = value
            case "resonanceHard": resonanceHard = value
            case "bendCents": bendCents = value
            case "bendTimeSoftMs": bendTimeSoftMs = value
            case "bendTimeHardMs": bendTimeHardMs = value
            case "detuneCents": detuneCents = value
            case "octaveThreshold": octaveThreshold = value
            case "octaveGain": octaveGain = value
            case "octaveDecay": octaveDecay = value
            case "octaveCutoff": octaveCutoff = value
            default: break
            }
        }
    }
}

/// Turns one strike into synth voices: a set of inharmonic partials with a
/// velocity-dependent attack, decay and filter sweep, the metal tube sound of the
/// original web version.
enum ChimeVoices {
    // Inharmonic series characteristic of hollow metal cylinders
    static let partialRatios = [1, 2.756, 5.404, 8.933]
    static let partialGains = [1.0, 0.55, 0.28, 0.10]
    static let partialDecays = [1.0, 0.55, 0.30, 0.15]

    static func make(for strike: ChimeStrike, sample: UserSample?, tuning t: SampleVoiceParams = SampleVoiceParams(),
                     sampleRate sr: Double) -> [SynthVoice] {
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
            func mix(_ soft: Double, _ hard: Double, _ x: Double) -> Double { soft + (hard - soft) * x }
            let ratio = sample.pitch > 0 ? freq / sample.pitch : freq / 440
            let hit = pow(velNorm, t.hitCurve)
            let decay = decayMult * (t.decayMin + pow(velNorm, t.decayCurve) * t.decayMax)
                * (1 - t.decayVariation + rand() * 2 * t.decayVariation) * (1 - freqNorm * 0.3)
            let attack = attackMult * mix(t.attackSoftMs, t.attackHardMs, velNorm) / 1000
            let level = vel * t.level * sample.loudness // evens out dense vs breathy material

            func layer(octave: Double, gainScale: Double, decayScale: Double, cutoffScale: Double) -> SynthVoice {
                let v = SynthVoice()
                v.startTime = now
                v.sample = sample.samples
                let detuneCents = (rand() - 0.5) * t.detuneCents
                v.sampleStep = ratio * octave * pow(2, detuneCents / 1200) * sample.sampleRate / sr
                // Hard hits start a little sharp and settle, as a struck object does
                v.pitchBend.setValue(pow(2, hit * t.bendCents / 1200), at: now)
                v.pitchBend.exponentialRamp(to: 1, at: now + mix(t.bendTimeSoftMs, t.bendTimeHardMs, hit) / 1000)

                // VCF: dark when soft, wide open when hard; closes faster than the amplitude
                let startMult = mix(t.cutoffSoft, t.cutoffHard, hit) * bright / 0.55 * cutoffScale
                let endMult = mix(t.cutoffEndSoft, t.cutoffEndHard, hit)
                let filterDecay = decay * decayScale * mix(t.filterDecaySoft, t.filterDecayHard, hit)
                var cutoff = Automation(freq * startMult * 0.5)
                cutoff.setValue(freq * startMult, at: now + attack)
                cutoff.exponentialRamp(to: freq * endMult, at: now + attack + filterDecay)
                v.filterFrequency = cutoff
                v.filter = Biquad(.lowpass, q: mix(t.resonanceSoft, t.resonanceHard, hit))

                // Makeup for a filter that starts below the fundamental, so a dark soft hit
                // holds its own against a bright one (2-pole lowpass response at f0). Full
                // makeup pushed the quiet notes past the metal, so three quarters of it is
                // applied; hard hits open the filter and get no makeup either way.
                let fullMakeup = min(4.0, (1 + pow(1 / max(0.05, startMult), 4)).squareRoot())
                let makeup = 1 + (fullMakeup - 1) * 0.75

                // VCA: fast drop into a quieter tail that rings for the rest of the decay
                let peak = level * gainScale * makeup
                let d = decay * decayScale
                v.gain.setValue(0, at: now)
                v.gain.linearRamp(to: peak, at: now + attack)
                v.gain.exponentialRamp(to: max(0.0001, peak * mix(t.kneeLevelSoft, t.kneeLevelHard, hit)), at: now + attack + d * t.kneeTime)
                v.gain.exponentialRamp(to: 0.0001, at: now + attack + d)
                v.stopTime = now + attack + d + 0.1
                return v
            }

            voices.append(layer(octave: 1, gainScale: 1, decayScale: 1, cutoffScale: 1))
            // Octave layer only on firmer hits, like the upper partials of a tube
            if velNorm > t.octaveThreshold && t.octaveGain > 0 {
                let presence = (velNorm - t.octaveThreshold) / max(0.01, 1 - t.octaveThreshold)
                voices.append(layer(octave: 2, gainScale: t.octaveGain * pow(presence, 0.7), decayScale: t.octaveDecay, cutoffScale: t.octaveCutoff))
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
