import Foundation

/// A short recording from the microphone, prepared so a strike can play it at any
/// pitch: silence trimmed, level normalized, its fundamental frequency estimated, and
/// shaped like a sampler's note: the start plays once, then a short sustain segment
/// loops for as long as the note rings (see makeLoop).
struct UserSample {
    var id = UUID().uuidString
    var name = ""
    let samples: [Float]
    let sampleRate: Double
    let pitch: Double     // estimated fundamental in Hz, or 0 if none was found
    let duration: Double  // seconds of the recording after trimming
    let loudness: Double  // playback gain evening out dense vs sparse material, see loudnessGain
    let loopStart: Int    // playback wraps from the end of `samples` back to here

    /// What the page needs to list or describe a sample
    var info: [String: Any] { ["id": id, "name": name, "pitch": pitch, "duration": duration] }

    static let minimumDuration = 0.08

    enum PrepareError: Error { case tooQuiet }

    /// Turns a raw recording into a playable sample.
    static func prepare(_ raw: [Float], sampleRate sr: Double) throws -> UserSample {
        // Trim leading and trailing silence (below -40 dB of the peak)
        let peak = raw.reduce(0) { max($0, abs($1)) }
        guard peak > 0.005 else { throw PrepareError.tooQuiet }
        let threshold = peak * 0.01
        guard let first = raw.firstIndex(where: { abs($0) > threshold }),
              let last = raw.lastIndex(where: { abs($0) > threshold }) else { throw PrepareError.tooQuiet }
        // Keep a few ms of lead-in so the attack isn't clipped
        let lead = Int(sr * 0.005)
        var s = Array(raw[max(0, first - lead)...last])
        guard Double(s.count) / sr >= minimumDuration else { throw PrepareError.tooQuiet }

        // Normalize to peak, which is what keeps the file clean of clipping
        let gain = 0.9 / peak
        for i in s.indices { s[i] *= gain }

        // Short fade-in so the loop start is clean
        let fade = min(Int(sr * 0.01), s.count / 4)
        for i in 0..<fade { s[i] *= Float(i) / Float(fade) }

        let pitch = estimatePitch(s, sampleRate: sr)
        let duration = Double(s.count) / sr
        let loudness = loudnessGain(s)
        let loopStart = makeLoop(&s, sampleRate: sr, pitch: pitch)

        return UserSample(samples: s, sampleRate: sr, pitch: pitch, duration: duration,
                          loudness: loudness, loopStart: loopStart)
    }

    /// Turns the recording into a one-shot head followed by a loop, the way a sampler
    /// holds a note. Looping the whole recording made a delay effect at high pitches,
    /// where the attack came round several times a second. The loop is a short stretch
    /// of the sound's body, about 120 ms and a whole number of pitch periods when the
    /// pitch is known, so the repetition sits on the note's own frequency and is not
    /// heard as rhythm. Its last half is crossfaded into the material that leads into
    /// it, so the wrap is seamless. Drops the samples after the loop; returns loopStart.
    static func makeLoop(_ s: inout [Float], sampleRate sr: Double, pitch: Double) -> Int {
        let n = s.count
        var loopLen: Int
        if pitch > 0 {
            let period = sr / pitch
            let periods = max(2, Int((0.12 * sr / period).rounded()))
            loopLen = Int((Double(periods) * period).rounded())
        } else {
            loopLen = Int(sr * 0.25)
        }
        loopLen = max(2, min(loopLen, n / 2))
        let loopStart = min(Int(Double(n) * 0.3), n - loopLen)
        let loopEnd = loopStart + loopLen
        let x = min(loopLen / 2, loopStart)
        for k in 0..<x {
            let w = Float(k) / Float(x)
            let a = cos(w * .pi / 2), b = sin(w * .pi / 2)
            let i = loopEnd - x + k
            let j = loopStart - x + k
            s[i] = s[i] * a + s[j] * b
        }
        s.removeSubrange(loopEnd..<n)
        return loopStart
    }

    /// Playback gain that evens out loudness between dense material (a clean tone, RMS
    /// near its peak) and sparse material (a breathy voice, RMS well below it) without
    /// touching the peak-normalized data: 1x for dense, up to 3x for sparse.
    static func loudnessGain(_ samples: [Float]) -> Double {
        var sum = 0.0
        for x in samples { sum += Double(x * x) }
        let rms = (sum / Double(max(1, samples.count))).squareRoot()
        guard rms > 1e-6 else { return 1 }
        return min(3, max(1, 0.5 / rms))
    }

    /// Fundamental frequency by normalized autocorrelation over a window from the
    /// middle of the sound. Picks the shortest lag that scores close to the best, which
    /// avoids landing an octave low.
    static func estimatePitch(_ s: [Float], sampleRate sr: Double) -> Double {
        let window = min(4096, s.count / 2)
        let minLag = max(2, Int(sr / 2000)), maxLag = Int(sr / 40)
        guard window > maxLag + 16 else { return 0 }
        let start = (s.count - window - maxLag) / 2
        let x = Array(s[start..<(start + window + maxLag)])

        var energy = 0.0
        for i in 0..<window { energy += Double(x[i] * x[i]) }
        guard energy > 0 else { return 0 }

        var scores = [Double](repeating: 0, count: maxLag + 1)
        var best = 0.0
        for lag in minLag...maxLag {
            var dot = 0.0, lagEnergy = 0.0
            for i in 0..<window {
                let b = Double(x[i + lag])
                dot += Double(x[i]) * b
                lagEnergy += b * b
            }
            let r = lagEnergy > 0 ? dot / (energy * lagEnergy).squareRoot() : 0
            scores[lag] = r
            best = max(best, r)
        }
        guard best > 0.5 else { return 0 }

        // First local peak that comes within 10% of the best score
        for lag in (minLag + 1)..<maxLag {
            let r = scores[lag]
            if r >= best * 0.9 && r >= scores[lag - 1] && r >= scores[lag + 1] {
                // Parabolic interpolation around the peak
                let a = scores[lag - 1], c = scores[lag + 1]
                let denom = a - 2 * r + c
                let offset = denom != 0 ? 0.5 * (a - c) / denom : 0
                return sr / (Double(lag) + offset)
            }
        }
        return 0
    }

}

/// Samples on disk: the last take (so it survives a relaunch unsaved) and the bank the
/// user has saved to. Each sample is a .pcm of Float32 plus an entry in bank.json.
enum SampleBank {
    struct Meta: Codable {
        var id: String
        var name: String
        var sampleRate: Double
        var pitch: Double
        var duration: Double
        var created: Double
        var loopStart: Int? // absent for samples saved before the head-plus-loop layout

        var info: [String: Any] { ["id": id, "name": name, "pitch": pitch, "duration": duration] }
    }

    private static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var indexURL: URL { directory.appendingPathComponent("bank.json") }
    private static var takeMetaURL: URL { directory.appendingPathComponent("take.json") }
    private static func pcmURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".pcm") }

    static func list() -> [Meta] {
        guard let data = try? Data(contentsOf: indexURL),
              let metas = try? JSONDecoder().decode([Meta].self, from: data) else { return [] }
        return metas
    }

    private static func writeList(_ metas: [Meta]) {
        if let data = try? JSONEncoder().encode(metas) { try? data.write(to: indexURL) }
    }

    private static func meta(for sample: UserSample) -> Meta {
        Meta(id: sample.id, name: sample.name, sampleRate: sample.sampleRate, pitch: sample.pitch,
             duration: sample.duration, created: Date().timeIntervalSince1970, loopStart: sample.loopStart)
    }

    private static func writePCM(_ sample: UserSample) {
        let data = sample.samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: pcmURL(sample.id))
    }

    private static func load(_ meta: Meta) -> UserSample? {
        guard let data = try? Data(contentsOf: pcmURL(meta.id)) else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return nil }
        var samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        let loudness = UserSample.loudnessGain(samples)
        // Older entries hold the whole recording as the loop; give them the new layout
        let loopStart = meta.loopStart ?? UserSample.makeLoop(&samples, sampleRate: meta.sampleRate, pitch: meta.pitch)
        return UserSample(id: meta.id, name: meta.name, samples: samples, sampleRate: meta.sampleRate,
                          pitch: meta.pitch, duration: meta.duration, loudness: loudness, loopStart: loopStart)
    }

    /// Adds a sample to the bank, or renames it if it's already there.
    static func save(_ sample: UserSample) -> Meta {
        var metas = list()
        let m = meta(for: sample)
        if let i = metas.firstIndex(where: { $0.id == sample.id }) {
            metas[i].name = sample.name
        } else {
            writePCM(sample)
            metas.append(m)
        }
        writeList(metas)
        return m
    }

    static func load(id: String) -> UserSample? {
        list().first { $0.id == id }.flatMap(load)
    }

    static func delete(id: String) {
        var metas = list()
        metas.removeAll { $0.id == id }
        writeList(metas)
        try? FileManager.default.removeItem(at: pcmURL(id))
    }

    static func saveTake(_ sample: UserSample) {
        if let old = loadTakeMeta(), old.id != sample.id, !list().contains(where: { $0.id == old.id }) {
            try? FileManager.default.removeItem(at: pcmURL(old.id))
        }
        writePCM(sample)
        if let data = try? JSONEncoder().encode(meta(for: sample)) { try? data.write(to: takeMetaURL) }
    }

    private static func loadTakeMeta() -> Meta? {
        guard let data = try? Data(contentsOf: takeMetaURL) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    static func loadTake() -> UserSample? { loadTakeMeta().flatMap(load) }
}
