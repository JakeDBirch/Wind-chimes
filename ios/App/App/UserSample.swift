import Foundation

/// A short recording from the microphone, prepared so a strike can play it at any
/// pitch: silence trimmed, level normalized, the end crossfaded into the start so it
/// loops without a click, and its fundamental frequency estimated.
struct UserSample {
    var id = UUID().uuidString
    var name = ""
    let samples: [Float]
    let sampleRate: Double
    let pitch: Double     // estimated fundamental in Hz, or 0 if none was found
    let duration: Double  // seconds of the prepared loop

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

        // Normalize
        let gain = 0.9 / peak
        for i in s.indices { s[i] *= gain }

        // Short fade-in so the loop start is clean
        let fade = min(Int(sr * 0.01), s.count / 4)
        for i in 0..<fade { s[i] *= Float(i) / Float(fade) }

        let pitch = estimatePitch(s, sampleRate: sr)

        // Crossfade the tail into the head so the sample loops seamlessly
        let n = s.count
        let x = min(Int(sr * 0.08), n / 4)
        let m = n - x
        var looped = Array(s[0..<m])
        for i in (m - x)..<m {
            let w = Float(i - (m - x)) / Float(x)
            let a = cos(w * .pi / 2), b = sin(w * .pi / 2)
            looped[i] = s[i] * a + s[i - (m - x)] * b
        }

        return UserSample(samples: looped, sampleRate: sr, pitch: pitch, duration: Double(m) / sr)
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
             duration: sample.duration, created: Date().timeIntervalSince1970)
    }

    private static func writePCM(_ sample: UserSample) {
        let data = sample.samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: pcmURL(sample.id))
    }

    private static func load(_ meta: Meta) -> UserSample? {
        guard let data = try? Data(contentsOf: pcmURL(meta.id)) else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return nil }
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        return UserSample(id: meta.id, name: meta.name, samples: samples, sampleRate: meta.sampleRate,
                          pitch: meta.pitch, duration: meta.duration)
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
