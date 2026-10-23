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

/// Turns one strike into synth voices. The metal voice is a modal synth fitted to the
/// reference physical model of a 1-inch aluminium tube (scripts/reference): every
/// mode the model found, at the frequency, damping and amplitude it found for this
/// pitch, this approach speed and this striker, each a damped sine from the first
/// sample. A recorded sound plays the user's sample instead.
enum ChimeVoices {
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
        let attackMult = isClapper ? 1.0 : 2.2
        let decayMult = isClapper ? 1.0 : 0.75

        let vel = gainScale * (0.05 + pow(velNorm, 2.2) * 0.95)
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

        return modal(for: strike)
    }

    /// Hard hits in the table are 1 m/s; this puts one at a peak of about 0.6 in the mix
    static let calibration: Double = {
        let row = ChimeModalTable.wood[4]              // 440 Hz
        let j = ChimeModalTable.speeds.firstIndex(of: 1.0) ?? 5
        let sum = row.reduce(0.0) { $0 + $1.amps[j] }
        return 0.6 / max(sum, 1e-9)
    }()

    /// The modal metal voice: look the strike up in the reference table, interpolating
    /// in log pitch between the two nearest fitted tubes and in log speed between the
    /// two nearest fitted strikes, and start every mode as a damped sine.
    static func modal(for strike: ChimeStrike) -> [SynthVoice] {
        let table = strike.isClapper ? ChimeModalTable.wood : ChimeModalTable.tube
        let pitches = ChimeModalTable.pitches, speeds = ChimeModalTable.speeds
        let f = strike.frequency
        let now = 0.006

        // Pitch bracket
        let fc = min(max(f, pitches.first!), pitches.last!)
        var i = 0
        while i + 2 < pitches.count && pitches[i + 1] <= fc { i += 1 }
        let tp = log(fc / pitches[i]) / log(pitches[i + 1] / pitches[i])
        // Speed bracket
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
        let split = twinModeSplit(for: f)
        var voices: [SynthVoice] = []

        func add(_ a: ChimeModalTable.Mode, _ b: ChimeModalTable.Mode, twin: Bool) {
            let ratio = a.ratio * (1 - tp) + b.ratio * tp
            let zeta = max(1e-4, a.zeta * (1 - tp) + b.zeta * tp)
            let level = exp(log(amp(a)) * (1 - tp) + log(amp(b)) * tp) * calibration
            let mf = f * ratio
            if mf > 16000 || level < 3e-5 { return }
            let decay = zeta * 2 * .pi * mf
            // Twin modes: a real tube is never perfectly round, so each bending mode is a
            // pair a cent or two apart that beat slowly as the note rings. Fixed per tube.
            let parts: [Double] = twin && mf < 4000 ? [-0.5, 0.5] : [0]
            for sign in parts {
                let v = SynthVoice()
                v.modal = true
                v.startTime = now
                v.modalFreq = mf * pow(2, sign * split / 1200)
                v.modalAmp = level / Double(parts.count)
                v.modalDecay = decay
                v.stopTime = now + log(v.modalAmp / 2e-5) / decay + 0.01
                voices.append(v)
            }
        }
        for k in 0..<min(loBend.count, hiBend.count) { add(loBend[k], hiBend[k], twin: true) }
        for k in 0..<min(loShell.count, hiShell.count) { add(loShell[k], hiShell[k], twin: false) }
        return voices
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
