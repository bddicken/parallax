import AVFoundation
import Foundation
import HaishinKit
import os
import ParallaxCore
import SRTHaishinKit
import VideoToolbox

private let log = Logger(subsystem: "com.bddicken.parallax", category: "uplink")

public enum UplinkState: Sendable, Equatable {
    case connecting
    case sending
    /// Couldn't connect or lost the connection; retrying.
    case retrying(String)
}

/// Sends the program output to parallax-server: HaishinKit encodes it
/// (VideoToolbox H.264 + AAC) and sends MPEG-TS over SRT. Reconnects on its
/// own until stopped. Frames that arrive while disconnected are dropped.
///
/// While sending, it reports `UplinkStats` once a second, and (with
/// `StreamSettings.adaptiveBitrate`) turns the video bitrate down while the
/// stream is behind, here or at the server's relays (`setRelayLag`).
public final class Uplink: MediaSink, @unchecked Sendable {
    public let encodedSize: CGSize

    /// What the sending task shares with the threads that feed it.
    private final class Shared: @unchecked Sendable {
        private let lock = NSLock()
        private var _droppedFrames = 0
        private var _relay = (lagMs: 0, kbps: 0)
        var droppedFrames: Int { lock.withLock { _droppedFrames } }
        var relay: (lagMs: Int, kbps: Int) {
            get { lock.withLock { _relay } }
            set { lock.withLock { _relay = newValue } }
        }
        func dropFrame() { lock.withLock { _droppedFrames += 1 } }
    }

    private let shared = Shared()

    private enum Item {
        case video(CMSampleBuffer)
        case audio(AVAudioPCMBuffer, AVAudioTime)
    }

    private let items: AsyncStream<Unchecked<Item>>.Continuation
    private let task: Task<Void, Never>
    private let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFormat.sampleRate,
                                            channels: AVAudioChannelCount(AudioFormat.channels), interleaved: true)!
    private let lock = NSLock()
    private var videoFormat: CMVideoFormatDescription?

    init(url: URL, stream: StreamSettings, output: OutputSettings, onState: @escaping @Sendable (UplinkState) -> Void,
         onStats: @escaping @Sendable (UplinkStats) -> Void = { _ in }) {
        let size = stream.resolution.size(for: output)
        encodedSize = CGSize(width: size.width, height: size.height)
        let video = VideoCodecSettings(
            videoSize: encodedSize,
            bitRate: stream.videoBitrateKbps * 1000,
            profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
            scalingMode: .letterbox,
            bitRateMode: .constant,
            maxKeyFrameIntervalDuration: Int32(stream.keyframeIntervalSeconds),
            // No B-frames: lower latency, and simpler for every hop to the platforms.
            allowFrameReordering: false,
            expectedFrameRate: Double(output.fps)
        )
        let audio = AudioCodecSettings(bitRate: stream.audioBitrateKbps * 1000)
        // A few frames of slack; anything older is stale while reconnecting.
        let (items, continuation) = AsyncStream.makeStream(of: Unchecked<Item>.self, bufferingPolicy: .bufferingNewest(16))
        self.items = continuation
        let controller = stream.adaptiveBitrate ? BitrateController(fullKbps: stream.videoBitrateKbps) : nil
        task = Task.detached(priority: .userInitiated) { [shared] in
            await Self.run(url: url, video: video, audio: audio, items: items, shared: shared, controller: controller,
                           onState: onState, onStats: onStats)
        }
    }

    /// How far the server's slowest relay is behind real time and the
    /// bitrate it's sending at, from its status. Adaptive bitrate counts the
    /// lag like a backlog here: with the built-in server, the relays are
    /// what use the upload.
    public func setRelayLag(ms: Int, kbps: Int) {
        shared.relay = (ms, kbps)
    }

    public func stop() {
        items.finish()
        task.cancel()
    }

    /// Stops and waits up to `timeout` for the connection to close, so the
    /// server learns right away that video stopped (otherwise it waits for a
    /// timeout). Blocks; for app quit.
    public func stopAndWait(timeout: TimeInterval) {
        stop()
        let closed = DispatchSemaphore(value: 0)
        let task = task
        Task.detached {
            await task.value
            closed.signal()
        }
        _ = closed.wait(timeout: .now() + timeout)
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let format = format(for: pixelBuffer) else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        // A full queue gives up its oldest item to take this one.
        if case .dropped(let old) = items.yield(Unchecked(.video(sample))), case .video = old.value {
            shared.dropFrame()
        }
    }

    public func appendAudio(_ samples: UnsafeBufferPointer<Float>, frameCount: Int, pts: CMTime) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let dest = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        dest.update(from: samples.baseAddress!, count: frameCount * AudioFormat.channels)
        let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: pts.seconds))
        if case .dropped(let old) = items.yield(Unchecked(.audio(buffer, when))), case .video = old.value {
            shared.dropFrame()
        }
    }

    /// The compositor reuses a few buffer sizes, so cache the description.
    private func format(for pixelBuffer: CVPixelBuffer) -> CMVideoFormatDescription? {
        lock.withLock {
            if let videoFormat, CMVideoFormatDescriptionMatchesImageBuffer(videoFormat, imageBuffer: pixelBuffer) {
                return videoFormat
            }
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
            videoFormat = format
            return format
        }
    }

    private static func run(url: URL, video: VideoCodecSettings, audio: AudioCodecSettings,
                            items: AsyncStream<Unchecked<Item>>, shared: Shared, controller: BitrateController?,
                            onState: @Sendable (UplinkState) -> Void, onStats: @Sendable (UplinkStats) -> Void) async {
        var iterator = items.makeAsyncIterator()
        var backoff = 1.0
        // Kept across reconnects, so a new connection starts at the bitrate
        // the last one could carry.
        var video = video, controller = controller
        let fullKbps = video.bitRate / 1000
        while !Task.isCancelled {
            onState(.connecting)
            let connection = SRTConnection()
            let stream = SRTStream(connection: connection)
            do {
                try await stream.setVideoSettings(video)
                try await stream.setAudioSettings(audio)
                await stream.setExpectedMedias([.video, .audio])
                try await connection.connect(url)
            } catch {
                await connection.close()
                onState(.retrying(Self.describe(error)))
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 15)
                continue
            }
            await stream.publish()
            onState(.sending)
            let connectedAt = CACurrentMediaTime()
            var checkedAt = connectedAt
            var meter = LinkMeter(at: connectedAt)
            // Feed frames in order until the stream ends or the connection drops.
            while let item = await iterator.next() {
                switch item.value {
                case .video(let sample): await stream.append(sample)
                case .audio(let buffer, let when): await stream.append(buffer, when: when)
                }
                let now = CACurrentMediaTime()
                if now - checkedAt > 0.5 {
                    checkedAt = now
                    if await !connection.connected { break }
                }
                if now - meter.readAt >= 1, let perf = await connection.performanceData {
                    let link = meter.read(perf, at: now)
                    let relay = shared.relay
                    // A relay that's behind is sending as fast as its
                    // platform takes it. Leave room for audio and for the
                    // connection to wobble.
                    let relayStrains = Double(relay.lagMs) >= StreamStrain.relayLagLimitMs
                        && Double(link.backlogMs) < StreamStrain.backlogLimitMs && relay.kbps > 0
                    let fit = relayStrains ? Int(Double(relay.kbps) * 0.8) - audio.bitRate / 1000 : nil
                    if let target = controller?.update(
                        strain: StreamStrain.of(backlogMs: link.backlogMs, relayLagMs: relay.lagMs),
                        dropping: link.droppedPackets > 0, fitKbps: fit), target * 1000 != video.bitRate {
                        log.info("video bitrate \(video.bitRate / 1000) → \(target) kbps (backlog \(link.backlogMs) ms, relay \(relay.lagMs) ms behind at \(relay.kbps) kbps)")
                        video.bitRate = target * 1000
                        // Only the bitrate changed, which the encoder takes without restarting.
                        try? await stream.setVideoSettings(video)
                    }
                    onStats(UplinkStats(sentKbps: link.sentKbps, videoKbps: video.bitRate / 1000, fullVideoKbps: fullKbps,
                                        rttMs: link.rttMs, lossPercent: link.lossPercent, backlogMs: link.backlogMs,
                                        droppedFrames: shared.droppedFrames, droppedPackets: meter.droppedPackets))
                }
            }
            await connection.close()
            if Task.isCancelled { return }
            if CACurrentMediaTime() - connectedAt > 30 { backoff = 1 }
            onState(.retrying("Lost the connection to the server."))
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 15)
        }
    }

    private static func describe(_ error: Error) -> String {
        if case SRTConnection.Error.failedToConnect(let reason) = error {
            return "The server refused the stream (\(reason)). Check the server's token and ingest settings."
        }
        return "Couldn't reach the server's video port. Is it running, and is UDP allowed through?"
    }
}

/// Turns SRT's running totals into what happened since the last reading.
private struct LinkMeter {
    struct Reading {
        var sentKbps = 0, rttMs = 0, backlogMs = 0
        var lossPercent = 0.0
        /// Packets given up on since the last reading.
        var droppedPackets = 0
    }

    private(set) var readAt: Double
    /// Packets given up on since the connection opened.
    private(set) var droppedPackets = 0
    private var bytes: UInt64 = 0
    private var packets: Int64 = 0
    private var lost: Int32 = 0

    init(at time: Double) { readAt = time }

    mutating func read(_ perf: SRTPerformanceData, at now: Double) -> Reading {
        let seconds = max(now - readAt, 0.001)
        let sent = perf.pktSentTotal - packets
        let reading = Reading(
            sentKbps: Int(Double(perf.byteSentTotal &- bytes) * 8 / 1000 / seconds),
            rttMs: Int(perf.msRTT.rounded()),
            backlogMs: Int(perf.msSndBuf),
            lossPercent: sent > 0 ? min(100, Double(perf.pktSndLossTotal - lost) / Double(sent) * 100) : 0,
            droppedPackets: max(0, Int(perf.pktSndDropTotal) - droppedPackets))
        readAt = now
        bytes = perf.byteSentTotal
        packets = perf.pktSentTotal
        lost = perf.pktSndLossTotal
        droppedPackets = Int(perf.pktSndDropTotal)
        return reading
    }
}
