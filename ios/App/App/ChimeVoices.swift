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
    var detuneCents = 0.0       // random spread per hit; 0, or repeated strikes of one tube beat
    // Octave layer
    var octaveThreshold = 0.49  // velocity above which the octave layer appears
    var octaveGain = 0.18
    var octaveDecay = 0.45      // × the main decay
    var octaveCutoff = 0.8      // × the main cutoff
    // Metal voice: the ting, the modes of a real tube that the four partials of the
    // sustain don't carry, taken from the reference physical model (scripts/reference)
    // at the strike's actual speed: their amplitude relative to the fundamental's and
    // their decay are the model's; only the level is taste.
    var sustain = 1.0           // × the ring time of every voice, metal and recorded (the Workshop's Ring time)
    var ting = 0.004            // level; 1 would be the model's balance against the fundamental, this is a 250th of it by ear
    var tingDecay = 1.85        // × the model's decay times
    var tingFrom = 2.0          // the lowest bending mode in the ting: the second, so it carries every mode above the fundamental

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
            case "sustain": sustain = max(0.1, value)
            case "ting": ting = max(0, value)
            case "tingDecay": tingDecay = max(0.05, value)
            case "tingFrom": tingFrom = max(2, min(9, value))
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
    // The same series carried on: the modes a strike excites but that are gone before the
    // ring settles. Only the ting uses them.
    static let tingRatios = [1, 2.756, 5.404, 8.933, 13.34, 18.64]

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
        // Ring time falls with pitch, as a metal tube's does (its losses give a roughly
        // constant Q, so a real tube rings in proportion to 1/f). Here it's a nudge toward
        // that: ∝ 1/f^0.6, anchored so A4 keeps the length it had, so an octave up rings
        // a third shorter and an octave down half as long again; clamped at both ends.
        let pitchRing = max(0.2, min(2.4, 0.867 * pow(440 / freq, 0.6)))
        // The decay is the time to -80 dB, so a note is heard for about half of it: a soft
        // touch at A4 rings for a few seconds, a hard strike for a dozen (Oct 26: the soft
        // end doubled and the hard end a quarter longer, as they died too soon)
        let baseDecay = decayMult * (2.5 + pow(velNorm, 0.7) * 30.0) * pitchRing * t.sustain
        let velBright = bright * (0.20 + velNorm * velNorm * 0.80)
        let startCutoffMult = 3.0 + velBright * 7.0
        // The sweep ends well above each partial: closing onto it (it used to end at 0.85×)
        // took another dozen dB off in the note's last stretch and made the end sudden
        let endCutoffMult = 1.8 + velBright * 0.4

        // No per-strike pitch randomness: a tube struck again while ringing must land on
        // exactly the same frequencies, or the two notes beat and read as pitch wobble
        let pitchWobble = 1.0
        let now = 0.006

        // ── Recorded sound: the user's sample looped at the tube's pitch. A sample has a
        // fixed spectrum, so the hit's character comes from the filter and amplifier:
        // soft hits are short, dark taps; hard hits open the filter, bend sharp for a
        // moment, bring in an octave layer and ring on with a long tail.
        if let sample {
            func mix(_ soft: Double, _ hard: Double, _ x: Double) -> Double { soft + (hard - soft) * x }
            let ratio = sample.pitch > 0 ? freq / sample.pitch : freq / 440
            let hit = pow(velNorm, t.hitCurve)
            let decay = decayMult * (t.decayMin + pow(velNorm, t.decayCurve) * t.decayMax) * t.sustain
                * (1 - t.decayVariation + rand() * 2 * t.decayVariation) * max(0.3, min(2.0, 0.9 * pow(440 / freq, 0.45)))
            let attack = attackMult * mix(t.attackSoftMs, t.attackHardMs, velNorm) / 1000
            let level = vel * t.level * sample.loudness // evens out dense vs breathy material

            func layer(octave: Double, gainScale: Double, decayScale: Double, cutoffScale: Double) -> SynthVoice {
                let v = SynthVoice()
                v.startTime = now
                v.sample = sample.samples
                v.loopStart = sample.loopStart
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

        // ── The ting: the first instant of a real strike is the tube's high modes, which the
        // four partials below don't carry. They come from the reference physical model,
        // looked up at this strike's pitch, approach speed and striker: each mode's
        // amplitude relative to the fundamental's and its decay are the model's, scaled by
        // the fundamental this voice is about to play, so the ting follows velocity the
        // way a struck tube's does. Instant onset, no filter.
        if t.ting > 0 {
            let fundamental = vel * 0.65
            for m in referenceTing(for: strike, from: Int(t.tingFrom.rounded())) {
                let level = t.ting * fundamental * m.relative
                if level < 2e-5 { continue }
                let v = SynthVoice()
                v.modal = true
                v.startTime = now
                v.modalFreq = m.frequency
                v.modalAmp = level
                v.modalDecay = m.decay / t.tingDecay
                v.stopTime = now + log(level / 2e-5) / v.modalDecay + 0.01
                voices.append(v)
            }
        }

        for i in 0..<partialRatios.count {
            let di = Double(i)
            let pFreq = freq * partialRatios[i] * pitchWobble
            if pFreq > 16000 { continue }

            // Higher partials only emerge on harder strikes
            let threshold = di * 0.12
            if velNorm < threshold { continue }
            let partialVel = max(0, (velNorm - threshold) / (1 - threshold))

            let pFreqD = pFreq
            let pDecay = baseDecay * partialDecays[i]
            let gainVar = 0.90 + rand() * 0.20
            let pGain = vel * partialGains[i] * gainVar * pow(partialRolloff, di) * pow(partialVel, 0.6) * 0.65
            let attack = attackMult * (0.006 + di * (0.006 + velNorm * 0.008))

            // Twin modes: a real tube is never perfectly round, so each partial is a pair
            // of modes a cent or two apart that beat slowly as the note rings. The split is
            // fixed per tube (from its pitch), so a tube warbles the same way every strike
            // and no two tubes warble together.
            let split = twinModeSplit(for: freq)
            for sign in [-0.5, 0.5] {
                let v = SynthVoice()
                v.startTime = now
                v.frequency = Automation(pFreqD * pow(2, sign * split / 1200))

                // Lowpass sweep from bright to dark as the note decays
                var cutoff = Automation(350) // BiquadFilterNode default until the sweep starts
                cutoff.setValue(pFreq * startCutoffMult, at: now + attack)
                cutoff.exponentialRamp(to: pFreq * endCutoffMult, at: now + attack + pDecay)
                v.filterFrequency = cutoff
                v.filter = Biquad(.lowpass, q: 0.5)

                // Two-stage release: the ring falls to -50 dB over most of the decay, then
                // the last stretch to silence takes its time, the way a lightly damped tube
                // hangs on at the very end rather than snapping off
                let peak = pGain * 0.5
                let knee = now + attack + pDecay * 0.7
                v.gain.setValue(0, at: now)
                v.gain.linearRamp(to: peak, at: now + attack)
                v.gain.exponentialRamp(to: peak * 0.00316, at: knee)
                v.gain.exponentialRamp(to: peak * 0.0001, at: knee + pDecay * 0.9) // half the slope
                v.stopTime = knee + pDecay * 0.9 + 0.05
                voices.append(v)
            }
        }

        return voices
    }

    struct TingMode { let frequency: Double; let relative: Double; let decay: Double }

    /// The reference model's modes for this strike beyond the sustain's partials: the
    /// bending modes from `from` up and the wall's ovalling modes, each with its
    /// amplitude as a fraction of the loudest low mode's and its decay rate per second.
    /// Interpolated in log pitch and log speed between the fitted grid points.
    static func referenceTing(for strike: ChimeStrike, from: Int) -> [TingMode] {
        let table = strike.isClapper ? ChimeModalTable.wood : ChimeModalTable.tube
        let pitches = ChimeModalTable.pitches, speeds = ChimeModalTable.speeds
        let f = strike.frequency
        let fc = min(max(f, pitches.first!), pitches.last!)
        var i = 0
        while i + 2 < pitches.count && pitches[i + 1] <= fc { i += 1 }
        let tp = log(fc / pitches[i]) / log(pitches[i + 1] / pitches[i])
        let sc = min(max(strike.speed, speeds.first!), speeds.last!)
        var j = 0
        while j + 2 < speeds.count && speeds[j + 1] <= sc { j += 1 }
        let ts = log(sc / speeds[j]) / log(speeds[j + 1] / speeds[j])
        func amp(_ m: ChimeModalTable.Mode) -> Double {
            exp(log(max(m.amps[j], 1e-9)) * (1 - ts) + log(max(m.amps[j + 1], 1e-9)) * ts)
        }
        let lo = table[i], hi = table[i + 1]
        let loBend = lo.filter { !$0.shell }, hiBend = hi.filter { !$0.shell }
        let loShell = lo.filter { $0.shell }, hiShell = hi.filter { $0.shell }
        // Relative to the loudest of the model's first four modes, the ones the sustain
        // plays (its fundamental is the loudest of its partials, so that is what the
        // level scales). Mode 1 alone would do, except that a long tube radiates its
        // fundamental poorly in the model and the ratio would blow up at low pitch.
        var reference = 1e-9
        for k in 0..<min(4, loBend.count, hiBend.count) {
            reference = max(reference, exp(log(amp(loBend[k])) * (1 - tp) + log(amp(hiBend[k])) * tp))
        }
        var out: [TingMode] = []
        func add(_ a: ChimeModalTable.Mode, _ b: ChimeModalTable.Mode) {
            let ratio = a.ratio * (1 - tp) + b.ratio * tp
            let zeta = max(1e-4, a.zeta * (1 - tp) + b.zeta * tp)
            let level = exp(log(amp(a)) * (1 - tp) + log(amp(b)) * tp)
            let mf = f * ratio
            if mf > 16000 { return }
            out.append(TingMode(frequency: mf, relative: level / reference, decay: zeta * 2 * .pi * mf))
        }
        let first = max(1, from - 1)
        if first < min(loBend.count, hiBend.count) {
            for k in first..<min(loBend.count, hiBend.count) { add(loBend[k], hiBend[k]) }
        }
        for k in 0..<min(loShell.count, hiShell.count) { add(loShell[k], hiShell[k]) }
        return out
    }

    /// The split between a tube's two bending modes, in cents: 1 to 2.6, fixed for a given
    /// pitch so every strike of that tube beats at the same slow rate (2 cents at A4 is a
    /// beat every two seconds).
    static func twinModeSplit(for freq: Double) -> Double {
        let x = sin(freq * 12.9898) * 43758.5453
        let frac = x - floor(x)
        return 1.0 + 1.6 * frac
    }
}
