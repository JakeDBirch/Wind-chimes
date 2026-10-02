import Foundation

/// A short recording from the microphone, prepared so a strike can play it at any
/// pitch: silence trimmed, level normalized, the end crossfaded into the start so it
/// loops without a click, and its fundamental frequency estimated.
struct UserSample {
    let samples: [Float]
    let sampleRate: Double
    let pitch: Double     // estimated fundamental in Hz, or 0 if none was found
    let duration: Double  // seconds of the prepared loop

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

    // MARK: - Persistence

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    private static var pcmURL: URL { directory.appendingPathComponent("recording.pcm") }
    private static var metaURL: URL { directory.appendingPathComponent("recording.json") }

    private struct Meta: Codable { let sampleRate, pitch, duration: Double }

    func save() {
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: Self.pcmURL)
        if let meta = try? JSONEncoder().encode(Meta(sampleRate: sampleRate, pitch: pitch, duration: duration)) {
            try? meta.write(to: Self.metaURL)
        }
    }

    static func load() -> UserSample? {
        guard let data = try? Data(contentsOf: pcmURL),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: metaData) else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return nil }
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        return UserSample(samples: samples, sampleRate: meta.sampleRate, pitch: meta.pitch, duration: meta.duration)
    }
}
