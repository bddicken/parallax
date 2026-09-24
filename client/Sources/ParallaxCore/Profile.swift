import Foundation

public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public enum VideoSourceKind: Codable, Hashable, Sendable {
    case camera(uniqueID: String)
    case display(displayID: UInt32)
    case window(windowID: UInt32)
    case image(path: String)
    case color(RGBAColor)
    /// Rolling feed of recent chat messages.
    case chatFeed
    /// A single chat message the host has chosen to feature on screen.
    case featuredChat
}

/// A video input. Sources are global; scenes place them via `SceneItem`s, so
/// one camera can appear in many scenes while being captured once.
public struct VideoSource: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: VideoSourceKind
    public var delayMs: Int

    public init(id: UUID = UUID(), name: String, kind: VideoSourceKind, delayMs: Int = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.delayMs = delayMs
    }
}

public struct SceneItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    public var frame: NormalizedRect
    public var crop: CropInsets
    public var contentMode: ContentMode
    public var isVisible: Bool

    public init(
        id: UUID = UUID(), sourceID: UUID, frame: NormalizedRect = .full,
        crop: CropInsets = .none, contentMode: ContentMode = .fit, isVisible: Bool = true
    ) {
        self.id = id
        self.sourceID = sourceID
        self.frame = frame
        self.crop = crop
        self.contentMode = contentMode
        self.isVisible = isVisible
    }
}

public struct StudioScene: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Drawn in order, so the last item is on top.
    public var items: [SceneItem]

    public init(id: UUID = UUID(), name: String, items: [SceneItem] = []) {
        self.id = id
        self.name = name
        self.items = items
    }
}

public enum AudioSourceKind: Codable, Hashable, Sendable {
    case device(uniqueID: String)
    /// Everything the Mac is playing, via ScreenCaptureKit (minus Parallax itself).
    case systemAudio
}

public enum ChannelMode: String, Codable, CaseIterable, Sendable {
    /// Take one input channel and place it center.
    case mono
    /// Take two consecutive input channels as left/right.
    case stereo
}

public struct NoiseGateSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool = false
    public var thresholdDB: Double = -45

    public init(isEnabled: Bool = false, thresholdDB: Double = -45) {
        self.isEnabled = isEnabled
        self.thresholdDB = thresholdDB
    }
}

public struct AudioSource: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: AudioSourceKind
    public var gainDB: Double
    public var isMuted: Bool
    public var delayMs: Int
    public var channelMode: ChannelMode
    /// Zero-based input channel (first of the pair for stereo).
    public var firstChannel: Int
    public var highPassEnabled: Bool
    public var gate: NoiseGateSettings

    public init(
        id: UUID = UUID(), name: String, kind: AudioSourceKind, gainDB: Double = 0, isMuted: Bool = false,
        delayMs: Int = 0, channelMode: ChannelMode = .mono, firstChannel: Int = 0,
        highPassEnabled: Bool = false, gate: NoiseGateSettings = NoiseGateSettings()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.gainDB = gainDB
        self.isMuted = isMuted
        self.delayMs = delayMs
        self.channelMode = channelMode
        self.firstChannel = firstChannel
        self.highPassEnabled = highPassEnabled
        self.gate = gate
    }
}

public struct OutputSettings: Codable, Hashable, Sendable {
    public var width: Int = 1920
    public var height: Int = 1080
    public var fps: Int = 30

    public init(width: Int = 1920, height: Int = 1080, fps: Int = 30) {
        self.width = width
        self.height = height
        self.fps = fps
    }
}

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264, hevc
}

public enum RecordingContainer: String, Codable, CaseIterable, Sendable {
    case mov, mp4
}

public struct RecordingSettings: Codable, Hashable, Sendable {
    public var directoryPath: String
    public var codec: VideoCodec = .h264
    public var container: RecordingContainer = .mov
    public var videoBitrateKbps: Int = 16_000
    public var audioBitrateKbps: Int = 256

    public init(directoryPath: String = RecordingSettings.defaultDirectory) {
        self.directoryPath = directoryPath
    }

    public static var defaultDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Movies/Parallax", directoryHint: .isDirectory).path
    }
}

public enum TransitionKind: String, Codable, CaseIterable, Sendable {
    case cut, fade
}

public struct TransitionSettings: Codable, Hashable, Sendable {
    public var kind: TransitionKind = .fade
    public var durationMs: Int = 300

    public init(kind: TransitionKind = .fade, durationMs: Int = 300) {
        self.kind = kind
        self.durationMs = durationMs
    }
}

public struct BroadcastSettings: Codable, Hashable, Sendable {
    /// Base URL of parallax-server. Empty means use the built-in mock.
    public var serverURL: String = ""
    public var uplinkVideoBitrateKbps: Int = 8_000

    public init(serverURL: String = "") {
        self.serverURL = serverURL
    }
}

/// Everything the user configures, persisted as one JSON document.
public struct Profile: Codable, Hashable, Sendable {
    public var version: Int = 1
    public var videoSources: [VideoSource] = []
    public var audioSources: [AudioSource] = []
    public var scenes: [StudioScene] = []
    public var programSceneID: UUID?
    public var output = OutputSettings()
    public var recording = RecordingSettings()
    public var transition = TransitionSettings()
    public var broadcast = BroadcastSettings()

    public init() {}

    public static func makeDefault() -> Profile {
        var p = Profile()
        let scene = StudioScene(name: "Main")
        p.scenes = [scene, StudioScene(name: "Screen Share"), StudioScene(name: "Be Right Back")]
        p.programSceneID = scene.id
        return p
    }

    public func videoSource(_ id: UUID) -> VideoSource? { videoSources.first { $0.id == id } }
    public func scene(_ id: UUID?) -> StudioScene? { scenes.first { $0.id == id } }
}
