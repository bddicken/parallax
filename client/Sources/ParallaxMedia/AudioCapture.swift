import AVFoundation
import Foundation
import ScreenCaptureKit

typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

protocol AudioInputNode: AnyObject, Sendable {
    func start()
    func stop()
}

/// Converts whatever a device delivers into deinterleaved Float32 at 48 kHz,
/// keeping its channel count so the mixer can pick channels.
final class PCMNormalizer {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        input.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList) == noErr else { return nil }

        if format.commonFormat == .pcmFormatFloat32, !format.isInterleaved, format.sampleRate == 48_000 {
            return input
        }
        if inputFormat != format {
            inputFormat = format
            converter = Self.targetFormat(for: format).flatMap { AVAudioConverter(from: format, to: $0) }
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(frames) * 48_000 / format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        // The input block runs synchronously inside convert(); hand over the one buffer.
        let pending = PendingInput(input)
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            guard let buffer = pending.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    private static func targetFormat(for format: AVAudioFormat) -> AVAudioFormat? {
        if format.channelCount <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: format.channelCount, interleaved: false)
        }
        let layout = format.channelLayout
            ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | format.channelCount)!
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
    }
}

private final class PendingInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

// MARK: - Microphones / interfaces

final class DeviceAudioNode: NSObject, AudioInputNode, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let uniqueID: String
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "parallax.audio-device", qos: .userInteractive)
    private let normalizer = PCMNormalizer()
    private let onBuffer: AudioBufferHandler
    private let onError: SourceErrorHandler
    private var configured = false

    init(uniqueID: String, onBuffer: @escaping AudioBufferHandler, onError: @escaping SourceErrorHandler) {
        self.uniqueID = uniqueID
        self.onBuffer = onBuffer
        self.onError = onError
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { [self] granted in
            guard granted else { return onError(.permissionDenied(.microphone)) }
            queue.async { [self] in
                if !configured { configure() }
                if configured, !session.isRunning { session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice(uniqueID: uniqueID) else { return onError(.failed("Audio device is disconnected.")) }
        do {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return onError(.failed("Audio device is unavailable.")) }
            session.addInput(input)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { return onError(.failed("Could not read from audio device.")) }
            session.addOutput(output)
            configured = true
        } catch {
            onError(.failed("Audio device failed: \(error.localizedDescription)"))
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let pcm = normalizer.convert(sampleBuffer) { onBuffer(pcm) }
    }
}

// MARK: - System audio

/// Captures everything the Mac plays (excluding Parallax) via ScreenCaptureKit.
final class SystemAudioNode: NSObject, AudioInputNode, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "parallax.audio-system", qos: .userInteractive)
    private let normalizer = PCMNormalizer()
    private let onBuffer: AudioBufferHandler
    private let onError: SourceErrorHandler
    private let lock = NSLock()
    private var stream: SCStream?
    private var wantsRunning = false

    init(onBuffer: @escaping AudioBufferHandler, onError: @escaping SourceErrorHandler) {
        self.onBuffer = onBuffer
        self.onError = onError
    }

    func start() {
        lock.withLock { wantsRunning = true }
        Task { await startStream() }
    }

    func stop() {
        let s = lock.withLock { () -> SCStream? in
            wantsRunning = false
            defer { stream = nil }
            return stream
        }
        s?.stopCapture { _ in }
    }

    private func startStream() async {
        guard CGPreflightScreenCaptureAccess() else { return onError(.permissionDenied(.screenRecording)) }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return onError(.failed("No display available for system audio.")) }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            // Video can't be disabled entirely; keep it tiny and slow.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            let keep = lock.withLock { () -> Bool in
                guard wantsRunning else { return false }
                self.stream = stream
                return true
            }
            guard keep else { return }
            try await stream.startCapture()
        } catch {
            onError(CGPreflightScreenCaptureAccess()
                ? .failed("System audio failed: \(error.localizedDescription)")
                : .permissionDenied(.screenRecording))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let pcm = normalizer.convert(sampleBuffer) else { return }
        onBuffer(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(.failed("System audio stopped: \(error.localizedDescription)"))
    }
}
