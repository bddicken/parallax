import AVFoundation
import Foundation
import ParallaxCore

/// Plays songs into the mixer. The mixer pulls audio on its own clock, so
/// there's no drift or buffering to tune; a background queue decodes a couple
/// of seconds ahead, and the next song follows the current one with no gap.
///
/// Starting, skipping, pausing, and seeking fade briefly so nothing clicks.
public final class SongPlayer: AudioPullSource, @unchecked Sendable {
    public struct Item: Sendable, Equatable {
        public var id: UUID
        public var url: URL
        public var gainDB: Double

        public init(id: UUID, url: URL, gainDB: Double) {
            self.id = id
            self.url = url
            self.gainDB = gainDB
        }
    }

    public enum Event: Sendable, Equatable {
        /// A song became audible (not sent for seeking within one).
        case started(UUID)
        /// The last song ended and nothing follows it.
        case stopped
        case failed(UUID, String)
    }

    /// A song's place in the stream of decoded audio.
    private struct Segment {
        var item: Item
        /// Stream frame where it starts.
        var startFrame: Int64
        /// Where in the song it starts (after a seek).
        var offset: Double
        var announce: Bool
    }

    private struct Request {
        var item: Item
        var offset: Double
        var announce: Bool
    }

    private static let bufferedFrames = Int(AudioFormat.sampleRate * 2)
    private static let skipFade = Float(1 / (0.03 * AudioFormat.sampleRate))
    private static let pauseFade = Float(1 / (0.25 * AudioFormat.sampleRate))
    private let gainSmoothing = Float(1 - exp(-1 / (0.05 * AudioFormat.sampleRate)))

    // Shared state, guarded by `lock`.
    private let lock = NSLock()
    private var fifo = StereoFIFO(capacity: Int(AudioFormat.sampleRate * 3))
    private var framesWritten: Int64 = 0
    private var framesRead: Int64 = 0
    private var segments: [Segment] = []
    private var current: Segment?
    /// Bumped whenever buffered audio is thrown away, so the decoder knows to start over.
    private var generation = 0
    private var request: Request?
    private var upcoming: Item?
    /// The last song handed to the decoder; `upcoming` follows it.
    private var tailID: UUID?
    /// The decoder reached the end of the last song with nothing queued.
    private var decoderFinished = true
    private var wantsPause = false
    /// Waiting for the fade-out before switching; a nil request means stop.
    private var pendingSwitch: Request??
    private var fade: Float = 1
    private var fadeTarget: Float = 1
    private var fadeStep = SongPlayer.skipFade
    private var trackGain: Float = 1
    private var trackGainTarget: Float = 1
    private var eventHandler: (@MainActor @Sendable (Event) -> Void)?

    // Decoder state, only touched on `decodeQueue`.
    private let decodeQueue = DispatchQueue(label: "parallax.music-decode", qos: .userInitiated)
    private var decodeTimer: DispatchSourceTimer?
    private var decoderGeneration = -1
    private var reader: TrackReader?

    public init() {
        let timer = DispatchSource.makeTimerSource(queue: decodeQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(40))
        timer.setEventHandler { [weak self] in self?.decode() }
        timer.resume()
        decodeTimer = timer
    }

    deinit {
        decodeTimer?.cancel()
    }

    /// Called on the main queue.
    public var onEvent: (@MainActor @Sendable (Event) -> Void)? {
        get { lock.withLock { eventHandler } }
        set { lock.withLock { eventHandler = newValue } }
    }

    // MARK: Control

    /// Plays `item` from `offset` seconds, fading out whatever is playing.
    public func play(_ item: Item, from offset: Double = 0) {
        switchTo(Request(item: item, offset: max(0, offset), announce: true))
    }

    public func stop() {
        switchTo(nil)
    }

    public func pause() {
        lock.withLock {
            wantsPause = true
            fadeTarget = 0
            fadeStep = Self.pauseFade
        }
    }

    public func resume() {
        lock.withLock {
            wantsPause = false
            if pendingSwitch == nil {
                fadeTarget = 1
                fadeStep = Self.pauseFade
            }
        }
    }

    /// Jumps within the current song, staying paused if it is.
    public func seek(to seconds: Double) {
        guard let item = lock.withLock({ current?.item }) else { return }
        switchTo(Request(item: item, offset: max(0, seconds), announce: false))
    }

    /// What follows song `previous`. Ignored if that's no longer the last
    /// song queued, e.g. the decoder already moved on to the one set before.
    public func setUpcoming(_ item: Item?, after previous: UUID) {
        lock.withLock {
            guard tailID == previous else { return }
            upcoming = item
            // Something's playing and the decoder already ran out: wake it.
            if item != nil, decoderFinished, current != nil || !segments.isEmpty { decoderFinished = false }
        }
        decodeQueue.async { [weak self] in self?.decode() }
    }

    /// Changes a song's volume, live if it's playing.
    public func setGain(_ gainDB: Double, for id: UUID) {
        lock.withLock {
            if current?.item.id == id {
                current?.item.gainDB = gainDB
                trackGainTarget = decibelsToLinear(gainDB)
            }
            for i in segments.indices where segments[i].item.id == id { segments[i].item.gainDB = gainDB }
            if upcoming?.id == id { upcoming?.gainDB = gainDB }
        }
    }

    public var currentID: UUID? { lock.withLock { current?.item.id } }
    public var isPaused: Bool { lock.withLock { wantsPause } }

    /// Seconds into the current song.
    public var position: Double {
        lock.withLock {
            guard let current else { return 0 }
            return current.offset + Double(framesRead - current.startFrame) / AudioFormat.sampleRate
        }
    }

    private func switchTo(_ request: Request?) {
        let now = lock.withLock { () -> Bool in
            // Picking a song (or stopping) unpauses; seeking doesn't.
            if request?.announce ?? true { wantsPause = false }
            // Nothing audible: no need to fade.
            if current == nil, fifo.count == 0 {
                switchNow(request)
                return true
            }
            pendingSwitch = .some(request)
            fadeTarget = 0
            fadeStep = Self.skipFade
            return false
        }
        if now { decodeQueue.async { [weak self] in self?.decode() } }
    }

    /// Drops buffered audio and points the decoder at `request`. Call with `lock` held.
    private func switchNow(_ request: Request?) {
        fifo.discard(fifo.count)
        framesWritten = framesRead
        segments = []
        current = nil
        generation += 1
        self.request = request
        upcoming = nil
        tailID = request?.item.id
        decoderFinished = request == nil
        pendingSwitch = nil
        fade = 0
        fadeTarget = wantsPause ? 0 : 1
        fadeStep = Self.skipFade
    }

    // MARK: Rendering (mixer queue)

    func render(into out: UnsafeMutableBufferPointer<Float>, frames n: Int) {
        var events: [Event] = []
        var switched = false
        let handler = lock.withLock { () -> (@MainActor @Sendable (Event) -> Void)? in
            var done = 0
            while done < n {
                if fifo.count == 0, fadeTarget == 0 { fade = 0 }
                if let request = pendingSwitch, fade == 0 {
                    let stopping = request == nil && current != nil
                    switchNow(request)
                    if stopping { events.append(.stopped) }
                    switched = true
                    continue
                }
                if let next = segments.first, next.startFrame <= framesRead {
                    segments.removeFirst()
                    current = next
                    trackGainTarget = decibelsToLinear(next.item.gainDB)
                    trackGain = trackGainTarget
                    if next.announce { events.append(.started(next.item.id)) }
                    continue
                }
                if wantsPause, fade == 0 { break }
                guard fifo.count > 0 else {
                    if decoderFinished, current != nil, segments.isEmpty {
                        current = nil
                        events.append(.stopped)
                    }
                    break
                }
                var chunk = min(n - done, fifo.count)
                if let next = segments.first { chunk = min(chunk, Int(next.startFrame - framesRead)) }
                let slice = UnsafeMutableBufferPointer(rebasing: out[(done * 2)..<((done + chunk) * 2)])
                fifo.read(into: slice, frames: chunk)
                var i = 0
                while i + 1 < slice.count {
                    fade = fade < fadeTarget ? min(fadeTarget, fade + fadeStep) : max(fadeTarget, fade - fadeStep)
                    trackGain += (trackGainTarget - trackGain) * gainSmoothing
                    let gain = fade * fade * trackGain
                    slice[i] *= gain
                    slice[i + 1] *= gain
                    i += 2
                }
                framesRead += Int64(chunk)
                done += chunk
            }
            for i in (done * 2)..<(n * 2) { out[i] = 0 }
            return eventHandler
        }
        if switched { decodeQueue.async { [weak self] in self?.decode() } }
        if let handler, !events.isEmpty {
            DispatchQueue.main.async { for event in events { handler(event) } }
        }
    }

    // MARK: Decoding (decode queue)

    private func decode() {
        let (gen, request) = lock.withLock { (generation, self.request) }
        if gen != decoderGeneration {
            decoderGeneration = gen
            reader = nil
            if let request { open(request) }
        }
        while true {
            guard let reader else {
                guard let next = takeUpcoming() else { return }
                open(Request(item: next, offset: 0, announce: true))
                continue
            }
            let room = lock.withLock { generation == decoderGeneration ? Self.bufferedFrames - fifo.count : 0 }
            guard room > 0 else { return }
            let samples = (try? reader.read(frames: min(room, 4800))) ?? []
            if samples.isEmpty {
                self.reader = nil
                continue
            }
            let stale = lock.withLock { () -> Bool in
                guard generation == decoderGeneration else { return true }
                samples.withUnsafeBufferPointer { fifo.write($0) }
                framesWritten += Int64(samples.count / 2)
                return false
            }
            if stale { return }
        }
    }

    /// The song queued to follow, or nil once there's nothing left to decode.
    private func takeUpcoming() -> Item? {
        lock.withLock {
            guard generation == decoderGeneration, !decoderFinished else { return nil }
            guard let next = upcoming else {
                decoderFinished = true
                return nil
            }
            upcoming = nil
            tailID = next.id
            return next
        }
    }

    private func open(_ request: Request) {
        do {
            let reader = try TrackReader.openBlocking(url: request.item.url, from: request.offset)
            let isCurrent = lock.withLock { () -> Bool in
                guard generation == decoderGeneration else { return false }
                segments.append(Segment(item: request.item, startFrame: framesWritten, offset: request.offset,
                                        announce: request.announce))
                return true
            }
            if isCurrent { self.reader = reader }
        } catch {
            let handler = lock.withLock { generation == decoderGeneration ? eventHandler : nil }
            let event = Event.failed(request.item.id, error.localizedDescription)
            if let handler { DispatchQueue.main.async { handler(event) } }
        }
    }
}

/// Reads an audio file as interleaved stereo Float32 at 48 kHz.
///
/// Uses AVAssetReader rather than AVAudioFile: Suno's downloads are Opus in
/// fragmented MP4, which AVAudioFile reports as zero-length and throws an
/// Objective-C exception (uncatchable in Swift) when seeking in.
final class TrackReader: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pending: [Float] = []
    private var pendingStart = 0

    private static var outputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioFormat.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    static func open(url: URL, from seconds: Double = 0) async throws -> TrackReader {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MediaError("\(url.lastPathComponent) has no audio.")
        }
        return try TrackReader(asset: asset, track: track, from: seconds, name: url.lastPathComponent)
    }

    /// `open` for a dispatch queue that may block (the player's decode
    /// queue), never one of Swift concurrency's threads.
    static func openBlocking(url: URL, from seconds: Double) throws -> TrackReader {
        let result = BlockingResult()
        Task.detached {
            do { result.value = .success(try await open(url: url, from: seconds)) } catch { result.value = .failure(error) }
            result.done.signal()
        }
        result.done.wait()
        return try result.value!.get()
    }

    private final class BlockingResult: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var value: Result<TrackReader, Error>?
    }

    private init(asset: AVAsset, track: AVAssetTrack, from seconds: Double, name: String) throws {
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaError("\(name) is in a format Parallax can't play.") }
        reader.add(output)
        if seconds > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 48_000), duration: .positiveInfinity)
        }
        guard reader.startReading() else {
            throw reader.error ?? MediaError("Couldn't read \(name).")
        }
    }

    deinit {
        reader.cancelReading()
    }

    /// Up to `frames` frames; empty at the end of the file.
    func read(frames: Int) throws -> [Float] {
        while pending.count - pendingStart < frames * 2 {
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed { throw reader.error ?? MediaError("Reading the song failed.") }
                break
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let old = pending.count
            pending.append(contentsOf: repeatElement(0, count: bytes / MemoryLayout<Float>.size))
            _ = pending.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes,
                                           destination: buffer.baseAddress! + old * MemoryLayout<Float>.size)
            }
        }
        let count = min(frames * 2, pending.count - pendingStart)
        let out = Array(pending[pendingStart..<(pendingStart + count)])
        pendingStart += count
        if pendingStart >= 1 << 16 || pendingStart == pending.count {
            pending.removeFirst(pendingStart)
            pendingStart = 0
        }
        return out
    }
}
