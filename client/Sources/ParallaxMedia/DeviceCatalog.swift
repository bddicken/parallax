import AppKit
import AVFoundation
import Observation
import ScreenCaptureKit

public struct CaptureDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
}

public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let name: String
}

public struct WindowInfo: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let title: String
    public let appName: String
}

/// What can be captured right now. Cameras and mics update on hot-plug;
/// displays and windows need `refreshShareableContent()`, which triggers the
/// Screen Recording permission prompt the first time.
@MainActor @Observable
public final class DeviceCatalog {
    public private(set) var cameras: [CaptureDeviceInfo] = []
    public private(set) var microphones: [CaptureDeviceInfo] = []
    public private(set) var displays: [DisplayInfo] = []
    public private(set) var windows: [WindowInfo] = []
    public private(set) var screenCaptureError: String?
    public private(set) var needsScreenRecordingPermission = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    public init() {
        refreshDevices()
        refreshDisplays()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplays() }
        })
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            })
        }
    }

    public func refreshDevices() {
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified
        ).devices.map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Displays from AppKit, which needs no Screen Recording permission.
    public func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayInfo(id: n.uint32Value, name: screen.localizedName)
        }
    }

    public func refreshShareableContent() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let names = Dictionary(NSScreen.screens.compactMap { screen -> (UInt32, String)? in
                guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return (n.uint32Value, screen.localizedName)
            }, uniquingKeysWith: { a, _ in a })
            displays = content.displays.map { DisplayInfo(id: $0.displayID, name: names[$0.displayID] ?? "Display \($0.displayID)") }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            windows = content.windows
                .filter { $0.windowLayer == 0 && $0.frame.width > 64 && $0.owningApplication?.processID != ownPID }
                .map { WindowInfo(id: $0.windowID, title: $0.title ?? "", appName: $0.owningApplication?.applicationName ?? "") }
                .sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }
            screenCaptureError = nil
            needsScreenRecordingPermission = false
        } catch {
            needsScreenRecordingPermission = !CGPreflightScreenCaptureAccess()
            screenCaptureError = needsScreenRecordingPermission ? nil : "Couldn't list screens: \(error.localizedDescription)"
        }
    }
}
