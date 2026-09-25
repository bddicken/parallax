import Foundation

// All buffers here are interleaved stereo Float32 at `AudioFormat.sampleRate`.

public enum AudioFormat {
    public static let sampleRate: Double = 48_000
    public static let channels = 2

    public static func frames(forMilliseconds ms: Int) -> Int {
        Int((Double(ms) / 1000 * sampleRate).rounded())
    }
}

public func decibelsToLinear(_ db: Double) -> Float {
    Float(pow(10, db / 20))
}

public func linearToDecibels(_ value: Float) -> Float {
    value > 0.000_001 ? 20 * log10(value) : -120
}

public struct AudioLevel: Equatable, Sendable {
    public var peakDB: Float
    public var rmsDB: Float

    public init(peakDB: Float, rmsDB: Float) {
        self.peakDB = peakDB
        self.rmsDB = rmsDB
    }

    public static let silent = AudioLevel(peakDB: -120, rmsDB: -120)

    public static func measure(_ samples: UnsafeBufferPointer<Float>) -> AudioLevel {
        guard !samples.isEmpty else { return .silent }
        var peak: Float = 0
        var sumSquares: Float = 0
        for s in samples {
            peak = max(peak, abs(s))
            sumSquares += s * s
        }
        return AudioLevel(peakDB: linearToDecibels(peak), rmsDB: linearToDecibels((sumSquares / Float(samples.count)).squareRoot()))
    }

    /// Combines levels measured over consecutive windows.
    public func merged(with other: AudioLevel) -> AudioLevel {
        AudioLevel(peakDB: max(peakDB, other.peakDB), rmsDB: max(rmsDB, other.rmsDB))
    }
}

/// Fixed-capacity ring buffer of stereo frames. When full, the oldest frames
/// are overwritten.
public struct StereoFIFO: Sendable {
    public let capacity: Int
    public private(set) var count = 0
    private var storage: [Float]
    private var readFrame = 0

    public init(capacity: Int) {
        self.capacity = capacity
        storage = [Float](repeating: 0, count: capacity * 2)
    }

    public mutating func write(_ samples: UnsafeBufferPointer<Float>) {
        let frames = samples.count / 2
        var src = max(0, frames - capacity) // if the write alone overflows, keep its tail
        let overflow = count + (frames - src) - capacity
        if overflow > 0 { discard(overflow) }
        var writeFrame = (readFrame + count) % capacity
        while src < frames {
            let n = min(frames - src, capacity - writeFrame)
            for i in 0..<(n * 2) { storage[writeFrame * 2 + i] = samples[src * 2 + i] }
            src += n
            count += n
            writeFrame = (writeFrame + n) % capacity
        }
    }

    public mutating func appendSilence(_ frames: Int) {
        let zeros = [Float](repeating: 0, count: max(0, frames) * 2)
        zeros.withUnsafeBufferPointer { write($0) }
    }

    /// Reads up to `frames` into `out` and returns how many were read.
    @discardableResult
    public mutating func read(into out: UnsafeMutableBufferPointer<Float>, frames: Int) -> Int {
        let n = min(frames, count, out.count / 2)
        var done = 0
        while done < n {
            let chunk = min(n - done, capacity - readFrame)
            for i in 0..<(chunk * 2) { out[done * 2 + i] = storage[readFrame * 2 + i] }
            done += chunk
            readFrame = (readFrame + chunk) % capacity
        }
        count -= n
        return n
    }

    public mutating func discard(_ frames: Int) {
        let n = min(max(0, frames), count)
        readFrame = (readFrame + n) % capacity
        count -= n
    }
}

/// Buffers a capture device's audio so the mixer can pull fixed-size chunks
/// on its own clock, with a user-set delay on top.
///
/// Latency is held near `delayFrames + prebufferFrames`: on startup or after
/// an underrun it waits to refill; if the device clock runs fast and audio
/// piles up beyond `maxDriftFrames`, the excess is dropped.
public struct DelayBuffer: Sendable {
    public private(set) var fifo: StereoFIFO
    public private(set) var delayFrames = 0
    public let prebufferFrames: Int
    public let maxDriftFrames: Int
    public private(set) var isPrimed = false

    public init(
        capacity: Int = Int(AudioFormat.sampleRate * 3),
        prebufferFrames: Int = AudioFormat.frames(forMilliseconds: 30),
        maxDriftFrames: Int = AudioFormat.frames(forMilliseconds: 100)
    ) {
        fifo = StereoFIFO(capacity: capacity)
        self.prebufferFrames = prebufferFrames
        self.maxDriftFrames = maxDriftFrames
    }

    public var targetFrames: Int { delayFrames + prebufferFrames }

    public mutating func setDelay(frames: Int) {
        let clamped = min(max(0, frames), fifo.capacity - prebufferFrames - maxDriftFrames)
        if isPrimed {
            let change = clamped - delayFrames
            if change > 0 { fifo.appendSilence(change) } else { fifo.discard(-change) }
        }
        delayFrames = clamped
    }

    public mutating func write(_ samples: UnsafeBufferPointer<Float>) {
        fifo.write(samples)
    }

    /// Fills `out` with `frames` frames, padding with silence when not enough
    /// audio is buffered. Returns false if the output is entirely silence
    /// because the buffer is still priming.
    @discardableResult
    public mutating func read(into out: UnsafeMutableBufferPointer<Float>, frames: Int) -> Bool {
        if !isPrimed {
            guard fifo.count >= targetFrames else {
                zero(out, from: 0, frames: frames)
                return false
            }
            isPrimed = true
        }
        if fifo.count > targetFrames + maxDriftFrames {
            fifo.discard(fifo.count - targetFrames)
        }
        let n = fifo.read(into: out, frames: frames)
        if n < frames {
            zero(out, from: n, frames: frames)
            isPrimed = false
        }
        return true
    }

    private func zero(_ out: UnsafeMutableBufferPointer<Float>, from start: Int, frames: Int) {
        for i in (start * 2)..<min(frames * 2, out.count) { out[i] = 0 }
    }
}

/// RBJ-cookbook biquad applied independently to both channels.
public struct StereoBiquad: Sendable {
    private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var z1 = [Float](repeating: 0, count: 2)
    private var z2 = [Float](repeating: 0, count: 2)

    public static func highPass(cutoff: Double, q: Double = 0.707, sampleRate: Double = AudioFormat.sampleRate) -> StereoBiquad {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        return StereoBiquad(
            b0: Float((1 + cosw) / 2 / a0), b1: Float(-(1 + cosw) / a0), b2: Float((1 + cosw) / 2 / a0),
            a1: Float(-2 * cosw / a0), a2: Float((1 - alpha) / a0)
        )
    }

    /// Bell boost or cut of `gainDB` centered on `frequency`.
    public static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double = AudioFormat.sampleRate) -> StereoBiquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        return StereoBiquad(
            b0: Float((1 + alpha * a) / a0), b1: Float(-2 * cosw / a0), b2: Float((1 - alpha * a) / a0),
            a1: Float(-2 * cosw / a0), a2: Float((1 - alpha / a) / a0)
        )
    }

    private init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// Takes `other`'s coefficients but keeps this filter's state, so a
    /// setting can change mid-stream without a click.
    public mutating func retune(to other: StereoBiquad) {
        b0 = other.b0
        b1 = other.b1
        b2 = other.b2
        a1 = other.a1
        a2 = other.a2
    }

    /// Gain in dB at `frequency`.
    public func magnitudeDB(at frequency: Double, sampleRate: Double = AudioFormat.sampleRate) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let (b0, b1, b2, a1, a2) = (Double(b0), Double(b1), Double(b2), Double(a1), Double(a2))
        let numRe = b0 + b1 * c1 + b2 * c2, numIm = -(b1 * s1 + b2 * s2)
        let denRe = 1 + a1 * c1 + a2 * c2, denIm = -(a1 * s1 + a2 * s2)
        let power = (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm)
        return 10 * log10(max(power, 1e-12))
    }

    public mutating func process(_ buffer: UnsafeMutableBufferPointer<Float>) {
        for c in 0..<2 {
            var s1 = z1[c], s2 = z2[c]
            var i = c
            while i < buffer.count {
                let x = buffer[i]
                let y = b0 * x + s1
                s1 = b1 * x - a1 * y + s2
                s2 = b2 * x - a2 * y
                buffer[i] = y
                i += 2
            }
            z1[c] = s1
            z2[c] = s2
        }
    }
}

/// Ten peaking filters, one octave wide, at `EQSettings.frequencies`.
public struct GraphicEQ: Sendable {
    public static let q = 1.41

    private var bands: [StereoBiquad]

    public init(_ settings: EQSettings) {
        bands = Self.filters(for: settings)
    }

    public mutating func configure(_ settings: EQSettings) {
        for (i, filter) in Self.filters(for: settings).enumerated() { bands[i].retune(to: filter) }
    }

    public mutating func process(_ buffer: UnsafeMutableBufferPointer<Float>) {
        for i in bands.indices { bands[i].process(buffer) }
    }

    /// Combined gain of all bands at `frequency`, for drawing the curve.
    public static func responseDB(_ settings: EQSettings, at frequency: Double) -> Double {
        filters(for: settings).reduce(0) { $0 + $1.magnitudeDB(at: frequency) }
    }

    private static func filters(for settings: EQSettings) -> [StereoBiquad] {
        EQSettings.frequencies.indices.map { i in
            .peaking(frequency: EQSettings.frequencies[i], gainDB: settings.gain(band: i), q: q)
        }
    }
}

/// Mutes the signal while it stays below a threshold.
public struct NoiseGate: Sendable {
    public var thresholdLinear: Float
    private var envelope: Float = 0
    private var gain: Float = 0
    private var holdRemaining = 0
    private let holdFrames: Int
    private let envelopeDecay: Float
    private let attackCoef: Float
    private let releaseCoef: Float

    public init(thresholdDB: Double, sampleRate: Double = AudioFormat.sampleRate) {
        thresholdLinear = decibelsToLinear(thresholdDB)
        holdFrames = Int(0.15 * sampleRate)
        envelopeDecay = Float(exp(-1 / (0.01 * sampleRate)))
        attackCoef = Float(1 - exp(-1 / (0.002 * sampleRate)))
        releaseCoef = Float(1 - exp(-1 / (0.1 * sampleRate)))
    }

    public mutating func process(_ buffer: UnsafeMutableBufferPointer<Float>) {
        var i = 0
        while i + 1 < buffer.count {
            let peak = max(abs(buffer[i]), abs(buffer[i + 1]))
            envelope = max(peak, envelope * envelopeDecay)
            let open: Bool
            if envelope >= thresholdLinear {
                holdRemaining = holdFrames
                open = true
            } else if holdRemaining > 0 {
                holdRemaining -= 1
                open = true
            } else {
                open = false
            }
            let target: Float = open ? 1 : 0
            gain += (target - gain) * (open ? attackCoef : releaseCoef)
            buffer[i] *= gain
            buffer[i + 1] *= gain
            i += 2
        }
    }
}

/// Instant-attack peak limiter for the master bus, so a loud input clips
/// gracefully instead of wrapping in the encoder.
public struct PeakLimiter: Sendable {
    public var ceiling: Float = decibelsToLinear(-1)
    private var gain: Float = 1
    private let releaseCoef = Float(1 - exp(-1 / (0.15 * AudioFormat.sampleRate)))

    public init() {}

    public mutating func process(_ buffer: UnsafeMutableBufferPointer<Float>) {
        var i = 0
        while i + 1 < buffer.count {
            let peak = max(abs(buffer[i]), abs(buffer[i + 1]))
            gain += (1 - gain) * releaseCoef
            if peak * gain > ceiling { gain = ceiling / peak }
            buffer[i] *= gain
            buffer[i + 1] *= gain
            i += 2
        }
    }
}

/// Per-input processing chain: high-pass → gate → EQ → fader → mute.
public struct ChannelStripProcessor: Sendable {
    private var highPass: StereoBiquad?
    private var gate: NoiseGate?
    private var eq: GraphicEQ?
    private var gateThresholdDB: Double?
    private var gain: Float = 1
    private var targetGain: Float = 1
    private var muted = false
    private var muteGain: Float = 1
    private let smoothing = Float(1 - exp(-1 / (0.01 * AudioFormat.sampleRate)))

    public init(source: AudioSource) {
        configure(source)
        gain = targetGain
        muteGain = muted ? 0 : 1
    }

    public mutating func configure(_ source: AudioSource) {
        if source.highPassEnabled {
            if highPass == nil { highPass = .highPass(cutoff: 80) }
        } else {
            highPass = nil
        }
        if source.gate.isEnabled {
            if gate == nil || gateThresholdDB != source.gate.thresholdDB {
                gate = NoiseGate(thresholdDB: source.gate.thresholdDB)
                gateThresholdDB = source.gate.thresholdDB
            }
        } else {
            gate = nil
            gateThresholdDB = nil
        }
        if source.eq.isEnabled {
            if eq == nil { eq = GraphicEQ(source.eq) } else { eq?.configure(source.eq) }
        } else {
            eq = nil
        }
        targetGain = decibelsToLinear(source.gainDB)
        muted = source.isMuted
    }

    /// Processes in place. Returns the post-fader, pre-mute level so meters
    /// still move while an input is muted.
    public mutating func process(_ buffer: UnsafeMutableBufferPointer<Float>) -> AudioLevel {
        highPass?.process(buffer)
        gate?.process(buffer)
        eq?.process(buffer)
        let muteTarget: Float = muted ? 0 : 1
        var peak: Float = 0
        var sumSquares: Float = 0
        var i = 0
        while i + 1 < buffer.count {
            gain += (targetGain - gain) * smoothing
            muteGain += (muteTarget - muteGain) * smoothing
            for c in 0..<2 {
                let s = buffer[i + c] * gain
                peak = max(peak, abs(s))
                sumSquares += s * s
                buffer[i + c] = s * muteGain
            }
            i += 2
        }
        let rms = buffer.isEmpty ? 0 : (sumSquares / Float(buffer.count)).squareRoot()
        return AudioLevel(peakDB: linearToDecibels(peak), rmsDB: linearToDecibels(rms))
    }
}
