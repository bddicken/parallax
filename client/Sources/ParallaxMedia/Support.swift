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

/// Thread-safe list of sinks that the compositor and mixer fan out to. Every
/// sink gets the audio mix; each gets the video of the program or of one scene.
final class SinkHub: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [ObjectIdentifier: (sink: MediaSink, sceneID: UUID?)] = [:]

    /// `sceneID` nil for the program.
    func add(_ sink: MediaSink, sceneID: UUID? = nil) { add([(sink, sceneID)]) }
    func remove(_ sink: MediaSink) { remove([sink]) }

    /// Adds several at once, so they all receive the same first frame.
    func add(_ entries: [(sink: MediaSink, sceneID: UUID?)]) {
        lock.withLock { for e in entries { sinks[ObjectIdentifier(e.sink)] = e } }
    }

    /// Removes several at once, so they all receive the same last frame.
    func remove(_ entries: [MediaSink]) {
        lock.withLock { for s in entries { _ = sinks.removeValue(forKey: ObjectIdentifier(s)) } }
    }

    var all: [MediaSink] { lock.withLock { sinks.values.map(\.sink) } }

    /// Sinks grouped by the video they want; the nil key is the program.
    var byScene: [UUID?: [MediaSink]] {
        lock.withLock { Dictionary(grouping: sinks.values, by: \.sceneID).mapValues { $0.map(\.sink) } }
    }
}

public struct MediaError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
