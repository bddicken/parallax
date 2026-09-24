import AVFoundation
import Foundation
import HaishinKit
import ParallaxCore
import SRTHaishinKit
import VideoToolbox

public enum UplinkState: Sendable, Equatable {
    case connecting
    case sending
    /// Couldn't connect or lost the connection; retrying.
    case retrying(String)
}

/// Sends the program output to parallax-server: HaishinKit encodes it
/// (VideoToolbox H.264 + AAC) and sends MPEG-TS over SRT. Reconnects on its
/// own until stopped. Frames that arrive while disconnected are dropped.
public final class Uplink: MediaSink, @unchecked Sendable {
    public let encodedSize: CGSize

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

    init(url: URL, stream: StreamSettings, output: OutputSettings, onState: @escaping @Sendable (UplinkState) -> Void) {
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
        task = Task.detached(priority: .userInitiated) {
            await Self.run(url: url, video: video, audio: audio, items: items, onState: onState)
        }
    }

    public func stop() {
        items.finish()
        task.cancel()
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let format = format(for: pixelBuffer) else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample { items.yield(Unchecked(.video(sample))) }
    }

    public func appendAudio(_ samples: UnsafeBufferPointer<Float>, frameCount: Int, pts: CMTime) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let dest = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        dest.update(from: samples.baseAddress!, count: frameCount * AudioFormat.channels)
        let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: pts.seconds))
        items.yield(Unchecked(.audio(buffer, when)))
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
                            items: AsyncStream<Unchecked<Item>>, onState: @Sendable (UplinkState) -> Void) async {
        var iterator = items.makeAsyncIterator()
        var backoff = 1.0
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
