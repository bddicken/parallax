import AppKit
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
    private let queue = DispatchQueue(label: "parallax.camera", qos: .userInteractive)
    private let frames = VideoFrameBuffer()
    private let onError: SourceErrorHandler
    private var link: ReconnectingCaptureSession!

    init(uniqueID: String, name: String?, modelID: String?, onError: @escaping SourceErrorHandler,
         onResolved: @escaping @Sendable (VideoSourceKind) -> Void) {
        self.onError = onError
        super.init()
        let frames = frames
        link = ReconnectingCaptureSession(
            mediaType: .video, target: .init(uniqueID: uniqueID, name: name, modelID: modelID), queue: queue,
            configure: { [unowned self] session, device in
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw MediaError("Camera is in use by another capture.") }
                session.addInput(input)
                session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                guard session.canAddOutput(output) else { throw MediaError("Could not read from camera.") }
                session.addOutput(output)
            },
            onIssue: onError,
            onResolved: { onResolved(.camera(uniqueID: $0.uniqueID, name: $0.name, modelID: $0.modelID)) },
            onDisconnected: { frames.clear() })
    }

    func start() {
        let askedJustNow = AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
        AVCaptureDevice.requestAccess(for: .video) { [self] granted in
            guard granted else { return onError(.permissionDenied(.camera, askedJustNow: askedJustNow)) }
            link.start()
        }
    }

    func stop() {
        link.stop()
        frames.clear()
    }

    func setDelay(ms: Int) { frames.setDelay(seconds: Double(ms) / 1000) }

    func image(at time: Double) -> CIImage? {
        frames.frame(at: time).map { CIImage(cvPixelBuffer: $0) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let pb = sampleBuffer.imageBuffer { frames.push(pb) }
    }
}

// MARK: - Screen / window

final class ScreenNode: NSObject, VideoSourceNode, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let fps: Int
    private let queue = DispatchQueue(label: "parallax.screen", qos: .userInteractive)
    private let frames = VideoFrameBuffer()
    private let onError: SourceErrorHandler
    private let onResolved: @Sendable (VideoSourceKind) -> Void
    private let lock = NSLock()
    private var kind: VideoSourceKind
    private var stream: SCStream?
    private var wantsRunning = false
    private var starting = false
    private var poll: DispatchSourceTimer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Captures are scaled down to this width; the canvas is at most 1440p.
    private static let maxWidth = 2560

    /// `kind` must be `.display` or `.window`.
    init(kind: VideoSourceKind, fps: Int, onError: @escaping SourceErrorHandler,
         onResolved: @escaping @Sendable (VideoSourceKind) -> Void) {
        self.kind = kind
        self.fps = fps
        self.onError = onError
        self.onResolved = onResolved
        super.init()
        // Displays come back (or get renumbered) on hot-plug, arrangement
        // changes, and wake; retry whenever that happens.
        let workspace = NSWorkspace.shared.notificationCenter
        for (center, name) in [(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
                               (workspace, NSWorkspace.didWakeNotification),
                               (workspace, NSWorkspace.screensDidWakeNotification)] {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.retry() }
            observers.append((center, token))
        }
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
        poll?.cancel()
    }

    func start() {
        lock.withLock { wantsRunning = true }
        retry()
    }

    func stop() {
        let s = lock.withLock { () -> SCStream? in
            wantsRunning = false
            poll?.cancel()
            poll = nil
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

    /// Starts capture if it should be running and isn't.
    private func retry() {
        let go = lock.withLock { () -> Bool in
            guard wantsRunning, stream == nil, !starting else { return false }
            starting = true
            return true
        }
        guard go else { return }
        Task {
            await startStream()
            lock.withLock { starting = false }
        }
    }

    /// While the target is missing, look again every few seconds (windows
    /// have no "appeared" notification; displays get one, this is a backstop).
    private func pollWhileWaiting() {
        lock.withLock {
            guard poll == nil, wantsRunning else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 3, repeating: 3)
            timer.setEventHandler { [weak self] in self?.retry() }
            timer.resume()
            poll = timer
        }
    }

    private func stopPolling() {
        lock.withLock {
            poll?.cancel()
            poll = nil
        }
    }

    private func startStream() async {
        // Check first: calling ScreenCaptureKit without access makes macOS prompt.
        guard CGPreflightScreenCaptureAccess() else { return onError(.permissionDenied(.screenRecording, askedJustNow: false)) }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let current = lock.withLock { kind }
            let filter: SCContentFilter
            let pixelSize: CGSize
            let resolved: VideoSourceKind
            switch current {
            case .display(let id, let uuid, let name):
                let names = await MainActor.run { DisplayNames.current() }
                let candidates = content.displays.map {
                    DeviceMatching.Display(id: $0.displayID, uuid: displayUUID($0.displayID), name: names[$0.displayID] ?? "")
                }
                guard let match = DeviceMatching.display(id: id, uuid: uuid, name: name, among: candidates),
                      let display = content.displays.first(where: { $0.displayID == match.id }) else {
                    onError(.waiting("Waiting for display \(name.map { "“\($0)”" } ?? "") to connect…"))
                    return pollWhileWaiting()
                }
                let mode = CGDisplayCopyDisplayMode(match.id)
                pixelSize = CGSize(width: mode?.pixelWidth ?? display.width, height: mode?.pixelHeight ?? display.height)
                filter = SCContentFilter(display: display, excludingWindows: [])
                resolved = .display(displayID: match.id, uuid: match.uuid ?? uuid, name: match.name.isEmpty ? name : match.name)
            case .window(let id, let bundleID, let title):
                let candidates = content.windows.map {
                    DeviceMatching.Window(id: $0.windowID, bundleID: $0.owningApplication?.bundleIdentifier, title: $0.title ?? "")
                }
                guard let match = DeviceMatching.window(id: id, bundleID: bundleID, title: title, among: candidates),
                      let window = content.windows.first(where: { $0.windowID == match.id }) else {
                    onError(.waiting("Waiting for the window \(title.map { "“\($0)”" } ?? "") to open…"))
                    return pollWhileWaiting()
                }
                filter = SCContentFilter(desktopIndependentWindow: window)
                let scale = Double(filter.pointPixelScale)
                pixelSize = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
                resolved = .window(windowID: match.id, bundleID: match.bundleID, title: match.title)
            default:
                return onError(.failed("Not a screen source."))
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
            stopPolling()
            onError(.recovered)
            if resolved != current {
                lock.withLock { kind = resolved }
                onResolved(resolved)
            }
        } catch {
            lock.withLock { stream = nil }
            if !CGPreflightScreenCaptureAccess() {
                onError(.permissionDenied(.screenRecording, askedJustNow: false))
            } else {
                onError(.waiting("Screen capture couldn't start (\(error.localizedDescription)). Retrying…"))
                pollWhileWaiting()
            }
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

    /// Display unplugged, window closed, or the system stopped capture
    /// (e.g. around sleep). Wait for it to come back.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let wanted = lock.withLock { () -> Bool in
            if self.stream === stream { self.stream = nil }
            return wantsRunning
        }
        frames.clear()
        guard wanted else { return }
        onError(.waiting("Screen capture stopped. Reconnecting when it's available…"))
        pollWhileWaiting()
        retry()
    }
}

/// The display's hardware UUID, which survives restarts (unlike its ID).
func displayUUID(_ id: CGDirectDisplayID) -> String? {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, uuid) as String?
}

enum DisplayNames {
    @MainActor
    static func current() -> [CGDirectDisplayID: String] {
        Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (n.uint32Value, screen.localizedName)
        }, uniquingKeysWith: { a, _ in a })
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
