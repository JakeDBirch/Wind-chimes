import Foundation

/// Settings the web controls send down. Defaults match the slider defaults in index.html.
struct ChimeParams {
    var windStrength = 0.3
    var windConsistency = 0.4 // 0 = gusty and shifting with long calms, 1 = a steady breeze
    var sensitivity = 0.5     // how much wind force reaches the chimes
    var tubeCount = 6
    var register = 0.0
    var scale = "Pentatonic"
    var windSoundGain = 0.1 // linear; 0 = off, 1 = full
    var windTightness = 0.6 // 0 = smooth, lagging impression; 1 = tracks the force almost directly
    var customScale = [0, 3, 5, 7, 10] // semitones above A, used when scale == "Custom"

    let cordLength = 0.53
    let gap = 15.25 // mm between tubes

    /// Velocity damping per step; the old slider's default, kept fixed
    let damping = 0.0015 * pow(6.667, 0.42)
    var windSteady: Double { windConsistency * 0.35 }
    var windTurb: Double { 0.5 - windConsistency * 0.4 }
    /// Scales the lulls between wind events: 1.5× at consistency 0, 0.5× at 1
    var lullScale: Double { 1.5 - windConsistency }
    /// How much the speed wanders within a gust: 0.25 at consistency 1, 0.75 at 0
    var gustVariation: Double { 0.25 + (1 - windConsistency) * 0.5 }
}

struct ChimeStrike {
    let frequency: Double
    let velocity: Double
    let isClapper: Bool
}

/// Top-down 2D pendulum model of the chime: a ring hanging from a fixed point, tubes
/// hanging from the ring, and a clapper disc hanging from the ring centre.
/// Ported from the original index.html tick() so the feel is unchanged.
final class ChimePhysics {
    static let g = 9.81
    static let dt = 1.0 / 120.0
    static let tubeR = 0.035 // tube radius in meters

    /// Semitone offsets above A4. "Chord Seq" cycles through chordProgression instead,
    /// and "Custom" uses params.customScale.
    static let scales: [String: [Int]] = [
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
    ]
    // Each chord is a set of semitone offsets from root
    static let chordProgression: [[Int]] = [
        [0, 3, 7, 10, 14, 17],   // im9add11 — tonic, open and floating
        [5, 8, 12, 15, 19, 22],  // iv9 — subdominant with ninth and eleventh
        [2, 5, 9, 12, 16, 21],   // II maj9 — bright borrowed chord
        [7, 10, 14, 17, 21, 24], // v11 — dominant suspended, unresolved
        [3, 7, 10, 14, 17, 22],  // IIImaj9 — warm mediant
        [8, 12, 15, 19, 22, 26], // VI9 — relative major with extensions
    ]
    static let chordDuration = 20.0 // seconds per chord
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

    // Wind event model: discrete events separated by lulls
    private var windAngle = 0.0, windSpeed = 0.0
    private var windMeanX = 0.0, windMeanY = 0.0
    private var noiseX = 0.0, noiseY = 0.0
    private var calmDamp = 1.0
    private var evtPhase = WindPhase.lull
    private var evtT = 0.0
    private var evtLullDur = 35.0
    private var evtRiseDur = 0.0, evtHoldDur = 0.0, evtFallDur = 0.0
    private var evtPeak = 0.0, evtAngle = 0.0
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
        }
    }

    func startWind(resetState: Bool) {
        windOn = true
        windAngle = rand() * .pi * 2
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
        let semitone: Int
        if params.scale == "Chord Seq" {
            let chord = Self.chordProgression[chordIndex % Self.chordProgression.count]
            semitone = chord[index % chord.count] + (index / chord.count) * 12
        } else {
            let scale: [Int]
            if params.scale == "Custom" {
                let custom = params.customScale.filter { (0..<12).contains($0) }.sorted()
                scale = custom.isEmpty ? [0] : custom
            } else {
                scale = Self.scales[params.scale] ?? Self.scales["Pentatonic"]!
            }
            semitone = scale[index % scale.count] + (index / scale.count) * 12
        }
        return 440 * pow(2, (Double(semitone) + params.register * 12) / 12)
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
        evtLullDur = (10 + rand() * 40) * params.lullScale   // lull: 10–50 s at mid consistency
        evtPeak = 0.2 + pow(rand(), 1.8) * 0.8               // weighted toward lighter events
        evtRiseDur = 0.8 + (1 - evtPeak) * 5 + rand() * 2    // stronger events rise faster
        evtHoldDur = 2 + rand() * 10
        evtFallDur = 1.5 + rand() * 8.5
        evtAngle = windAngle + (rand() - 0.5) * .pi * 0.6    // drift from previous direction
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
            let lenVariation = (freqRef / tubeFrequency(i)).squareRoot()
            tubes.append(Tube(lenFactor: lenVariation, mass: lenVariation))
            strikeFlash.append(0)
        }
        ring = Pendulum()
        striker = Pendulum()
    }

    private func clampAngle(_ a: Double) -> Double { max(-.pi / 2, min(.pi / 2, a)) }

    private func emitStrike(_ index: Int, velocity: Double, isClapper: Bool) {
        onStrike?(ChimeStrike(frequency: tubeFrequency(index), velocity: velocity, isClapper: isClapper))
    }

    // MARK: - Tick

    func tick() {
        let p = params
        let G = Self.g, DT = Self.dt, tubeR = Self.tubeR
        let damping = p.damping
        let ringL = p.cordLength * 0.30
        let ringD = damping
        let tubeL = p.cordLength
        let tubeD = damping * 0.67
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

        // ── Clapper disc — longer cord than tubes, strikes at tube midpoint.
        // Sheltered inside the ring: only feels turbulent variation, not mean flow.
        let strikerL = p.cordLength * 0.76
        let clapperD = damping * 1.67
        let sEnergy = striker.vx * striker.vx + striker.vy * striker.vy
            + (striker.ax * striker.ax + striker.ay * striker.ay) * 0.15
        let sDamp = min(0.10, clapperD * (1 + sEnergy * 25))
        let clapperWindX = (windX - windMeanX) * 0.55 * wSusc
        let clapperWindY = (windY - windMeanY) * 0.55 * wSusc
        let sAccX = -(G / strikerL) * sin(striker.ax) + clapperWindX / strikerL
        let sAccY = -(G / strikerL) * sin(striker.ay) + clapperWindY / strikerL
        striker.vx += sAccX * DT; striker.vy += sAccY * DT
        striker.vx *= (1 - sDamp * calmDamp); striker.vy *= (1 - sDamp * calmDamp)
        striker.ax += striker.vx * DT; striker.ay += striker.vy * DT
        striker.ax = clampAngle(striker.ax)
        striker.ay = clampAngle(striker.ay)
        let scx = rcx + sin(striker.ax) * strikerL
        let scy = rcy + sin(striker.ay) * strikerL
        let clapperR = max(0.005, ringRadius - tubeR - (p.gap / 1000))

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

            let tubeWindX = ((windX - windMeanX) * 0.85 + windMeanX * 0.06) * wSusc
            let tubeWindY = ((windY - windMeanY) * 0.85 + windMeanY * 0.06) * wSusc
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
            if cDist < cStrikeDist && cDist > 0.0001 && timeSince > 0.150 {
                let cnx = cdx / cDist, cny = cdy / cDist
                let tvx = t.tv * (tLen * 0.5) * radX + t.tvT * (tLen * 0.5) * tanX
                let tvy = t.tv * (tLen * 0.5) * radY + t.tvT * (tLen * 0.5) * tanY
                let cvx = striker.vx * strikerL
                let cvy = striker.vy * strikerL
                // Relative velocity along normal — positive means approaching
                let relVn = (cvx - tvx) * cnx + (cvy - tvy) * cny

                if relVn > 0 {
                    let clapperMass = tubeMass * 2.5
                    let restitution = 0.65
                    let impulse = (1 + restitution) * relVn / (1 / clapperMass + 1 / tubeMass)

                    striker.vx -= (impulse * cnx) / (clapperMass * strikerL)
                    striker.vy -= (impulse * cny) / (clapperMass * strikerL)
                    t.tv += (impulse * cnx * radX + impulse * cny * radY) / (tubeMass * tLen * 0.5)
                    t.tvT += (impulse * cnx * tanX + impulse * cny * tanY) / (tubeMass * tLen * 0.5)

                    let cOverlap = (cStrikeDist - cDist) * 0.5
                    striker.ax -= (cOverlap * cnx) / strikerL
                    striker.ay -= (cOverlap * cny) / strikerL
                    t.ta += (cOverlap * cnx * radX + cOverlap * cny * radY) / (tLen * 0.5)
                    t.tt += (cOverlap * cnx * tanX + cOverlap * cny * tanY) / (tLen * 0.5)

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
                emitStrike(i, velocity: strikeVel * 2.5, isClapper: true)
            }
        }

        // ── Tube-tube collisions, using fresh tip positions and velocities
        var tips: [Tip] = []
        tips.reserveCapacity(n)
        let collisionDist = tubeR * 2
        for i in 0..<n {
            let t = tubes[i]
            let tL = tubeL * t.lenFactor
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
                        emitStrike(a, velocity: impulse * 2, isClapper: false)
                        emitStrike(b, velocity: impulse * 2, isClapper: false)
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
            let wStr = p.windStrength
            let wSteady = p.windSteady
            let wTurb = p.windTurb

            evtT += DT
            var targetSpeed = 0.0
            switch evtPhase {
            case .lull:
                // Silence — drain residual wind and apply extra physics damping
                windSpeed *= 0.92
                calmDamp = 3.0
                if evtT >= evtLullDur {
                    evtPhase = .rise; evtT = 0
                    windAngle = evtAngle
                }
            case .rise:
                calmDamp = 1.0
                let progress = min(1, evtT / evtRiseDur)
                targetSpeed = evtPeak * progress * progress // ease in
                windSpeed += (targetSpeed - windSpeed) * 0.08
                if evtT >= evtRiseDur { evtPhase = .hold; evtT = 0 }
            case .hold:
                calmDamp = 1.0
                // Small internal variation — wind is never perfectly steady
                targetSpeed = evtPeak * (0.75 + sin(evtT * 1.3) * 0.15 + sin(evtT * 2.7) * 0.10)
                if rand() < 0.005 { targetSpeed *= 1.4 + rand() * 0.6 } // occasional spike
                windSpeed += (targetSpeed - windSpeed) * 0.05
                windAngle += (rand() - 0.5) * (1 - wSteady) * 0.04     // slow angle drift
                if evtT >= evtHoldDur { evtPhase = .fall; evtT = 0 }
            case .fall:
                calmDamp = 1.0
                let progress = max(0, 1 - evtT / evtFallDur)
                targetSpeed = evtPeak * progress
                windSpeed += (targetSpeed - windSpeed) * 0.06
                if evtT >= evtFallDur {
                    windSpeed = 0
                    scheduleNextEvent()
                }
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

            windSurge = surge
            windX = meanX + noiseX * turbAmp
            windY = meanY + noiseY * turbAmp
            windMeanX += (windX - windMeanX) * 0.003
            windMeanY += (windY - windMeanY) * 0.003
        } else if motionOn {
            // Smooth the raw acceleration into a force; a slow baseline makes the
            // phone's resting orientation read as zero so only sway and shake come through.
            motionX += (motionRawX - motionX) * 0.4
            motionY += (motionRawY - motionY) * 0.4
            motionBaseX += (motionX - motionBaseX) * 0.02
            motionBaseY += (motionY - motionBaseY) * 0.02
            let fx = (motionX - motionBaseX) * motionGain
            let fy = (motionY - motionBaseY) * motionGain
            windX = -fx * 0.5
            windY = fy * 0.5
            windSurge = 0
            windMeanX *= 0.9
            windMeanY *= 0.9
        } else {
            windX *= 0.97
            windY *= 0.97
            windSurge *= 0.97
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
            if chordTimer >= Self.chordDuration {
                chordTimer = 0
                chordIndex = (chordIndex + 1) % Self.chordProgression.count
            }
        }
    }
}
