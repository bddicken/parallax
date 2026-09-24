import AppKit
import AVFoundation
import CoreGraphics
import ParallaxCore

/// The privacy permissions Parallax needs, with the System Settings pane for each.
public enum Permission: String, CaseIterable, Identifiable, Sendable {
    case camera, microphone, screenRecording

    public var id: String { rawValue }

    public enum Status: Sendable { case granted, notDetermined, denied }

    public var status: Status {
        switch self {
        case .camera: Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone: Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        // macOS doesn't expose "not asked yet" for screen recording.
        case .screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
    }

    /// Shows the system prompt if access isn't granted and macOS still allows
    /// one (only the first time for each permission). Returns whether access
    /// is granted now.
    @discardableResult
    public func request() async -> Bool {
        if status == .granted { return true }
        switch self {
        case .camera: return await AVCaptureDevice.requestAccess(for: .video)
        case .microphone: return await AVCaptureDevice.requestAccess(for: .audio)
        case .screenRecording: return CGRequestScreenCaptureAccess()
        }
    }

    @MainActor
    public func openSystemSettings() {
        let pane = switch self {
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    public var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .screenRecording: "Screen & System Audio Recording"
        }
    }

    public var symbol: String {
        switch self {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .screenRecording: "rectangle.dashed.badge.record"
        }
    }

    public var reason: String {
        switch self {
        case .camera: "Parallax needs camera access to show your cameras in scenes and recordings."
        case .microphone: "Parallax needs microphone access to mix your mics into streams and recordings."
        case .screenRecording: "Parallax needs screen recording access to capture displays, windows, and system audio."
        }
    }

    /// Screen capture access only takes effect in a freshly launched process.
    public var mayNeedRelaunch: Bool { self == .screenRecording }

    private static func map(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}

public enum SourceIssue: Sendable {
    case permissionDenied(Permission)
    case failed(String)
}

extension VideoSourceKind {
    public var permission: Permission? {
        switch self {
        case .camera: .camera
        case .display, .window: .screenRecording
        default: nil
        }
    }
}

extension AudioSourceKind {
    public var permission: Permission {
        switch self {
        case .device: .microphone
        case .systemAudio: .screenRecording
        }
    }
}
