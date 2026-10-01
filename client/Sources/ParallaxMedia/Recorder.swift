import AVFoundation
import Foundation
import os
import ParallaxCore

private let log = Logger(subsystem: "com.bddicken.parallax", category: "recording")

/// What a recording left on disk.
public struct RecordingResult: Sendable {
    /// Every file written, in order. There's more than one if a file failed
    /// partway through and recording carried on in a new one.
    public let files: [URL]
    /// What went wrong, if anything did. The files are still worth keeping.
    public let problem: String?
}

/// Writes the program output to a local file. Recording is independent of
/// streaming so a flaky uplink never affects the local copy.
///
/// Files are fragmented, so whatever was written plays even if the file is
/// never finished. If a file fails partway through, it is kept as-is and
/// recording carries on in a new file ("… (2).mp4").
public final class Recorder: MediaSink, @unchecked Sendable {
    /// The first file.
    public let url: URL
    /// The recording's frame size (the canvas, or scaled down from it).
    public let encodedSize: CGSize
    private let recording: RecordingSettings
    private let output: OutputSettings
    private let audioFormat: CMAudioFormatDescription
    private let onProblem: @Sendable (Recorder, _ message: String, _ stopped: Bool) -> Void
    private let queue = DispatchQueue(label: "parallax.recorder", qos: .userInitiated)

    /// A file that fails sooner than this after starting probably fails for
    /// a reason a new file won't fix (a full disk), so recording stops.
    static let minFileSecondsToRetry: Double = 10
    private static let maxFiles = 20

    // Only touched on `queue`.
    private var file: File?
    private var files: [File] = []
    private var problems: [String] = []
    /// The first frame of the first file, for "error at 32:10" messages.
    private var recordingStart: CMTime?
    private var finished = false

    /// `onProblem` is called on the recorder's queue when a file fails
    /// partway through; `stopped` is true if recording couldn't carry on.
    init(directory: URL, recording: RecordingSettings, output: OutputSettings,
         onProblem: @escaping @Sendable (Recorder, _ message: String, _ stopped: Bool) -> Void = { _, _, _ in }) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Date().formatted(.verbatim(
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
            timeZone: .current, calendar: .current))
        url = directory.appending(path: "Parallax \(stamp).\(recording.container.rawValue)")
        let size = recording.resolution.size(for: output)
        encodedSize = CGSize(width: size.width, height: size.height)
        self.recording = recording
        self.output = output
        self.onProblem = onProblem

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

        let first = try File(url: url, recording: recording, output: output, audioFormat: desc)
        file = first
        files = [first]
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let pb = Unchecked(pixelBuffer)
        queue.async { [self] in
            guard !finished, let file else { return }
            guard file.writer.status == .writing else { return failed(file, at: pts) }
            if file.sessionStart == nil {
                file.writer.startSession(atSourceTime: pts)
                file.sessionStart = pts
                if recordingStart == nil { recordingStart = pts }
            }
            if file.videoInput.isReadyForMoreMediaData, !file.adaptor.append(pb.value, withPresentationTime: pts) {
                failed(file, at: pts)
            }
        }
    }

    public func appendAudio(_ samples: UnsafeBufferPointer<Float>, frameCount: Int, pts: CMTime) {
        let data = Data(buffer: samples)
        queue.async { [self] in
            guard !finished, let file, let start = file.sessionStart, pts >= start else { return }
            guard file.writer.status == .writing else { return failed(file, at: pts) }
            guard file.audioInput.isReadyForMoreMediaData,
                  let sample = makeAudioSample(data, frames: frameCount, pts: pts) else { return }
            if !file.audioInput.append(sample) { failed(file, at: pts) }
        }
    }

    /// Finishes the file. Throws only if nothing at all was saved.
    public func finish() async throws -> RecordingResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RecordingResult, Error>) in
            queue.async { [self] in
                finished = true
                guard let file else { return complete(cont) }
                self.file = nil
                guard file.sessionStart != nil else {
                    // Nothing in it; this deletes the file.
                    file.writer.cancelWriting()
                    return complete(cont)
                }
                guard file.writer.status == .writing else {
                    noteFailure(of: file, at: nil)
                    return complete(cont)
                }
                file.videoInput.markAsFinished()
                file.audioInput.markAsFinished()
                let writer = Unchecked(file.writer)
                writer.value.finishWriting { [self] in
                    queue.async { [self] in
                        if writer.value.status != .completed { noteFailure(of: file, at: nil) }
                        complete(cont)
                    }
                }
            }
        }
    }

    // MARK: Failures

    /// The writer stopped accepting samples. Keep its file as-is (fragmented,
    /// so it plays up to its last fragment; `cancelWriting` would delete it)
    /// and carry on in a new file if that's likely to help.
    private func failed(_ failed: File, at pts: CMTime) {
        guard file === failed else { return }
        file = nil
        if failed.writer.status == .writing {
            // Not failed for good, just refusing samples: close it properly.
            failed.videoInput.markAsFinished()
            failed.audioInput.markAsFinished()
            failed.writer.finishWriting {}
        }
        var message = noteFailure(of: failed, at: pts)
        let fileSeconds = failed.sessionStart.map { (pts - $0).seconds } ?? 0
        var stopped = true
        if fileSeconds >= Self.minFileSecondsToRetry, files.count < Self.maxFiles {
            let next = url.deletingPathExtension().lastPathComponent + " (\(files.count + 1))." + url.pathExtension
            do {
                let new = try File(url: url.deletingLastPathComponent().appending(path: next),
                                   recording: recording, output: output, audioFormat: audioFormat)
                file = new
                files.append(new)
                message += " Recording continues in \"\(next)\"."
                stopped = false
            } catch {
                log.error("Couldn't start \(next, privacy: .public): \(String(describing: error), privacy: .public)")
                message += " Couldn't start a new file (\(error.localizedDescription)), so recording stopped."
            }
        } else {
            message += " Recording stopped."
        }
        onProblem(self, message, stopped)
    }

    /// Logs and remembers why `file` failed, and returns a message for the user.
    @discardableResult
    private func noteFailure(of file: File, at pts: CMTime?) -> String {
        let name = file.url.lastPathComponent
        log.error("Recording to \(name, privacy: .public) failed: \(String(describing: file.writer.error), privacy: .public)")
        let reason = file.writer.error?.localizedDescription ?? "unknown error"
        var message = "Recording error"
        if let pts, let start = recordingStart { message += " at \(Self.clock((pts - start).seconds))" }
        message += ": \(reason)."
        if file.sessionStart != nil { message += " \"\(name)\" is saved up to about then." }
        problems.append(message)
        return message
    }

    private func complete(_ cont: CheckedContinuation<RecordingResult, Error>) {
        let kept = files.filter { $0.sessionStart != nil }.map(\.url)
        if kept.isEmpty {
            cont.resume(throwing: MediaError(problems.first ?? "Nothing was recorded."))
        } else {
            cont.resume(returning: RecordingResult(files: kept, problem: problems.isEmpty ? nil : problems.joined(separator: "\n")))
        }
    }

    /// Treats the current file as failed, as if the writer had rejected a
    /// sample at `pts`.
    func simulateFailureForTesting(at pts: CMTime) {
        queue.async { [self] in if let file { failed(file, at: pts) } }
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Samples

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

/// One output file. Only touched on the recorder's queue.
private final class File {
    let url: URL
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    var sessionStart: CMTime?

    init(url: URL, recording: RecordingSettings, output: OutputSettings, audioFormat: CMAudioFormatDescription) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: recording.container == .mov ? .mov : .mp4)
        // Fragmented output keeps everything up to the last fragment if we
        // crash or the writer fails.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        let size = recording.resolution.size(for: output)
        let video: [String: Any] = [
            AVVideoCodecKey: recording.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            // The canvas may be larger than the recording; scale to fit.
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
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

        let audio: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioFormat.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: recording.audioBitrateKbps * 1000,
        ]
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audio, sourceFormatHint: audioFormat)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw MediaError("Unsupported recording settings.") }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else {
            throw MediaError("Could not start recording: \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }
}
