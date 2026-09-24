import CoreMedia
import Foundation
import QuartzCore

/// Carries a non-Sendable value (CVPixelBuffer, CMSampleBuffer, …) across a
/// queue hop where we know only one side touches it at a time.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Seconds on the host clock, shared by capture, compositor, mixer, and recorder.
@inline(__always) func hostNow() -> Double { CACurrentMediaTime() }

extension CMTime {
    init(hostSeconds: Double) {
        self.init(seconds: hostSeconds, preferredTimescale: 1_000_000_000)
    }
}

/// Anything that consumes the program output: the recorder today, the uplink
/// to parallax-server later. Called from the compositor and mixer queues.
public protocol MediaSink: AnyObject, Sendable {
    func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime)
    /// Interleaved stereo Float32 at 48 kHz. Only valid for the duration of the call.
    func appendAudio(_ samples: UnsafeBufferPointer<Float>, frameCount: Int, pts: CMTime)
}

/// Thread-safe list of sinks that the compositor and mixer fan out to.
final class SinkHub: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [ObjectIdentifier: MediaSink] = [:]

    func add(_ sink: MediaSink) { lock.withLock { sinks[ObjectIdentifier(sink)] = sink } }
    func remove(_ sink: MediaSink) { lock.withLock { _ = sinks.removeValue(forKey: ObjectIdentifier(sink)) } }
    var all: [MediaSink] { lock.withLock { Array(sinks.values) } }
}

public struct MediaError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
