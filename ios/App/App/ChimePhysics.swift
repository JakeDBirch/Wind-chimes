import Foundation

/// Settings the web controls send down. Defaults match the slider defaults in index.html.
struct ChimeParams {
    var windStrength = 0.3
    var windConsistency = 0.4 // "Constancy" on screen: 0 = gusty and shifting with long calms, 1 = a steady breeze
    var sensitivity: Double { lab.sensitivity } // how much wind force reaches the ring, tubes and clapper
    var tubeCount = 6
    var register = 0.0
    var scale = "Pentatonic"
    var windSoundGain = 0.1 // linear; 0 = off, 1 = full
    var windTightness = 0.6 // 0 = smooth, lagging impression; 1 = tracks the force almost directly
    var customScale = [0, 3, 5, 7, 10] // semitones above A, used when scale == "Custom"

    let cordLength = 0.53
    /// The Lab: every physics and measurement change of the last two days as its own
    /// setting, so the feel can be taken apart one knob at a time. Defaults are today's.
    var lab = LabParams()
    var gap: Double { lab.gap }
    var clapperGap: Double { lab.clapperGap }

    /// Velocity damping per step; the old slider's default, kept fixed
    let damping = 0.0015 * pow(6.667, 0.42) * 1.1 // the old slider's default, a tenth more since 21 Oct
    var windSteady: Double { windConsistency * 0.35 }
    var windTurb: Double { lab.steadyConstancy ? 0.5 - windConsistency * 0.4 - windConsistency * windConsistency * 0.08 : 0.5 - windConsistency * 0.4 }
    /// Scales the lulls between wind events: 1.5× at consistency 0, 0.3× at 1
    var lullScale: Double { 1.5 - windConsistency * 1.2 }
    /// Chance a lull goes truly still rather than settling to a breeze: 50% at 0, none at 1
    var stillLullChance: Double { (1 - windConsistency) * 0.5 }
    /// Wind speed between gusts: a light 15% at 0, up to 60% at 1 so the wind never drops out
    var breezeSpeed: Double { 0.15 + windConsistency * 0.45 }
    /// Holds last up to twice as long at consistency 1
    var holdScale: Double { 1 + windConsistency }
    /// How much the speed wanders within a gust (sub-gusts, drops, wander): 0.75 at
    /// constancy 0, 0.5 at the default 0.4, none at 1
    var gustVariation: Double { lab.steadyConstancy ? (1 - windConsistency) * 0.5 + 0.25 * (1 - windConsistency * windConsistency) : 0.25 + (1 - windConsistency) * 0.5 }
    /// At full constancy every event blows at the same strength; lower down the peaks
    /// are random (weighted toward lighter events)
    var peakBlend: Double { lab.steadyConstancy ? windConsistency * windConsistency : 0 }
    /// Scales the wobble and the chance of a spike while a gust holds: gone at 1
    var holdWobble: Double { lab.steadyConstancy ? 1 - windConsistency * windConsistency * 0.9 : 1 }
    var spikeChance: Double { lab.steadyConstancy ? 1 - windConsistency * windConsistency : 1 }
    /// The wind never falls below this between events: nothing at 0, the breeze at 1,
    /// so a constant wind stays up instead of dipping to zero before each gust
    var speedFloor: Double { lab.steadyConstancy ? breezeSpeed * windConsistency : 0 }
}

/// Lab settings. Each one is a change made on 17–19 October; "Oct 17", "Oct 18" and
/// "Today" presets on the page set them all at once, and any can be moved alone.
struct LabParams: Equatable {
    var steadyConstancy = true   // full constancy is a genuinely steady wind (Oct 18)
    var collisionAtMid = true    // tube-on-tube clashes at the midpoints, where drawn (Oct 18)
    var prevailingWind = true    // a slowly veering prevailing direction (Oct 18)
    var gap = 10.5               // mm between neighbouring tubes at rest (15.25 → 12.5 → 11 → 10.5)
    var clapperGap = 7.5         // mm between the clapper and each tube at rest (= gap → 7 → 7.5)
    var clapperDamp = 0.72       // clapper damping × base rate (1.67 → 1.1 → 0.6 → 0.72, a fifth more)
    var tubeDamp = 0.54          // tube damping × base rate (0.67 → 0.54, a fifth less)
    var sensitivity = 0.342      // share of the wind force that reaches the set (0.5 → 0.4 → 0.36 → 0.342)
    var clapperDrag = 45.0       // how much faster the clapper damps at speed (25 → 18 → 45)
    var clapperFluct = 0.70      // share of the gusty wind the clapper feels (0.55 → 0.70)
    var clapperMean = 0.06       // share of the steady wind the clapper feels (0 → 0.06)
    var clapperMass = 0.8        // clapper mass × tube mass in a strike (2.5 → 0.8)
    var restitution = 0.38       // bounce left after a clapper strike (0.65 → 0.38)
    var velocityScale = 0.6      // soft velocity curve tanh(v / scale); 0 = the old linear ×2.5
    var windShadow = true        // windward tubes feel the flow, leeward ones its eddies (Oct 20)
    var ownTurbulence = true     // each tube and the clapper has turbulence of its own (Oct 20)
    var tuningDiversity = 1.0    // how much tube length and mass follow pitch: 0 all alike, 1 physical (Oct 20)
    var strikeScatter = true     // a clapper strike deflects its rebound a little off the line (Oct 20)
    var chordSeconds = 20.0      // seconds each chord of the Chord Seq scale lasts
    var chordSet = 0             // which of ChimePhysics.chordSets the Chord Seq scale cycles through
    var chordShuffle = false     // chords in a random order (never the same one twice running) instead of in turn

    mutating func apply(_ values: [String: Double]) {
        for (key, value) in values {
            switch key {
            case "steadyConstancy": steadyConstancy = value != 0
            case "collisionAtMid": collisionAtMid = value != 0
            case "prevailingWind": prevailingWind = value != 0
            case "gap": gap = max(2, value)
            case "clapperGap": clapperGap = max(1, value)
            case "clapperDamp": clapperDamp = max(0, value)
            case "tubeDamp": tubeDamp = max(0, value)
            case "sensitivity": sensitivity = max(0, value)
            case "clapperDrag": clapperDrag = max(0, value)
            case "clapperFluct": clapperFluct = max(0, value)
            case "clapperMean": clapperMean = max(0, value)
            case "clapperMass": clapperMass = max(0.05, value)
            case "restitution": restitution = max(0, min(1, value))
            case "velocityScale": velocityScale = max(0, value)
            case "windShadow": windShadow = value != 0
            case "ownTurbulence": ownTurbulence = value != 0
            case "tuningDiversity": tuningDiversity = max(0, min(2, value))
            case "strikeScatter": strikeScatter = value != 0
            case "chordSeconds": chordSeconds = max(2, value)
            case "chordSet": chordSet = max(0, min(ChimePhysics.chordSets.count - 1, Int(value.isFinite ? value.rounded() : 0)))
            case "chordShuffle": chordShuffle = value != 0
            default: break
            }
        }
    }

    var info: [String: Any] {
        ["steadyConstancy": steadyConstancy, "collisionAtMid": collisionAtMid, "prevailingWind": prevailingWind,
         "gap": gap, "clapperGap": clapperGap, "clapperDamp": clapperDamp, "tubeDamp": tubeDamp, "sensitivity": sensitivity, "clapperDrag": clapperDrag,
         "clapperFluct": clapperFluct, "clapperMean": clapperMean, "clapperMass": clapperMass,
         "restitution": restitution, "velocityScale": velocityScale,
         "windShadow": windShadow, "ownTurbulence": ownTurbulence, "tuningDiversity": tuningDiversity, "strikeScatter": strikeScatter,
         "chordSeconds": chordSeconds, "chordSet": chordSet, "chordShuffle": chordShuffle]
    }
}

struct ChimeStrike {
    let frequency: Double
    let velocity: Double   // 0–1, the soft curve the voice's sustain uses
    let speed: Double      // the approach speed in m/s, for the reference-fitted ting
    let isClapper: Bool
}

/// Top-down 2D pendulum model of the chime: a ring hanging from a fixed point, tubes
/// hanging from the ring, and a clapper disc hanging from the ring centre.
/// Ported from the original index.html tick() so the feel is unchanged.
final class ChimePhysics {
    static let g = 9.81
    static let dt = 1.0 / 120.0
    static let tubeR = 0.035 // tube radius in meters

    /// Semitone offsets above A4, fractional where a tuning falls between the piano's
    /// keys. "Chord Seq" cycles through one of chordSets instead, and "Custom" uses
    /// params.customScale.
    static let scales: [String: [Double]] = [
        "Pentatonic": [0, 3, 5, 7, 10],
        "Major Pent": [0, 2, 4, 7, 9],
        "Major": [0, 2, 4, 5, 7, 9, 11],
        "Minor": [0, 2, 3, 5, 7, 8, 10],
        "Dorian": [0, 2, 3, 5, 7, 9, 10],
        "Lydian": [0, 2, 4, 6, 7, 9, 11],
        "Mixolydian": [0, 2, 4, 5, 7, 9, 10],
        "Whole Tone": [0, 2, 4, 6, 8, 10],
        "Blues": [0, 3, 5, 6, 7, 10],
        "Hirajoshi": [0, 2, 3, 7, 8],
        "In Sen": [0, 1, 5, 7, 10],
        // Javanese gamelan. Slendro divides the octave into five near-equal steps of
        // 240 cents; pelog's steps are uneven, here the five-note bem selection of a
        // typical seven-note tuning (0, 120, 258, 675, 785 cents).
        "Slendro": [0, 2.4, 4.8, 7.2, 9.6],
        "Pelog": [0, 1.2, 2.58, 6.75, 7.85],
    ]
    // Chord sequences the "Chord Seq" scale cycles through, chosen in the Workshop by
    // index. Each chord is a set of semitone offsets from the root; tubes past the
    // sixth take the same notes an octave up.
    static let chordSets: [[[Int]]] = [
        // 0 Floating: minor ninths and elevenths that never quite resolve
        [
            [0, 3, 7, 10, 14, 17],   // im9add11 — tonic, open and floating
            [5, 8, 12, 15, 19, 22],  // iv9 — subdominant with ninth and eleventh
            [2, 5, 9, 12, 16, 21],   // II maj9 — bright borrowed chord
            [7, 10, 14, 17, 21, 24], // v11 — dominant suspended, unresolved
            [3, 7, 10, 14, 17, 22],  // IIImaj9 — warm mediant
            [8, 12, 15, 19, 22, 26], // VI9 — relative major with extensions
        ],
        // 1 Hymn: a plain major I–IV–vi–V, each chord with its ninth
        [
            [0, 4, 7, 11, 14, 19],   // Imaj9
            [5, 9, 12, 16, 19, 24],  // IVmaj9
            [9, 12, 16, 19, 23, 28], // vi9
            [7, 11, 14, 17, 21, 26], // V9
        ],
        // 2 Drift: a modal two-chord vamp, minor tonic against its major fourth
        [
            [0, 3, 7, 10, 14, 17],   // im9
            [5, 9, 12, 16, 19, 23],  // IV9
            [0, 3, 7, 10, 14, 19],   // im9, fifth on top
            [10, 14, 17, 21, 24, 29],// VIImaj9
        ],
        // 3 Drone: one tonic, breathing between an open and a warm voicing
        [
            [0, 7, 12, 14, 19, 24],  // open fifths and a ninth
            [0, 4, 7, 11, 14, 19],   // Imaj9
            [0, 2, 7, 9, 14, 19],    // sus2 with a sixth
        ],
    ]
    static let gustDuration = 2.0   // seconds a Gust button push lasts

    struct Pendulum { var ax = 0.0, vx = 0.0, ay = 0.0, vy = 0.0 }

    struct Tube {
        var ta = 0.0, tv = 0.0   // radial angle / angular velocity
        var tt = 0.0, tvT = 0.0  // tangential angle / angular velocity
        var lenFactor = 1.0
        var mass = 1.0
        var lastStrike = -1e9
    }

    private struct Tip { var x, y, vx, vy, len, rX, rY, tX, tY: Double }

    private enum WindPhase { case lull, rise, hold, fall }

    private(set) var params = ChimeParams()
    private(set) var ring = Pendulum()
    private(set) var striker = Pendulum()
    private(set) var tubes: [Tube] = []
    private(set) var strikeFlash: [Double] = []
    private(set) var ringRadius = 0.187
    private(set) var windX = 0.0, windY = 0.0
    // The wind without the gust button's push, so a gust adds to the wind once rather
    // than to its own remains tick after tick (with the wind off it used to pile up
    // thirty-fold)
    private var baseWindX = 0.0, baseWindY = 0.0
    private(set) var windSurge = 0.0 // mean wind speed (gust envelope with its texture), without turbulence
    private(set) var strikeCount = 0

    var onStrike: ((ChimeStrike) -> Void)?

    // Drive sources
    private(set) var windOn = false
    private(set) var motionOn = false
    var motionRawX = 0.0, motionRawY = 0.0
    private var motionX = 0.0, motionY = 0.0
    private var motionBaseX = 0.0, motionBaseY = 0.0
    private let motionGain = 1.0

    // Wind event model: discrete events separated by lulls. The wind has a prevailing
    // direction that veers only slowly, over minutes; each event blows from near it.
    private var prevailingAngle = Double.random(in: 0..<(2 * .pi))
    private var windAngle = 0.0, windSpeed = 0.0
    private var windMeanX = 0.0, windMeanY = 0.0
    private var noiseX = 0.0, noiseY = 0.0
    // Turbulence each element feels on its own, besides the shared gust: eddies shed by
    // the neighbours, with a shorter memory than the gust (0.5 s for tubes, 0.3 s for the
    // clapper in the ring's wake). This is what gives the set relative motion.
    private var tubeNoiseX: [Double] = [], tubeNoiseY: [Double] = []
    private var clapNoiseX = 0.0, clapNoiseY = 0.0
    private var turbAmpLast = 0.0
    private var calmDamp = 1.0
    private var evtPhase = WindPhase.lull
    private var evtT = 0.0
    private var evtLullDur = 35.0
    private var evtRiseDur = 0.0, evtHoldDur = 0.0, evtFallDur = 0.0
    private var evtPeak = 0.0, evtAngle = 0.0
    private var evtLullStill = false
    // Gusts within gusts: a wandering multiplier on the speed plus short sub-gust bursts
    private var textureOU = 0.0
    private var subGustT = 9.0, subGustDur = 1.0, subGustAmp = 0.0
    private var dropT = 9.0, dropDur = 1.0, dropAmp = 0.0

    private var chordIndex = 0
    private var chordTimer = 0.0
    private var gustX = 0.0, gustY = 0.0
    private var gustT = ChimePhysics.gustDuration
    private var simTime = 0.0

    init() {
        scheduleNextEvent()
        rebuild()
    }

    // MARK: - Controls

    func apply(_ newParams: ChimeParams) {
        let old = params
        params = newParams
        if newParams.tubeCount != old.tubeCount {
            rebuild()
        } else {
            if newParams.lab.gap != old.lab.gap { updateRingRadius() }
            if newParams.lab.chordSet != old.lab.chordSet { chordIndex = 0; chordTimer = 0 }
            if newParams.lab.tuningDiversity != old.lab.tuningDiversity || newParams.scale != old.scale
                || newParams.register != old.register || newParams.customScale != old.customScale
                || newParams.lab.chordSet != old.lab.chordSet {
                // Re-derive lengths and masses from pitch without resetting the swing
                let freqRef = tubeFrequency(tubes.count / 2)
                for i in tubes.indices {
                    let v = pow((freqRef / tubeFrequency(i)).squareRoot(), newParams.lab.tuningDiversity)
                    tubes[i].lenFactor = v; tubes[i].mass = v
                }
            }
        }
    }

    func startWind(resetState: Bool) {
        windOn = true
        windAngle = prevailingAngle
        if resetState {
            windSpeed = 0; noiseX = 0; noiseY = 0
            calmDamp = 1.0
        }
        // Skip the opening lull: the first gust starts rising at once, and the
        // 10-50 s lulls follow between events
        scheduleNextEvent()
        evtPhase = .rise
        evtT = 0
        windAngle = evtAngle
    }

    /// Physics off: wind stops and forces clear; the pendulums keep their state.
    func stopWind() {
        windOn = false
        windX = 0; windY = 0; windSurge = 0
        baseWindX = 0; baseWindY = 0
    }

    func selectMotion() {
        motionOn = true
        windOn = false
    }

    func selectWind(physicsOn: Bool) {
        if motionOn {
            motionOn = false
            motionX = 0; motionY = 0; motionRawX = 0; motionRawY = 0
        }
        if physicsOn { startWind(resetState: false) }
    }

    /// Single gust: a push in the current wind direction (random if wind is off) that
    /// rises quickly and dies away over gustDuration.
    func gust() {
        let strength = params.windStrength != 0 ? params.windStrength : 1.0
        let angle = windOn ? windAngle : rand() * .pi * 2
        let gustStrength = strength * (1.5 + rand())
        gustX = cos(angle) * gustStrength
        gustY = sin(angle) * gustStrength
        gustT = 0
    }

    func tubeFrequency(_ index: Int) -> Double {
        let semitone: Double
        if params.scale == "Chord Seq" {
            let chords = Self.chordSets[params.lab.chordSet]
            let chord = chords[chordIndex % chords.count]
            semitone = Double(chord[index % chord.count] + (index / chord.count) * 12)
        } else {
            let scale: [Double]
            if params.scale == "Custom" {
                let custom = params.customScale.filter { (0..<12).contains($0) }.sorted()
                scale = (custom.isEmpty ? [0] : custom).map(Double.init)
            } else {
                scale = Self.scales[params.scale] ?? Self.scales["Pentatonic"]!
            }
            semitone = scale[index % scale.count] + Double(index / scale.count) * 12
        }
        return 440 * pow(2, (semitone + params.register * 12) / 12)
    }

    /// True once nothing is moving: no wind or gust pushing, every pendulum near rest,
    /// and no strike in the last few seconds. Lets the engine go quiet with the wind off.
    var isSettled: Bool {
        if windOn || motionOn || gustT < Self.gustDuration { return false }
        if abs(ring.vx) + abs(ring.vy) + abs(striker.vx) + abs(striker.vy) > 0.02 { return false }
        for t in tubes {
            if abs(t.tv) + abs(t.tvT) > 0.02 || abs(t.ta) + abs(t.tt) > 0.02 { return false }
            if simTime - t.lastStrike < 4 { return false }
        }
        return true
    }

    func snapshot() -> [String: Any] {
        [
            "ring": [ring.ax, ring.ay],
            "striker": [striker.ax, striker.ay],
            "ta": tubes.map { $0.ta },
            "tt": tubes.map { $0.tt },
            "lenFactor": tubes.map { $0.lenFactor },
            "flash": strikeFlash,
            "ringRadius": ringRadius,
            "wind": [windX, windY], // the wind vector on the chimes, for the dust on screen
        ]
    }

    // MARK: - Setup

    private func rand() -> Double { Double.random(in: 0..<1) }
    private func gaussian() -> Double {
        var u = 0.0
        while u == 0 { u = rand() }
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * rand())
    }

    private func scheduleNextEvent() {
        // Most lulls are a light breeze; some go truly still, and those are shorter
        evtLullStill = rand() < params.stillLullChance
        evtLullDur = (evtLullStill ? 5 + rand() * 10 : 10 + rand() * 40) * params.lullScale
        let randomPeak = 0.2 + pow(rand(), 1.8) * 0.8         // weighted toward lighter events
        evtPeak = randomPeak + (0.75 - randomPeak) * params.peakBlend
        evtRiseDur = 0.8 + (1 - evtPeak) * 5 + rand() * 2    // stronger events rise faster
        evtHoldDur = (2 + rand() * 10) * params.holdScale
        evtFallDur = 1.5 + rand() * 8.5
        // From near the prevailing direction: within ~20° typically, tighter when constant
        evtAngle = params.lab.prevailingWind
            ? prevailingAngle + gaussian() * (0.35 - params.windConsistency * 0.2)
            : windAngle + (rand() - 0.5) * .pi * 0.6 // the old drift from the previous direction
        evtPhase = .lull
        evtT = 0
    }

    private func updateRingRadius() {
        let n = Double(max(1, params.tubeCount))
        let gapM = (params.gap * 0.5) / 1000
        ringRadius = (gapM + 2 * Self.tubeR) / (2 * sin(.pi / n))
    }

    private func rebuild() {
        let n = max(1, params.tubeCount)
        updateRingRadius()
        tubes = []
        strikeFlash = []
        // Tube length from pitch: f = K/L^2 => L ∝ 1/sqrt(f); mass ∝ length
        let freqRef = tubeFrequency(n / 2)
        for i in 0..<n {
            // tuningDiversity 0 makes every tube the middle one; 1 is the physical spread
            let lenVariation = pow((freqRef / tubeFrequency(i)).squareRoot(), params.lab.tuningDiversity)
            tubes.append(Tube(lenFactor: lenVariation, mass: lenVariation))
            strikeFlash.append(0)
        }
        tubeNoiseX = Array(repeating: 0, count: n)
        tubeNoiseY = Array(repeating: 0, count: n)
        ring = Pendulum()
        striker = Pendulum()
    }

    private func clampAngle(_ a: Double) -> Double { max(-.pi / 2, min(.pi / 2, a)) }

    private func emitStrike(_ index: Int, velocity: Double, speed: Double, isClapper: Bool) {
        onStrike?(ChimeStrike(frequency: tubeFrequency(index), velocity: velocity, speed: speed, isClapper: isClapper))
    }

    /// Strike velocity for the voice, 0–1, from an approach speed or impulse. A soft
    /// curve: `scale` is the speed at which it reaches about three quarters, and it
    /// never quite saturates, so only a hard blow brings in the full bright attack and
    /// ordinary strikes sit in the rounder middle of the voice.
    private func strikeVelocity(_ x: Double, scale: Double, linear: Double) -> Double {
        let s = params.lab.velocityScale
        return s > 0 ? tanh(x / (scale / 0.6 * s)) : min(1, x * linear) // the Lab can restore the old linear map
    }

    // MARK: - Tick

    func tick() {
        let p = params
        let G = Self.g, DT = Self.dt, tubeR = Self.tubeR
        let damping = p.damping
        let ringL = p.cordLength * 0.30
        let ringD = damping
        let tubeL = p.cordLength
        let tubeD = damping * p.lab.tubeDamp
        let n = tubes.count
        simTime += DT

        // ── Ring (housing) pendulum — only feels wind variation, not mean (prevents DC drift)
        let wSusc = p.sensitivity
        let ringWindX = ((windX - windMeanX) * 0.75 + windMeanX * 0.08) * wSusc
        let ringWindY = ((windY - windMeanY) * 0.75 + windMeanY * 0.08) * wSusc
        let ringAx = -(G / ringL) * sin(ring.ax) + ringWindX / ringL
        let ringAy = -(G / ringL) * sin(ring.ay) + ringWindY / ringL
        ring.vx += ringAx * DT; ring.vy += ringAy * DT
        ring.vx *= (1 - ringD * calmDamp); ring.vy *= (1 - ringD * calmDamp)
        ring.ax += ring.vx * DT; ring.ay += ring.vy * DT
        ring.ax = clampAngle(ring.ax)
        ring.ay = clampAngle(ring.ay)
        let rcx = sin(ring.ax) * ringL
        let rcy = sin(ring.ay) * ringL

        // ── Clapper disc — longer cord than tubes, strikes at tube midpoint. A light
        // disc with a lot of face: sheltered inside the ring it feels mostly the turbulent
        // variation and a little of the mean flow, and swings more freely than the heavy
        // tubes (damped less, and lighter than a tube when they meet).
        let strikerL = p.cordLength * 0.76
        let clapperD = damping * p.lab.clapperDamp
        let sEnergy = striker.vx * striker.vx + striker.vy * striker.vy
            + (striker.ax * striker.ax + striker.ay * striker.ay) * 0.15
        // A light disc has a lot of drag for its mass: a fast dash across the ring bleeds
        // off quickly, while slow drifting in light air stays nearly free
        let sDamp = min(0.12, clapperD * (1 + sEnergy * p.lab.clapperDrag))
        // With its own turbulence the clapper keeps most of the shared gust and gets quick
        // eddies of its own on top, so it isn't pumped along one line. Quick eddies move a
        // pendulum far less than slow ones of the same size, so they add, not replace.
        let clapShare = p.lab.ownTurbulence ? 0.8 : 1.0
        let clapOwn = p.lab.ownTurbulence ? 0.9 * turbAmpLast : 0
        let clapperWindX = ((windX - windMeanX) * p.lab.clapperFluct * clapShare + clapNoiseX * clapOwn * p.lab.clapperFluct + windMeanX * p.lab.clapperMean) * wSusc
        let clapperWindY = ((windY - windMeanY) * p.lab.clapperFluct * clapShare + clapNoiseY * clapOwn * p.lab.clapperFluct + windMeanY * p.lab.clapperMean) * wSusc
        let sAccX = -(G / strikerL) * sin(striker.ax) + clapperWindX / strikerL
        let sAccY = -(G / strikerL) * sin(striker.ay) + clapperWindY / strikerL
        striker.vx += sAccX * DT; striker.vy += sAccY * DT
        striker.vx *= (1 - sDamp * calmDamp); striker.vy *= (1 - sDamp * calmDamp)
        striker.ax += striker.vx * DT; striker.ay += striker.vy * DT
        striker.ax = clampAngle(striker.ax)
        striker.ay = clampAngle(striker.ay)
        let scx = rcx + sin(striker.ax) * strikerL
        let scy = rcy + sin(striker.ay) * strikerL
        let clapperR = max(0.005, ringRadius - tubeR - (p.clapperGap / 1000))

        // ── Tubes — each swings radially and tangentially from its mount on the ring
        for i in 0..<n {
            var t = tubes[i]
            let tLen = tubeL * t.lenFactor
            let tubeMass = t.mass

            let mountAngle = Double(i) / Double(n) * .pi * 2
            let mx = rcx + cos(mountAngle) * ringRadius
            let my = rcy + sin(mountAngle) * ringRadius
            let radX = -cos(mountAngle), radY = -sin(mountAngle)
            let tanX = -sin(mountAngle), tanY = cos(mountAngle)

            // Where this tube sits relative to the wind: +1 on the windward side, -1 in the
            // lee. Windward tubes take the flow; leeward ones sit in the eddies behind them.
            var meanShare = 1.0, fluctShare = 1.0
            if p.lab.windShadow && (windOn || motionOn) {
                let wMag = (windMeanX * windMeanX + windMeanY * windMeanY).squareRoot()
                if wMag > 1e-4 {
                    let facing = -(cos(mountAngle) * windMeanX + sin(mountAngle) * windMeanY) / wMag
                    meanShare = 0.4 + 0.6 * max(0, min(1, (facing + 1) / 2))
                    fluctShare = 0.8 + 0.5 * max(0, min(1, (1 - facing) / 2))
                }
            }
            let shared = 1.0
            let own = p.lab.ownTurbulence ? 0.8 * turbAmpLast : 0
            let tubeWindX = (((windX - windMeanX) * shared + tubeNoiseX[i] * own) * 0.85 * fluctShare + windMeanX * 0.06 * meanShare) * wSusc
            let tubeWindY = (((windY - windMeanY) * shared + tubeNoiseY[i] * own) * 0.85 * fluctShare + windMeanY * 0.06 * meanShare) * wSusc
            let windR = tubeWindX * radX + tubeWindY * radY
            let windT = tubeWindX * tanX + tubeWindY * tanY

            let ringAccX = ring.vx * 35, ringAccY = ring.vy * 35
            let ringCoupR = (ringAccX * radX + ringAccY * radY) * 0.15
            let ringCoupT = (ringAccX * tanX + ringAccY * tanY) * 0.15

            // Radial DOF
            let taccR = -(G / tLen) * sin(t.ta) + windR * 0.24 / (tLen * tubeMass) - ringCoupR / tLen
            t.tv += taccR * DT
            let eR = t.tv * t.tv + t.ta * t.ta * 0.15
            t.tv *= (1 - min(0.18, tubeD * calmDamp * (1 + eR * 25)))
            t.ta += t.tv * DT
            t.ta = clampAngle(t.ta)

            // Tangential DOF — side-to-side along ring circumference
            let taccT = -(G / tLen) * sin(t.tt) + windT * 0.24 / (tLen * tubeMass) - ringCoupT / tLen
            t.tvT += taccT * DT
            let eT = t.tvT * t.tvT + t.tt * t.tt * 0.15
            t.tvT *= (1 - min(0.18, tubeD * calmDamp * (1 + eT * 25)))
            t.tt += t.tvT * DT
            t.tt = clampAngle(t.tt)

            let midX = mx + sin(t.ta) * (tLen * 0.5) * radX + sin(t.tt) * (tLen * 0.5) * tanX
            let midY = my + sin(t.ta) * (tLen * 0.5) * radY + sin(t.tt) * (tLen * 0.5) * tanY

            // ── Clapper vs tube: disc centre vs tube midpoint
            let cdx = midX - scx, cdy = midY - scy
            let cDist = (cdx * cdx + cdy * cdy).squareRoot()
            let cStrikeDist = clapperR + tubeR
            let timeSince = simTime - t.lastStrike

            var struck: Double?
            if cDist < cStrikeDist && cDist > 0.0001 {
                let cnx = cdx / cDist, cny = cdy / cDist
                let tvx = t.tv * (tLen * 0.5) * radX + t.tvT * (tLen * 0.5) * tanX
                let tvy = t.tv * (tLen * 0.5) * radY + t.tvT * (tLen * 0.5) * tanY
                let cvx = striker.vx * strikerL
                let cvy = striker.vy * strikerL
                // Relative velocity along normal — positive means approaching
                let relVn = (cvx - tvx) * cnx + (cvy - tvy) * cny

                // Whatever else happens, the two are pushed apart: an overlap that lingered
                // (a rebound that still pointed inward, wind pressing the clapper on) used to
                // go uncorrected for the 150 ms after a strike and showed as a stuck, jittering
                // clapper
                let cOverlap = (cStrikeDist - cDist) * 0.5
                striker.ax -= (cOverlap * cnx) / strikerL
                striker.ay -= (cOverlap * cny) / strikerL
                t.ta += (cOverlap * cnx * radX + cOverlap * cny * radY) / (tLen * 0.5)
                t.tt += (cOverlap * cnx * tanX + cOverlap * cny * tanY) / (tLen * 0.5)

                if relVn > 0 && timeSince > 0.150 {
                    let clapperMass = tubeMass * p.lab.clapperMass
                    let restitution = p.lab.restitution
                    let impulse = (1 + restitution) * relVn / (1 / clapperMass + 1 / tubeMass)

                    striker.vx -= (impulse * cnx) / (clapperMass * strikerL)
                    striker.vy -= (impulse * cny) / (clapperMass * strikerL)
                    if p.lab.strikeScatter {
                        // Contact is never square on: the disc's edge and the cord's twist send
                        // the rebound a little off the line, up to ±20°, never back into the tube
                        let turn = (rand() - 0.5) * 0.7
                        let c = cos(turn), sn = sin(turn)
                        let vx = striker.vx, vy = striker.vy
                        striker.vx = vx * c - vy * sn
                        striker.vy = vx * sn + vy * c
                        let into = striker.vx * cnx + striker.vy * cny
                        if into > 0 { striker.vx -= into * cnx; striker.vy -= into * cny }
                    }
                    t.tv += (impulse * cnx * radX + impulse * cny * radY) / (tubeMass * tLen * 0.5)
                    t.tvT += (impulse * cnx * tanX + impulse * cny * tanY) / (tubeMass * tLen * 0.5)

                    let strikeVel = abs(relVn)
                    strikeCount += 1
                    strikeFlash[i] = min(1, strikeVel * 5)
                    t.lastStrike = simTime
                    struck = strikeVel
                }
            }

            // Decay flash — positive (clapper) and negative (collision) both decay toward 0
            let sf = strikeFlash[i]
            strikeFlash[i] = sf > 0 ? max(0, sf - 0.04) : min(0, sf + 0.04)
            tubes[i] = t

            if let strikeVel = struck {
                emitStrike(i, velocity: strikeVelocity(strikeVel, scale: 0.6, linear: 2.5), speed: strikeVel, isClapper: true)
            }
        }

        // ── Tube-tube collisions at the tubes' midpoints, where the clapper meets them
        // and where the screen draws them, so a clash shows as the circles touching
        var tips: [Tip] = []
        tips.reserveCapacity(n)
        let collisionDist = tubeR * 2
        for i in 0..<n {
            let t = tubes[i]
            let tL = tubeL * t.lenFactor * (p.lab.collisionAtMid ? 0.5 : 1.0)
            let mAng = Double(i) / Double(n) * .pi * 2
            let mx = rcx + cos(mAng) * ringRadius
            let my = rcy + sin(mAng) * ringRadius
            let rX = -cos(mAng), rY = -sin(mAng)
            let tX = -sin(mAng), tY = cos(mAng)
            tips.append(Tip(
                x: mx + sin(t.ta) * tL * rX + sin(t.tt) * tL * tX,
                y: my + sin(t.ta) * tL * rY + sin(t.tt) * tL * tY,
                vx: t.tv * tL * rX + t.tvT * tL * tX,
                vy: t.tv * tL * rY + t.tvT * tL * tY,
                len: tL, rX: rX, rY: rY, tX: tX, tY: tY))
        }

        for a in 0..<n {
            for b in (a + 1)..<max(a + 1, n) {
                var pa = tips[a], pb = tips[b]
                let dx = pb.x - pa.x, dy = pb.y - pa.y
                let dist2 = dx * dx + dy * dy
                if dist2 >= collisionDist * collisionDist || dist2 < 0.000001 { continue }

                let dist = dist2.squareRoot()
                let nx = dx / dist, ny = dy / dist // normal from a to b
                // Relative velocity of b minus a along normal: negative = approaching
                let relVn = (pb.vx - pa.vx) * nx + (pb.vy - pa.vy) * ny

                if relVn < 0 {
                    let restitution = 0.72
                    let mA = tubes[a].mass, mB = tubes[b].mass
                    // Mass-weighted impulse: heavier tube deflects less
                    let impulse = -(1 + restitution) * relVn / (1 / mA + 1 / mB)

                    tubes[a].tv -= (impulse * nx * pa.rX + impulse * ny * pa.rY) / (mA * pa.len)
                    tubes[a].tvT -= (impulse * nx * pa.tX + impulse * ny * pa.tY) / (mA * pa.len)
                    tubes[b].tv += (impulse * nx * pb.rX + impulse * ny * pb.rY) / (mB * pb.len)
                    tubes[b].tvT += (impulse * nx * pb.tX + impulse * ny * pb.tY) / (mB * pb.len)
                    pa.vx = tubes[a].tv * pa.len * pa.rX + tubes[a].tvT * pa.len * pa.tX
                    pa.vy = tubes[a].tv * pa.len * pa.rY + tubes[a].tvT * pa.len * pa.tY
                    pb.vx = tubes[b].tv * pb.len * pb.rX + tubes[b].tvT * pb.len * pb.tX
                    pb.vy = tubes[b].tv * pb.len * pb.rY + tubes[b].tvT * pb.len * pb.tY
                    tips[a] = pa
                    tips[b] = pb

                    if impulse > 0.002 {
                        strikeFlash[a] = -min(1, impulse * 5)
                        strikeFlash[b] = -min(1, impulse * 5)
                        strikeCount += 1
                        tubes[a].lastStrike = simTime
                        tubes[b].lastStrike = simTime
                        emitStrike(a, velocity: strikeVelocity(impulse, scale: 0.7, linear: 2.0), speed: abs(relVn), isClapper: false)
                        emitStrike(b, velocity: strikeVelocity(impulse, scale: 0.7, linear: 2.0), speed: abs(relVn), isClapper: false)
                    }
                }

                // Positional correction — push the tubes apart
                let overlap = (collisionDist - dist) * 0.5
                tubes[a].ta -= (overlap * nx * pa.rX + overlap * ny * pa.rY) / pa.len
                tubes[a].tt -= (overlap * nx * pa.tX + overlap * ny * pa.tY) / pa.len
                tubes[b].ta += (overlap * nx * pb.rX + overlap * ny * pb.rY) / pb.len
                tubes[b].tt += (overlap * nx * pb.tX + overlap * ny * pb.tY) / pb.len
            }
        }

        // ── Wind / motion forcing
        if windOn {
            // The prevailing direction veers slowly: a random walk of a few degrees a minute
            if p.lab.prevailingWind { prevailingAngle += gaussian() * DT.squareRoot() * 0.02 }
            let wStr = p.windStrength
            let wSteady = p.windSteady
            let wTurb = p.windTurb

            evtT += DT
            var targetSpeed = 0.0
            switch evtPhase {
            case .lull:
                if evtLullStill {
                    // Still: drain residual wind and apply extra physics damping
                    windSpeed *= 0.92
                    calmDamp = 3.0
                } else {
                    // Light breeze: the chimes drift and strike now and then
                    calmDamp = 1.0
                    windSpeed += (p.breezeSpeed - windSpeed) * 0.03
                }
                if evtT >= evtLullDur {
                    evtPhase = .rise; evtT = 0
                    windAngle = evtAngle
                }
            case .rise:
                calmDamp = 1.0
                let progress = min(1, evtT / evtRiseDur)
                targetSpeed = max(p.speedFloor, evtPeak * progress * progress) // ease in
                windSpeed += (targetSpeed - windSpeed) * 0.08
                if evtT >= evtRiseDur { evtPhase = .hold; evtT = 0 }
            case .hold:
                calmDamp = 1.0
                // Small internal variation — wind is never perfectly steady
                let wobble = p.holdWobble
                targetSpeed = evtPeak * (0.75 + 0.25 * (1 - wobble) + (sin(evtT * 1.3) * 0.15 + sin(evtT * 2.7) * 0.10) * wobble)
                if rand() < 0.005 * p.spikeChance { targetSpeed *= 1.4 + rand() * 0.6 } // occasional spike
                windSpeed += (targetSpeed - windSpeed) * 0.05
                // Wander about the event's direction without walking away from it
                windAngle += (p.lab.prevailingWind ? (evtAngle - windAngle) * 0.003 : 0) + (rand() - 0.5) * (1 - wSteady) * 0.04
                if evtT >= evtHoldDur { evtPhase = .fall; evtT = 0 }
            case .fall:
                calmDamp = 1.0
                let progress = max(0, 1 - evtT / evtFallDur)
                targetSpeed = max(p.speedFloor, evtPeak * progress)
                windSpeed += (targetSpeed - windSpeed) * 0.06
                if evtT >= evtFallDur { scheduleNextEvent() }
            }

            // Texture: an Ornstein-Uhlenbeck wander (τ 2.5 s) and sub-gusts (half-sine,
            // 0.6–2 s) on top of the event envelope, scaled by consistency
            let variation = p.gustVariation
            let tau = 2.5
            textureOU += (-textureOU / tau) * DT + (2 * DT / tau).squareRoot() * gaussian()
            textureOU = max(-2, min(2, textureOU))
            subGustT += DT
            if evtPhase != .lull && subGustT > subGustDur && rand() < DT / 5.0 {
                subGustT = 0
                subGustDur = 0.6 + rand() * 1.4
                subGustAmp = (0.3 + rand() * 0.5) * variation / 0.55
            }
            let subGust = subGustT < subGustDur ? subGustAmp * sin(.pi * subGustT / subGustDur) : 0
            // Drops: the wind falls away inside a gust for 1–3 s
            dropT += DT
            if evtPhase != .lull && dropT > dropDur && rand() < DT / 7.0 {
                dropT = 0
                dropDur = 1 + rand() * 2
                dropAmp = (0.6 + rand() * 0.2) * min(1, variation / 0.55)
            }
            let drop = dropT < dropDur ? dropAmp * sin(.pi * dropT / dropDur) : 0
            let texture = max(0.1, 1 + textureOU * variation * 0.5 + subGust - drop)

            windSpeed = max(0, min(1.5, windSpeed))
            let surge = windSpeed * texture * wStr
            let meanX = cos(windAngle) * surge
            let meanY = sin(windAngle) * surge

            // Turbulence: bounded (Ornstein-Uhlenbeck, τ 1 s) and proportional to the
            // wind, so a lull is calm. The original random walk never died down; the
            // amplitude here matches the fluctuating force it delivered during a gust
            // (~0.3 RMS at full strength), which is what the chimes couple to.
            let turbTau = 1.0
            noiseX += (-noiseX / turbTau) * DT + (2 * DT / turbTau).squareRoot() * gaussian()
            noiseY += (-noiseY / turbTau) * DT + (2 * DT / turbTau).squareRoot() * gaussian()
            let turbAmp = wTurb * (0.02 + surge) * 4.0
            turbAmpLast = turbAmp
            // Each tube's own eddies (0.5 s memory) and the clapper's (0.3 s)
            let tubeTau = 0.5, clapTau = 0.3
            for i in tubeNoiseX.indices {
                tubeNoiseX[i] += (-tubeNoiseX[i] / tubeTau) * DT + (2 * DT / tubeTau).squareRoot() * gaussian()
                tubeNoiseY[i] += (-tubeNoiseY[i] / tubeTau) * DT + (2 * DT / tubeTau).squareRoot() * gaussian()
            }
            clapNoiseX += (-clapNoiseX / clapTau) * DT + (2 * DT / clapTau).squareRoot() * gaussian()
            clapNoiseY += (-clapNoiseY / clapTau) * DT + (2 * DT / clapTau).squareRoot() * gaussian()

            windSurge = surge
            windX = meanX + noiseX * turbAmp
            windY = meanY + noiseY * turbAmp
            baseWindX = windX; baseWindY = windY
            windMeanX += (windX - windMeanX) * 0.003
            windMeanY += (windY - windMeanY) * 0.003
        } else if motionOn {
            // Smooth the raw acceleration into a force; a slow baseline makes the
            // phone's resting orientation read as zero so only sway and shake come through.
            motionX += (motionRawX - motionX) * 0.4
            motionY += (motionRawY - motionY) * 0.4
            motionBaseX += (motionX - motionBaseX) * 0.02
            motionBaseY += (motionY - motionBaseY) * 0.02
            // Scaled so a gentle sway lands around a moderate gust (the wind model's
            // forces are ~0.3), and capped so a shake can't turn violent
            let fx = (motionX - motionBaseX) * motionGain
            let fy = (motionY - motionBaseY) * motionGain
            var mx = -fx * 0.12, my = fy * 0.12
            let mag = (mx * mx + my * my).squareRoot()
            if mag > 0.6 { mx *= 0.6 / mag; my *= 0.6 / mag }
            windX = mx
            windY = my
            baseWindX = mx; baseWindY = my
            windSurge = 0
            turbAmpLast *= 0.9
            windMeanX *= 0.9
            windMeanY *= 0.9
        } else {
            baseWindX *= 0.97
            baseWindY *= 0.97
            windX = baseWindX
            windY = baseWindY
            windSurge *= 0.97
            turbAmpLast *= 0.97
            windMeanX *= 0.97
            windMeanY *= 0.97
        }

        // ── Gust button: a push on top of whatever is driving the chimes
        if gustT < Self.gustDuration {
            gustT += DT
            let rise = 0.25
            let envelope = gustT < rise
                ? gustT / rise
                : max(0, 1 - (gustT - rise) / (Self.gustDuration - rise))
            windX += gustX * envelope
            windY += gustY * envelope
        }

        // Advance chord progression
        if p.scale == "Chord Seq" {
            chordTimer += DT
            if chordTimer >= p.lab.chordSeconds {
                chordTimer = 0
                let count = Self.chordSets[p.lab.chordSet].count
                if p.lab.chordShuffle && count > 1 {
                    // Any chord but the one just played
                    var next = Int.random(in: 0..<(count - 1))
                    if next >= chordIndex % count { next += 1 }
                    chordIndex = next
                } else {
                    chordIndex = (chordIndex + 1) % count
                }
                // The new chord retunes the tubes, so their lengths and masses follow
                let freqRef = tubeFrequency(tubes.count / 2)
                for i in tubes.indices {
                    let v = pow((freqRef / tubeFrequency(i)).squareRoot(), p.lab.tuningDiversity)
                    tubes[i].lenFactor = v; tubes[i].mass = v
                }
            }
        }
    }
}
