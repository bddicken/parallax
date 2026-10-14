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

/// Which version of the output a sink gets.
enum OutputFeed: Hashable, Sendable {
    /// Everything: the preview and the stream.
    case program
    /// The program minus sources left out of the recording (music, chat
    /// overlays, …).
    case recording
    /// One scene on its own, whatever is live, minus sources left out of
    /// the recording. Gets the recording's audio.
    case scene(UUID)
}

/// Thread-safe list of sinks that the compositor and mixer fan out to.
final class SinkHub: @unchecked Sendable {
    struct Feeds {
        var program: [MediaSink] = []
        var recording: [MediaSink] = []
        var scenes: [UUID: [MediaSink]] = [:]

        /// Everything that gets the recording's audio mix.
        var recordingAudio: [MediaSink] { recording + scenes.values.joined() }
    }

    private let lock = NSLock()
    private var sinks: [ObjectIdentifier: (sink: MediaSink, feed: OutputFeed)] = [:]

    func add(_ sink: MediaSink, feed: OutputFeed = .program) { add([(sink, feed)]) }
    func remove(_ sink: MediaSink) { remove([sink]) }

    /// Adds several at once, so they all get the same first frame.
    func add(_ entries: [(sink: MediaSink, feed: OutputFeed)]) {
        lock.withLock { for e in entries { sinks[ObjectIdentifier(e.sink)] = e } }
    }

    /// Removes several at once, so they all get the same last frame.
    func remove(_ entries: [MediaSink]) {
        lock.withLock { for s in entries { _ = sinks.removeValue(forKey: ObjectIdentifier(s)) } }
    }

    /// The sinks on each feed.
    var byFeed: Feeds {
        lock.withLock {
            var feeds = Feeds()
            for (sink, feed) in sinks.values {
                switch feed {
                case .program: feeds.program.append(sink)
                case .recording: feeds.recording.append(sink)
                case .scene(let id): feeds.scenes[id, default: []].append(sink)
                }
            }
            return feeds
        }
    }
}

public struct MediaError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
