import AVFoundation
import CoreImage
import Foundation
import ParallaxCore
import ScreenCaptureKit

/// A live or static image the compositor can draw.
protocol VideoSourceNode: AnyObject, Sendable {
    func start()
    func stop()
    func setDelay(ms: Int)
    func image(at time: Double) -> CIImage?
}

extension VideoSourceNode {
    func setDelay(ms: Int) {}
}

/// Thread-safe map of source id → node, shared by the engine and compositor.
final class SourceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var nodes: [UUID: VideoSourceNode] = [:]

    subscript(id: UUID) -> VideoSourceNode? {
        get { lock.withLock { nodes[id] } }
        set { lock.withLock { nodes[id] = newValue } }
    }

    var ids: [UUID] { lock.withLock { Array(nodes.keys) } }
}

typealias SourceErrorHandler = @Sendable (SourceIssue) -> Void

// MARK: - Camera

final class CameraNode: NSObject, VideoSourceNode, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let uniqueID: String
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "parallax.camera", qos: .userInteractive)
    private let frames = VideoFrameBuffer()
    private let onError: SourceErrorHandler
    private var configured = false

    init(uniqueID: String, onError: @escaping SourceErrorHandler) {
        self.uniqueID = uniqueID
        self.onError = onError
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [self] granted in
            guard granted else { return onError(.permissionDenied(.camera)) }
            queue.async { [self] in
                if !configured { configure() }
                if configured, !session.isRunning { session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            frames.clear()
        }
    }

    func setDelay(ms: Int) { frames.setDelay(seconds: Double(ms) / 1000) }

    func image(at time: Double) -> CIImage? {
        frames.frame(at: time).map { CIImage(cvPixelBuffer: $0) }
    }

    private func configure() {
        guard let device = AVCaptureDevice(uniqueID: uniqueID) else { return onError(.failed("Camera is disconnected.")) }
        do {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return onError(.failed("Camera is in use by another capture.")) }
            session.addInput(input)
            session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { return onError(.failed("Could not read from camera.")) }
            session.addOutput(output)
            configured = true
        } catch {
            onError(.failed("Camera failed: \(error.localizedDescription)"))
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let pb = sampleBuffer.imageBuffer { frames.push(pb) }
    }
}

// MARK: - Screen / window

final class ScreenNode: NSObject, VideoSourceNode, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Target: Sendable { case display(CGDirectDisplayID), window(CGWindowID) }

    private let target: Target
    private let fps: Int
    private let queue = DispatchQueue(label: "parallax.screen", qos: .userInteractive)
    private let frames = VideoFrameBuffer()
    private let onError: SourceErrorHandler
    private let lock = NSLock()
    private var stream: SCStream?
    private var wantsRunning = false

    /// Captures are scaled down to this width; the canvas is at most 1440p.
    private static let maxWidth = 2560

    init(target: Target, fps: Int, onError: @escaping SourceErrorHandler) {
        self.target = target
        self.fps = fps
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
        frames.clear()
    }

    func setDelay(ms: Int) { frames.setDelay(seconds: Double(ms) / 1000) }

    func image(at time: Double) -> CIImage? {
        frames.frame(at: time).map { CIImage(cvPixelBuffer: $0) }
    }

    private func startStream() async {
        // Check first: calling ScreenCaptureKit without access makes macOS prompt.
        guard CGPreflightScreenCaptureAccess() else { return onError(.permissionDenied(.screenRecording)) }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let filter: SCContentFilter
            let pixelSize: CGSize
            switch target {
            case .display(let id):
                guard let display = content.displays.first(where: { $0.displayID == id }) else {
                    return onError(.failed("Display is disconnected."))
                }
                let mode = CGDisplayCopyDisplayMode(id)
                pixelSize = CGSize(width: mode?.pixelWidth ?? display.width, height: mode?.pixelHeight ?? display.height)
                filter = SCContentFilter(display: display, excludingWindows: [])
            case .window(let id):
                guard let window = content.windows.first(where: { $0.windowID == id }) else {
                    return onError(.failed("Window was closed."))
                }
                filter = SCContentFilter(desktopIndependentWindow: window)
                let scale = Double(filter.pointPixelScale)
                pixelSize = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
            }
            let config = SCStreamConfiguration()
            let scale = min(1, Double(Self.maxWidth) / pixelSize.width)
            config.width = Int(pixelSize.width * scale)
            config.height = Int(pixelSize.height * scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.queueDepth = 5

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            let keep = lock.withLock { () -> Bool in
                guard wantsRunning else { return false }
                self.stream = stream
                return true
            }
            guard keep else { return }
            try await stream.startCapture()
        } catch {
            onError(CGPreflightScreenCaptureAccess()
                ? .failed("Screen capture failed: \(error.localizedDescription)")
                : .permissionDenied(.screenRecording))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = sampleBuffer.imageBuffer else { return }
        // Idle frames repeat the previous image; we keep the last one anyway.
        if let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
           let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) != .complete {
            return
        }
        frames.push(pb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(.failed("Screen capture stopped: \(error.localizedDescription)"))
    }
}

// MARK: - Static

/// Image files, solid colors, and chat overlays: a CIImage swapped in whole.
final class StaticImageNode: VideoSourceNode, @unchecked Sendable {
    private let lock = NSLock()
    private var current: CIImage?

    init(image: CIImage? = nil) {
        current = image
    }

    func start() {}
    func stop() {}
    func image(at time: Double) -> CIImage? { lock.withLock { current } }
    func setImage(_ image: CIImage?) { lock.withLock { current = image } }
}
