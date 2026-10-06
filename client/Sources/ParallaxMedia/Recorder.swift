import AVFoundation
import Foundation
import os
import ParallaxCore
import VideoToolbox

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
/// The recorder runs the hardware video encoder itself and AVAssetWriter
/// only writes the file. If the encoder fails, a new one takes over and the
/// same file carries on, missing at most a moment of video.
///
/// Files are fragmented, so whatever was written plays even if the file is
/// never finished. If the file itself fails partway through (a full disk),
/// it is kept as-is and recording carries on in a new file ("… (2).mp4").
public final class Recorder: MediaSink, @unchecked Sendable {
    /// The first file.
    public let url: URL
    /// The recording's frame size (the canvas, or scaled down from it).
    public let encodedSize: CGSize
    private let recording: RecordingSettings
    private let output: OutputSettings
    private let audioFormat: CMAudioFormatDescription
    /// What the encoder produces; each file needs it up front.
    private let videoFormat: CMFormatDescription
    private let onProblem: @Sendable (Recorder, _ message: String, _ stopped: Bool) -> Void
    private let queue = DispatchQueue(label: "parallax.recorder", qos: .userInitiated)
    private var encoder: RecordingEncoder!

    /// A file that fails sooner than this after starting probably fails for
    /// a reason a new file won't fix (a full disk), so recording stops.
    static let minFileSecondsToRetry: Double = 10
    private static let maxFiles = 20
    /// More encoder failures than this in a minute means a new encoder isn't
    /// helping, so recording stops.
    static let maxEncoderRestartsPerMinute = 5

    // Only touched on `queue`.
    private var file: File?
    private var files: [File] = []
    private var problems: [String] = []
    /// The first frame of the first file, for "error at 32:10" messages.
    private var recordingStart: CMTime?
    /// False once `finish()` starts: no new frames go in.
    private var accepting = true
    private var finished = false
    /// Ask the encoder for a keyframe with the next frame.
    private var needsKeyFrame = true
    /// Drop encoded frames until a keyframe: a file has to start with one,
    /// and so does the video after frames were lost.
    private var waitingForKeyFrame = true
    /// Encoded frames waiting for the file to take them.
    private var pending: [CMSampleBuffer] = []
    private var encoderRestarts: [Double] = []
    private var encoderGaveUp = false
    private var droppedFrames = 0

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

        let config = RecordingEncoder.Config(recording: recording, output: output)
        videoFormat = try RecordingEncoder.formatDescription(for: config, sourceWidth: output.width, sourceHeight: output.height)
        let first = try File(url: url, recording: recording, videoFormat: videoFormat, audioFormat: desc)
        file = first
        files = [first]
        encoder = try RecordingEncoder(config: config) { [weak self] generation, status, sample in
            guard let self else { return }
            let sample = sample.map(Unchecked.init)
            queue.async { self.encoded(sample?.value, status: status, generation: generation) }
        }
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let pb = Unchecked(pixelBuffer)
        queue.async { [self] in
            guard accepting, !encoderGaveUp, let file else { return }
            guard file.writer.status == .writing else { return failed(file, at: pts) }
            // The encoder is a second behind: skip this frame rather than
            // queue up more.
            if encoder.inFlight >= output.fps {
                droppedFrames += 1
                return
            }
            let status = encoder.encode(pb.value, pts: pts, keyFrame: needsKeyFrame)
            if status == noErr {
                needsKeyFrame = false
            } else {
                encoderFailed(status, generation: encoder.generation, at: pts)
            }
        }
    }

    public func appendAudio(_ samples: UnsafeBufferPointer<Float>, frameCount: Int, pts: CMTime) {
        let data = Data(buffer: samples)
        queue.async { [self] in
            guard accepting, let file, let start = file.sessionStart, pts >= start else { return }
            guard file.writer.status == .writing else { return failed(file, at: pts) }
            if file.audioInput.isReadyForMoreMediaData, let sample = makeAudioSample(data, frames: frameCount, pts: pts),
               !file.audioInput.append(sample) {
                return failed(file, at: pts)
            }
            drain()
        }
    }

    /// Finishes the file. Throws only if nothing at all was saved.
    public func finish() async throws -> RecordingResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RecordingResult, Error>) in
            queue.async { [self] in
                accepting = false
                // Frames still in the encoder come out onto the queue, ahead
                // of the block below.
                encoder.flush()
                queue.async { [self] in finishFile(cont) }
            }
        }
    }

    private func finishFile(_ cont: CheckedContinuation<RecordingResult, Error>) {
        finished = true
        encoder.invalidate()
        if droppedFrames > 0 { log.info("Recording skipped \(self.droppedFrames) frames while the encoder caught up") }
        guard let file else { return complete(cont) }
        drain(waiting: true)
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

    // MARK: Encoded video

    private func encoded(_ sample: CMSampleBuffer?, status: OSStatus, generation: Int) {
        guard !finished, generation == encoder.generation else { return }
        guard status == noErr, let sample else {
            return encoderFailed(status, generation: generation, at: nil)
        }
        guard let file else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard file.writer.status == .writing else { return failed(file, at: pts) }
        if waitingForKeyFrame {
            guard sample.isKeyFrame else { return }
            waitingForKeyFrame = false
        }
        if file.sessionStart == nil {
            file.writer.startSession(atSourceTime: pts)
            file.sessionStart = pts
            if recordingStart == nil { recordingStart = pts }
        }
        pending.append(sample)
        drain()
    }

    /// Hands waiting frames to the file as it's ready for them.
    private func drain(waiting: Bool = false) {
        guard let file else { return pending.removeAll() }
        var waited = 0
        while let sample = pending.first {
            guard file.writer.status == .writing else { return }
            guard file.videoInput.isReadyForMoreMediaData else {
                // Only when finishing: give the file up to a couple of seconds.
                guard waiting, waited < 1000 else { break }
                waited += 1
                usleep(2000)
                continue
            }
            pending.removeFirst()
            if !file.videoInput.append(sample) {
                return failed(file, at: CMSampleBufferGetPresentationTimeStamp(sample))
            }
        }
        // The file has fallen seconds behind. Drop what's waiting and pick up
        // again at the next keyframe, rather than pile up memory.
        if pending.count > output.fps * 3 {
            log.warning("Recording dropped \(self.pending.count) frames the file couldn't take in time")
            droppedFrames += pending.count
            pending.removeAll()
            waitingForKeyFrame = true
            needsKeyFrame = true
        }
    }

    // MARK: Failures

    /// The encoder stopped working. Start a new one; the file carries on
    /// from its first keyframe. Frames still waiting for the file are fine.
    private func encoderFailed(_ status: OSStatus, generation: Int, at pts: CMTime?) {
        guard !encoderGaveUp, generation == encoder.generation else { return }
        let reason = RecordingEncoder.describe(status)
        log.error("Recording video encoder failed (\(reason, privacy: .public)); starting a new one")
        let now = hostNow()
        encoderRestarts = encoderRestarts.filter { now - $0 < 60 } + [now]
        var failure: String?
        if encoderRestarts.count > Self.maxEncoderRestartsPerMinute {
            failure = "the video encoder keeps failing (\(reason))"
        } else {
            do {
                try encoder.restart()
            } catch {
                failure = error.localizedDescription
            }
        }
        needsKeyFrame = true
        waitingForKeyFrame = true
        guard let failure else { return }
        encoderGaveUp = true
        var message = "Recording error"
        if let pts, let start = recordingStart { message += " at \(Self.clock((pts - start).seconds))" }
        message += ": \(failure). Recording stopped; everything before it is saved."
        log.error("\(message, privacy: .public)")
        problems.append(message)
        onProblem(self, message, true)
    }

    /// The file stopped accepting samples. Keep it as-is (fragmented, so it
    /// plays up to its last fragment; `cancelWriting` would delete it) and
    /// carry on in a new file if that's likely to help.
    private func failed(_ failed: File, at pts: CMTime) {
        guard file === failed else { return }
        file = nil
        pending.removeAll()
        needsKeyFrame = true
        waitingForKeyFrame = true
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
                                   recording: recording, videoFormat: videoFormat, audioFormat: audioFormat)
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
        var reason = file.writer.error?.localizedDescription ?? "unknown error"
        if let underlying = (file.writer.error as NSError?)?.userInfo[NSUnderlyingErrorKey] as? NSError {
            reason += " (\(underlying.domain) \(underlying.code))"
        }
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

    /// Treats the encoder as failed, as if it had reported an error.
    func simulateEncoderFailureForTesting() {
        queue.async { [self] in encoderFailed(kVTVideoEncoderMalfunctionErr, generation: encoder.generation, at: nil) }
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

private extension CMSampleBuffer {
    var isKeyFrame: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }
}

/// One output file. Only touched on the recorder's queue.
private final class File {
    let url: URL
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput
    var sessionStart: CMTime?

    init(url: URL, recording: RecordingSettings, videoFormat: CMFormatDescription, audioFormat: CMAudioFormatDescription) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: recording.container == .mov ? .mov : .mp4)
        // Fragmented output keeps everything up to the last fragment if we
        // crash or the writer fails.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        // Already encoded by RecordingEncoder; the writer only stores it.
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = true

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
