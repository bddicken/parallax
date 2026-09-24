import AVFoundation
import Foundation
import ParallaxCore

/// Keeps an AVCaptureSession attached to one physical camera or mic across
/// unplug/replug, macOS renumbering it, and capture runtime errors.
///
/// While the device is missing it reports `.waiting` and reconnects by
/// itself when a matching device shows up.
final class ReconnectingCaptureSession: NSObject, @unchecked Sendable {
    struct Target: Sendable {
        var uniqueID: String
        var name: String?
        var modelID: String?
    }

    typealias Configure = (AVCaptureSession, AVCaptureDevice) throws -> Void

    /// Thrown by `configure` when the source that owns this session is gone
    /// (removed, or replaced after a settings change). Not a user-facing error.
    struct OwnerGone: Error {}

    private let mediaType: AVMediaType
    private let queue: DispatchQueue
    private let configure: Configure
    private let onIssue: SourceErrorHandler
    private let onResolved: @Sendable (Target) -> Void
    private let onDisconnected: @Sendable () -> Void

    // Only touched on `queue`.
    private var target: Target
    private var session: AVCaptureSession?
    private var deviceID: String?
    private var wantsRunning = false
    private var observers: [NSObjectProtocol] = []

    init(mediaType: AVMediaType, target: Target, queue: DispatchQueue, configure: @escaping Configure,
         onIssue: @escaping SourceErrorHandler, onResolved: @escaping @Sendable (Target) -> Void,
         onDisconnected: @escaping @Sendable () -> Void = {}) {
        self.mediaType = mediaType
        self.target = target
        self.queue = queue
        self.configure = configure
        self.onIssue = onIssue
        self.onResolved = onResolved
        self.onDisconnected = onDisconnected
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { self.connect() }
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self else { return }
            let gone = (note.object as? AVCaptureDevice)?.uniqueID
            queue.async { self.deviceWentAway(gone) }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: nil) { [weak self] note in
            guard let self else { return }
            let failed = note.object.map { ObjectIdentifier($0 as AnyObject) }
            queue.async { self.sessionFailed(failed) }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        session?.stopRunning()
    }

    func start() {
        queue.async { [self] in
            wantsRunning = true
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            wantsRunning = false
            teardown()
        }
    }

    private var displayName: String {
        target.name ?? (mediaType == .video ? "camera" : "audio device")
    }

    private func connect() {
        guard wantsRunning, session == nil else { return }
        let devices = Self.discover(mediaType)
        let candidates = devices.map { DeviceMatching.Device(uniqueID: $0.uniqueID, name: $0.localizedName, modelID: $0.modelID) }
        guard let match = DeviceMatching.device(uniqueID: target.uniqueID, name: target.name, modelID: target.modelID, among: candidates),
              let device = devices.first(where: { $0.uniqueID == match.uniqueID }) else {
            onIssue(.waiting("Waiting for \(displayName) to connect…"))
            return
        }
        let session = AVCaptureSession()
        do {
            session.beginConfiguration()
            try configure(session, device)
            session.commitConfiguration()
        } catch is OwnerGone {
            wantsRunning = false
            return
        } catch {
            onIssue(.failed("\(device.localizedName): \(error.localizedDescription)"))
            return
        }
        self.session = session
        deviceID = device.uniqueID
        session.startRunning()
        onIssue(.recovered)

        let resolved = Target(uniqueID: device.uniqueID, name: device.localizedName, modelID: device.modelID)
        if resolved.uniqueID != target.uniqueID || resolved.name != target.name || resolved.modelID != target.modelID {
            target = resolved
            onResolved(resolved)
        }
    }

    private func teardown() {
        session?.stopRunning()
        session = nil
        deviceID = nil
    }

    private func deviceWentAway(_ uniqueID: String?) {
        guard let uniqueID, uniqueID == deviceID else { return }
        teardown()
        onDisconnected()
        if wantsRunning { onIssue(.waiting("\(displayName) disconnected. Waiting for it to come back…")) }
    }

    private func sessionFailed(_ failed: ObjectIdentifier?) {
        guard let session, failed == ObjectIdentifier(session) else { return }
        teardown()
        onDisconnected()
        // Often transient (device reset, sleep/wake); try again shortly.
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
    }

    static func discover(_ mediaType: AVMediaType) -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = mediaType == .video
            ? [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
            : [.microphone, .external]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: mediaType, position: .unspecified).devices
    }
}
