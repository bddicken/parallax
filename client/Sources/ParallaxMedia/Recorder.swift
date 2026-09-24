import AVFoundation
import Foundation
import ParallaxCore

/// Writes the program output to a local file. Recording is independent of
/// streaming so a flaky uplink never affects the local copy.
public final class Recorder: MediaSink, @unchecked Sendable {
    public let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioFormat: CMAudioFormatDescription
    private let queue = DispatchQueue(label: "parallax.recorder", qos: .userInitiated)

    // Only touched on `queue`.
    private var sessionStart: CMTime?
    private var finished = false

    init(directory: URL, recording: RecordingSettings, output: OutputSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Date().formatted(.verbatim(
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
            timeZone: .current, calendar: .current))
        url = directory.appending(path: "Parallax \(stamp).\(recording.container.rawValue)")

        writer = try AVAssetWriter(outputURL: url, fileType: recording.container == .mov ? .mov : .mp4)
        // Fragmented output keeps everything up to the last fragment if we crash.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        let video: [String: Any] = [
            AVVideoCodecKey: recording.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: output.width,
            AVVideoHeightKey: output.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: recording.videoBitrateKbps * 1000,
                AVVideoExpectedSourceFrameRateKey: output.fps,
                AVVideoMaxKeyFrameIntervalKey: output.fps * 2,
                AVVideoAllowFrameReorderingKey: true,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: video)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: AudioFormat.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var desc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
        guard let desc else { throw MediaError("Could not create audio format.") }
        audioFormat = desc
        let audio: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioFormat.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: recording.audioBitrateKbps * 1000,
        ]
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audio, sourceFormatHint: desc)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw MediaError("Unsupported recording settings.") }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else {
            throw MediaError("Could not start recording: \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let pb = Unchecked(pixelBuffer)
        queue.async { [self] in
            guard !finished, writer.status == .writing else { return }
            if sessionStart == nil {
                writer.startSession(atSourceTime: pts)
                sessionStart = pts
            }
            if videoInput.isReadyForMoreMediaData {
                adaptor.append(pb.value, withPresentationTime: pts)
            }
        }
    }

    public func appendAudio(_ samples: UnsafeBufferPointer<Float>, frameCount: Int, pts: CMTime) {
        let data = Data(buffer: samples)
        queue.async { [self] in
            guard !finished, writer.status == .writing, let start = sessionStart, pts >= start,
                  audioInput.isReadyForMoreMediaData,
                  let sample = makeAudioSample(data, frames: frameCount, pts: pts) else { return }
            audioInput.append(sample)
        }
    }

    /// Finishes the file. Returns its URL, or throws if writing failed.
    public func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            queue.async { [self] in
                finished = true
                guard writer.status == .writing, sessionStart != nil else {
                    writer.cancelWriting()
                    return cont.resume(throwing: MediaError(writer.error?.localizedDescription ?? "Nothing was recorded."))
                }
                videoInput.markAsFinished()
                audioInput.markAsFinished()
                let writer = Unchecked(writer)
                writer.value.finishWriting { [url] in
                    if writer.value.status == .completed {
                        cont.resume(returning: url)
                    } else {
                        cont.resume(throwing: MediaError(writer.value.error?.localizedDescription ?? "Recording failed."))
                    }
                }
            }
        }
    }

    private func makeAudioSample(_ data: Data, frames: Int, pts: CMTime) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: frames,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }
}
