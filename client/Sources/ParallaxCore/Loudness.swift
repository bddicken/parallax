import Foundation

/// Integrated loudness per ITU-R BS.1770 (K-weighted, gated), in LUFS. Used
/// to play every song in the music library at about the same loudness.
/// Feed it interleaved stereo at 48 kHz.
public struct LoudnessMeter: Sendable {
    private var filters: [[Biquad]] = [[.kShelf, .kHighPass], [.kShelf, .kHighPass]]
    private var sum = 0.0
    private var count = 0
    /// Mean square (both channels summed) of each 100 ms stretch; gating
    /// blocks are four of these (400 ms, 75% overlap).
    private var steps: [Double] = []
    private static let stepFrames = AudioFormat.frames(forMilliseconds: 100)

    public init() {}

    public mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        var i = 0
        while i + 1 < samples.count {
            let l = filters[0][1].process(filters[0][0].process(Double(samples[i])))
            let r = filters[1][1].process(filters[1][0].process(Double(samples[i + 1])))
            sum += l * l + r * r
            count += 1
            if count == Self.stepFrames {
                steps.append(sum / Double(count))
                sum = 0
                count = 0
            }
            i += 2
        }
    }

    /// Nil until at least 400 ms has been added, or if it's all silence.
    public var integratedLoudness: Double? {
        guard steps.count >= 4 else { return nil }
        let blocks = (3..<steps.count).map { (steps[$0 - 3] + steps[$0 - 2] + steps[$0 - 1] + steps[$0]) / 4 }
        let loud = blocks.filter { Self.lufs($0) > -70 }
        guard !loud.isEmpty else { return nil }
        let relativeGate = Self.lufs(loud.reduce(0, +) / Double(loud.count)) - 10
        let gated = loud.filter { Self.lufs($0) > relativeGate }
        return Self.lufs(gated.reduce(0, +) / Double(gated.count))
    }

    private static func lufs(_ meanSquare: Double) -> Double {
        -0.691 + 10 * log10(max(meanSquare, 1e-12))
    }

    /// Double precision so the very low K-weighting high-pass stays accurate.
    private struct Biquad: Sendable {
        let b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0

        // BS.1770's published 48 kHz coefficients.
        static let kShelf = Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                                   a1: -1.69065929318241, a2: 0.73248077421585)
        static let kHighPass = Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621)

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
}

/// Turns music down while you talk: down quickly when a microphone gets
/// loud, held through short pauses between words, then eased back up.
public struct Ducker: Sendable {
    /// A microphone louder than this (RMS over a 10 ms chunk) counts as talking.
    public static let thresholdDB: Float = -40

    private var gain: Float = 1
    private var holdFrames = 0
    private let attack = Float(1 - exp(-1 / (0.04 * AudioFormat.sampleRate)))
    private let release = Float(1 - exp(-1 / (0.5 * AudioFormat.sampleRate)))
    private let hold = AudioFormat.frames(forMilliseconds: 500)

    public init() {}

    public var gainDB: Float { linearToDecibels(gain) }

    /// Processes in place. `keyDB` is the loudest unmuted microphone's RMS
    /// over the same stretch of time.
    public mutating func process(_ buffer: UnsafeMutableBufferPointer<Float>, keyDB: Float, settings: DuckSettings) {
        let frames = buffer.count / 2
        if settings.isEnabled, keyDB > Self.thresholdDB {
            holdFrames = hold
        } else {
            holdFrames = max(0, holdFrames - frames)
        }
        let target: Float = settings.isEnabled && holdFrames > 0 ? decibelsToLinear(settings.amountDB) : 1
        let coef = target < gain ? attack : release
        var i = 0
        while i + 1 < buffer.count {
            gain += (target - gain) * coef
            buffer[i] *= gain
            buffer[i + 1] *= gain
            i += 2
        }
    }
}
