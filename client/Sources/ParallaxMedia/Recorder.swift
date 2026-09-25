import AVFoundation
import Foundation
import ParallaxCore

/// Writes one recording output (the program or a single scene) to a local
/// file. Recording is independent of streaming so a flaky uplink never
/// affects the local copy.
public final class Recorder: MediaSink, @unchecked Sendable {
    /// What `finish` left on disk: the file, if anything was recorded, and
    /// what went wrong, if anything.
    struct Result: Sendable {
        var url: URL?
        var problem: String?
    }

    public let url: URL
    /// The recording's frame size (the canvas, or scaled down from it).
    public let encodedSize: CGSize
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let timecodeInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioFormat: CMAudioFormatDescription
    private let timecodeFormat: CMTimeCodeFormatDescription?
    private let timecode: TimecodeClock
    private let fps: Int
    private let onFailure: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "parallax.recorder", qos: .userInitiated)

    // Only touched on `queue`.
    private var sessionStart: CMTime?
    private var lastVideoPTS: CMTime?
    /// Audio that arrived before the first frame. Every file in a take gets
    /// the same frames and audio, but not always in the same order, so hold
    /// early audio rather than dropping it; then all files start on the same
    /// sample.
    private var pendingAudio: [CMSampleBuffer] = []
    private var finished = false
    private var failure: String?

    /// `timecode` should be shared by every recorder in a take, so the files
    /// carry matching timecode. `onFailure` is called once, on a background
    /// queue, if writing fails mid-recording.
    init(url: URL, recording: RecordingSettings, output: RecordingOutput, canvas: OutputSettings,
         timecode: TimecodeClock, onFailure: @escaping @Sendable (String) -> Void) throws {
        self.url = url
        self.timecode = timecode
        fps = canvas.fps
        self.onFailure = onFailure

        writer = try AVAssetWriter(outputURL: url, fileType: recording.container == .mov ? .mov : .mp4)
        // Fragmented output keeps everything up to the last fragment if we
        // crash or writing fails, so at most this much is lost.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        let size = output.resolution.size(for: canvas)
        encodedSize = CGSize(width: size.width, height: size.height)
        let video: [String: Any] = [
            AVVideoCodecKey: recording.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            // The canvas may be larger than the recording; scale to fit.
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: output.videoBitrateKbps * 1000,
                AVVideoExpectedSourceFrameRateKey: canvas.fps,
                AVVideoMaxKeyFrameIntervalKey: canvas.fps * 2,
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

        // A time-of-day timecode track (QuickTime only), so editors can line
        // up the files from one take automatically.
        var tcFormat: CMTimeCodeFormatDescription?
        if recording.container == .mov {
            CMTimeCodeFormatDescriptionCreate(
                allocator: nil, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
                frameDuration: CMTime(value: 1, timescale: CMTimeScale(canvas.fps)), frameQuanta: UInt32(canvas.fps),
                flags: kCMTimeCodeFlag_24HourMax, extensions: nil, formatDescriptionOut: &tcFormat)
        }
        if let tcFormat {
            let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: tcFormat)
            input.expectsMediaDataInRealTime = true
            let association = AVAssetTrack.AssociationType.timecode.rawValue
            if writer.canAdd(input) {
                writer.add(input)
                if videoInput.canAddTrackAssociation(withTrackOf: input, type: association) {
                    videoInput.addTrackAssociation(withTrackOf: input, type: association)
                }
                timecodeInput = input
            } else {
                timecodeInput = nil
            }
        } else {
            timecodeInput = nil
        }
        timecodeFormat = tcFormat

        guard writer.startWriting() else {
            throw MediaError("Could not start recording: \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let pb = Unchecked(pixelBuffer)
        queue.async { [self] in
            guard !finished, writer.status == .writing else { return checkFailed() }
            if sessionStart == nil { startSession(at: pts) }
            if videoInput.isReadyForMoreMediaData {
                adaptor.append(pb.value, withPresentationTime: pts)
                lastVideoPTS = pts
            }
            checkFailed()
        }
    }

    public func appendAudio(_ samples: UnsafeBufferPointer<Float>, frameCount: Int, pts: CMTime) {
        let data = Data(buffer: samples)
        queue.async { [self] in
            guard !finished, writer.status == .writing,
                  let sample = makeAudioSample(data, frames: frameCount, pts: pts) else { return }
            guard let start = sessionStart else {
                pendingAudio.append(sample)
                // A few frames' worth is plenty; older audio would be cut anyway.
                if pendingAudio.count > 50 { pendingAudio.removeFirst() }
                return
            }
            if pts >= start, audioInput.isReadyForMoreMediaData { audioInput.append(sample) }
            checkFailed()
        }
    }

    private func startSession(at pts: CMTime) {
        writer.startSession(atSourceTime: pts)
        sessionStart = pts
        appendTimecode(at: pts)
        for sample in pendingAudio where CMSampleBufferGetPresentationTimeStamp(sample) >= pts {
            if audioInput.isReadyForMoreMediaData { audioInput.append(sample) }
        }
        pendingAudio = []
    }

    /// The whole timecode track is one sample: the timecode of the first
    /// frame. Players and editors count on from there. Finished right away so
    /// the writer never holds other tracks back waiting for more timecode.
    private func appendTimecode(at pts: CMTime) {
        guard let timecodeInput, let timecodeFormat else { return }
        defer { timecodeInput.markAsFinished() }
        var frame = timecode.frameNumber(at: pts, fps: fps).bigEndian
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: 4, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block,
            CMBlockBufferReplaceDataBytes(with: &frame, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4) == noErr
        else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: timecodeFormat, sampleCount: 1,
                                  sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        if let sample, timecodeInput.isReadyForMoreMediaData { timecodeInput.append(sample) }
    }

    /// Reports a mid-recording failure once, as soon as it happens, rather
    /// than only when the user presses Stop.
    private func checkFailed() {
        guard writer.status == .failed, failure == nil else { return }
        let message = describe(writer.error)
        failure = message
        onFailure(message)
    }

    /// Deletes the file; for a take that couldn't start.
    func discard() {
        queue.sync {
            finished = true
            writer.cancelWriting()
        }
    }

    /// Finishes the file. Never deletes one with anything playable in it: if
    /// writing failed partway, the fragments written before that still play.
    func finish() async -> Result {
        let (recorded, failure) = await finishWriting()
        guard let recorded else { return Result(problem: failure ?? "Nothing was recorded.") }
        guard let failure else { return Result(url: url) }
        let name = url.lastPathComponent, time = recorded.formatted(.time(pattern: .hourMinuteSecond))
        if (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0 > 0 {
            return Result(url: url, problem: "\(name) stopped after \(time): \(failure). It keeps everything up to a moment before that.")
        }
        try? FileManager.default.removeItem(at: url)
        return Result(problem: "\(name) failed after \(time), before anything could be saved: \(failure).")
    }

    /// How long was recorded (nil if nothing), and what went wrong, if anything.
    private func finishWriting() async -> (Duration?, String?) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Duration?, String?), Never>) in
            queue.async { [self] in
                finished = true
                checkFailed()
                guard let start = sessionStart else {
                    writer.cancelWriting()
                    return cont.resume(returning: (nil, failure))
                }
                let recorded = Duration.seconds(((lastVideoPTS ?? start) - start).seconds)
                guard writer.status == .writing else {
                    return cont.resume(returning: (recorded, failure ?? describe(writer.error)))
                }
                videoInput.markAsFinished()
                audioInput.markAsFinished()
                let writer = Unchecked(writer)
                writer.value.finishWriting {
                    let ok = writer.value.status == .completed
                    cont.resume(returning: (recorded, ok ? nil : "could not finish the file: \(self.describe(writer.value.error))"))
                }
            }
        }
    }

    /// AVFoundation's descriptions are often just "The operation could not be
    /// completed", so include the underlying error, which says what happened.
    private func describe(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "unknown error" }
        var text = error.localizedDescription
        if let reason = error.localizedFailureReason { text += " (\(reason))" }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " [\(underlying.domain) \(underlying.code)]"
        } else {
            text += " [\(error.domain) \(error.code)]"
        }
        return text
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

/// Time-of-day timecode for host-clock times. One is shared by every file in
/// a take, so files that start on the same frame carry the same timecode.
struct TimecodeClock: Sendable {
    /// Seconds since local midnight at host time zero.
    private let offset: Double

    init(now: Date = Date()) {
        offset = now.timeIntervalSince(Calendar.current.startOfDay(for: now)) - hostNow()
    }

    func frameNumber(at pts: CMTime, fps: Int) -> Int32 {
        let seconds = (pts.seconds + offset).truncatingRemainder(dividingBy: 86_400)
        return Int32((max(0, seconds) * Double(fps)).rounded(.down))
    }
}
