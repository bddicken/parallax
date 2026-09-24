import AppKit
import AVFoundation
import Observation
import ParallaxCore
import ScreenCaptureKit

public struct CaptureDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let modelID: String

    public var cameraKind: VideoSourceKind { .camera(uniqueID: id, name: name, modelID: modelID) }
    public var microphoneKind: AudioSourceKind { .device(uniqueID: id, name: name, modelID: modelID) }
}

public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let name: String
    public let uuid: String?

    public var kind: VideoSourceKind { .display(displayID: id, uuid: uuid, name: name) }
}

public struct WindowInfo: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let title: String
    public let appName: String
    public let bundleID: String?

    public var kind: VideoSourceKind { .window(windowID: id, bundleID: bundleID, title: title) }
}

/// What can be captured right now. Cameras and mics update on hot-plug;
/// displays and windows need `refreshShareableContent()`, which triggers the
/// Screen Recording permission prompt the first time.
@MainActor @Observable
public final class DeviceCatalog {
    public private(set) var cameras: [CaptureDeviceInfo] = []
    public private(set) var microphones: [CaptureDeviceInfo] = []
    public private(set) var displays: [DisplayInfo] = []
    public private(set) var outputDevices: [AudioOutputDevice] = []
    public private(set) var defaultOutputName: String?
    /// Called when outputs are added/removed or the system default changes.
    @ObservationIgnored public var onOutputsChanged: (() -> Void)?
    public private(set) var windows: [WindowInfo] = []
    public private(set) var screenCaptureError: String?
    public private(set) var needsScreenRecordingPermission = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    public init() {
        refreshDevices()
        refreshDisplays()
        refreshOutputs()
        CoreAudioOutputs.observeChanges { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshOutputs()
                self?.onOutputsChanged?()
            }
        }
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
        ).devices.map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName, modelID: $0.modelID) }
        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName, modelID: $0.modelID) }
    }

    private func refreshOutputs() {
        outputDevices = CoreAudioOutputs.all()
        let defaultID = CoreAudioOutputs.defaultOutput()
        defaultOutputName = outputDevices.first { $0.deviceID == defaultID }?.name
    }

    /// Displays from AppKit, which needs no Screen Recording permission.
    public func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayInfo(id: n.uint32Value, name: screen.localizedName, uuid: displayUUID(n.uint32Value))
        }
    }

    /// Lists displays and windows. Does nothing (and triggers no macOS
    /// prompt) until Screen Recording access has been granted.
    public func refreshShareableContent() async {
        guard CGPreflightScreenCaptureAccess() else {
            needsScreenRecordingPermission = true
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let names = Dictionary(NSScreen.screens.compactMap { screen -> (UInt32, String)? in
                guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return (n.uint32Value, screen.localizedName)
            }, uniquingKeysWith: { a, _ in a })
            displays = content.displays.map {
                DisplayInfo(id: $0.displayID, name: names[$0.displayID] ?? "Display \($0.displayID)", uuid: displayUUID($0.displayID))
            }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            windows = content.windows
                .filter { $0.windowLayer == 0 && $0.frame.width > 64 && $0.owningApplication?.processID != ownPID }
                .map {
                    WindowInfo(id: $0.windowID, title: $0.title ?? "", appName: $0.owningApplication?.applicationName ?? "",
                               bundleID: $0.owningApplication?.bundleIdentifier)
                }
                .sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }
            screenCaptureError = nil
            needsScreenRecordingPermission = false
        } catch {
            needsScreenRecordingPermission = !CGPreflightScreenCaptureAccess()
            screenCaptureError = needsScreenRecordingPermission ? nil : "Couldn't list screens: \(error.localizedDescription)"
        }
    }
}
