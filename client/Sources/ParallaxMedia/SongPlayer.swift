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
            let reader = try TrackReader(url: request.item.url, from: request.offset)
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

/// Reads an audio file as interleaved stereo Float32 at 48 kHz. Used by one
/// queue at a time; Sendable only so the converter's input block can use it.
final class TrackReader: @unchecked Sendable {
    private let file: AVAudioFile
    private let converter: AVAudioConverter?
    private let input: AVAudioPCMBuffer
    private let outputFormat: AVAudioFormat
    private var reachedEnd = false
    private var finished = false

    init(url: URL, from seconds: Double = 0) throws {
        file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFormat.sampleRate,
                                         channels: min(format.channelCount, 2), interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw MediaError("Couldn't read \(url.lastPathComponent).")
        }
        outputFormat = target
        self.input = input
        if format.sampleRate == target.sampleRate, format.channelCount == target.channelCount,
           format.commonFormat == .pcmFormatFloat32, !format.isInterleaved {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: format, to: target) else {
                throw MediaError("\(url.lastPathComponent) is in a format Parallax can't play.")
            }
            self.converter = converter
        }
        file.framePosition = min(file.length, AVAudioFramePosition(seconds * format.sampleRate))
    }

    /// Length in seconds.
    var duration: Double { Double(file.length) / file.processingFormat.sampleRate }

    /// Up to `frames` frames; empty at the end of the file.
    func read(frames: Int) throws -> [Float] {
        guard !finished, frames > 0 else { return [] }
        let pcm: AVAudioPCMBuffer
        if let converter {
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return [] }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { [self] _, status in
                if reachedEnd {
                    status.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: input.frameCapacity)
                } catch {
                    reachedEnd = true
                }
                if input.frameLength == 0 {
                    reachedEnd = true
                    status.pointee = .endOfStream
                    return nil
                }
                status.pointee = .haveData
                return input
            }
            if let error { throw error }
            if status == .endOfStream || status == .error { finished = true }
            pcm = out
        } else {
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return [] }
            try file.read(into: out, frameCount: AVAudioFrameCount(frames))
            if out.frameLength == 0 { finished = true }
            pcm = out
        }
        return Self.interleave(pcm)
    }

    private static func interleave(_ pcm: AVAudioPCMBuffer) -> [Float] {
        let count = Int(pcm.frameLength)
        guard count > 0, let channels = pcm.floatChannelData else { return [] }
        let left = channels[0]
        let right = pcm.format.channelCount > 1 ? channels[1] : left
        var out = [Float](repeating: 0, count: count * 2)
        for i in 0..<count {
            out[i * 2] = left[i]
            out[i * 2 + 1] = right[i]
        }
        return out
    }
}
