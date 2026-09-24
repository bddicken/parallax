import CoreGraphics
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
    /// `name`/`modelID` let a camera be found again if macOS gives it a new
    /// uniqueID (e.g. plugged into a different port).
    case camera(uniqueID: String, name: String? = nil, modelID: String? = nil)
    /// `uuid` is the display's hardware identity, stable across restarts;
    /// `displayID` is only valid for the current login session.
    case display(displayID: UInt32, uuid: String? = nil, name: String? = nil)
    /// Window IDs change whenever the app relaunches, so the owning app and
    /// title are kept to find the window again.
    case window(windowID: UInt32, bundleID: String? = nil, title: String? = nil)
    case image(path: String)
    case color(RGBAColor)
    /// Rolling feed of recent chat messages.
    case chatFeed
    /// A single chat message the host has chosen to feature on screen.
    case featuredChat
}

extension VideoSourceKind {
    /// Identifies the physical thing captured, ignoring descriptive metadata,
    /// so the same monitor or camera isn't added as two sources.
    public var deviceKey: String? {
        switch self {
        case .camera(let uniqueID, _, _): "camera:\(uniqueID)"
        case .display(let id, let uuid, _): "display:\(uuid ?? String(id))"
        case .window(let id, _, _): "window:\(id)"
        default: nil
        }
    }
}

extension VideoSourceKind {
    /// Sources saved by older builds have no device name in their kind; the
    /// source's own name (which defaults to the device name) stands in so the
    /// device can still be matched after its ID changes.
    public func withNameHint(_ sourceName: String) -> VideoSourceKind {
        switch self {
        case .camera(let uniqueID, nil, let modelID): .camera(uniqueID: uniqueID, name: sourceName, modelID: modelID)
        case .display(let id, nil, nil): .display(displayID: id, uuid: nil, name: sourceName)
        default: self
        }
    }
}

extension AudioSourceKind {
    public func withNameHint(_ sourceName: String) -> AudioSourceKind {
        switch self {
        case .device(let uniqueID, nil, let modelID): .device(uniqueID: uniqueID, name: sourceName, modelID: modelID)
        default: self
        }
    }

    public var deviceKey: String {
        switch self {
        case .device(let uniqueID, _, _): "device:\(uniqueID)"
        case .systemAudio: "system"
        }
    }
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

public struct ItemBorder: Codable, Hashable, Sendable {
    public var isEnabled = false
    /// Stroke width in pixels at 1080p; scaled with the canvas.
    public var width: Double = 6
    public var color = RGBAColor(red: 1, green: 1, blue: 1)

    public init(isEnabled: Bool = false, width: Double = 6, color: RGBAColor = RGBAColor(red: 1, green: 1, blue: 1)) {
        self.isEnabled = isEnabled
        self.width = width
        self.color = color
    }
}

public struct ItemShadow: Codable, Hashable, Sendable {
    public var isEnabled = false
    /// How far the shadow is offset, in pixels at 1080p.
    public var distance: Double = 12
    /// Direction the shadow falls, in degrees clockwise from right (90 = straight down).
    public var angle: Double = 90
    /// Blur radius in pixels at 1080p.
    public var blur: Double = 24
    public var opacity: Double = 0.5
    public var color = RGBAColor(red: 0, green: 0, blue: 0)

    public init(isEnabled: Bool = false, distance: Double = 12, angle: Double = 90, blur: Double = 24,
                opacity: Double = 0.5, color: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0)) {
        self.isEnabled = isEnabled
        self.distance = distance
        self.angle = angle
        self.blur = blur
        self.opacity = opacity
        self.color = color
    }

    /// Offset in canvas pixels, top-left origin (+y is down).
    public func offset(canvasHeight: Double) -> CGSize {
        let scale = canvasHeight / 1080, radians = angle * .pi / 180
        return CGSize(width: cos(radians) * distance * scale, height: sin(radians) * distance * scale)
    }
}

public struct SceneItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    public var frame: NormalizedRect
    public var crop: CropInsets
    public var contentMode: ContentMode
    public var isVisible: Bool
    /// Fraction of the drawn image's shorter side; 0.5 makes a circle or pill.
    public var cornerRadius: Double
    public var border: ItemBorder
    public var shadow: ItemShadow

    public init(
        id: UUID = UUID(), sourceID: UUID, frame: NormalizedRect = .full,
        crop: CropInsets = .none, contentMode: ContentMode = .fit, isVisible: Bool = true,
        cornerRadius: Double = 0, border: ItemBorder = ItemBorder(), shadow: ItemShadow = ItemShadow()
    ) {
        self.id = id
        self.sourceID = sourceID
        self.frame = frame
        self.crop = crop
        self.contentMode = contentMode
        self.isVisible = isVisible
        self.cornerRadius = cornerRadius
        self.border = border
        self.shadow = shadow
    }

    // Decodes profiles saved before newer fields existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceID = try c.decode(UUID.self, forKey: .sourceID)
        frame = try c.decode(NormalizedRect.self, forKey: .frame)
        crop = try c.decodeIfPresent(CropInsets.self, forKey: .crop) ?? .none
        contentMode = try c.decodeIfPresent(ContentMode.self, forKey: .contentMode) ?? .fit
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        border = try c.decodeIfPresent(ItemBorder.self, forKey: .border) ?? ItemBorder()
        shadow = try c.decodeIfPresent(ItemShadow.self, forKey: .shadow) ?? ItemShadow()
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
    case device(uniqueID: String, name: String? = nil, modelID: String? = nil)
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

/// Where to play the program audio so you can hear it (headphones, usually).
public struct MonitorSettings: Codable, Hashable, Sendable {
    public enum Output: Codable, Hashable, Sendable {
        case off
        case systemDefault
        /// A Core Audio device UID, stable across reboots and reconnects.
        case device(uid: String)
    }

    public var output: Output = .off
    /// 0...1
    public var volume: Double = 0.8

    public init(output: Output = .off, volume: Double = 0.8) {
        self.output = output
        self.volume = volume
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
    public var monitor = MonitorSettings()

    public init() {}

    // Every field is optional on disk so profiles saved by older builds
    // still load after new settings are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Profile()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        videoSources = try c.decodeIfPresent([VideoSource].self, forKey: .videoSources) ?? d.videoSources
        audioSources = try c.decodeIfPresent([AudioSource].self, forKey: .audioSources) ?? d.audioSources
        scenes = try c.decodeIfPresent([StudioScene].self, forKey: .scenes) ?? d.scenes
        programSceneID = try c.decodeIfPresent(UUID.self, forKey: .programSceneID)
        output = try c.decodeIfPresent(OutputSettings.self, forKey: .output) ?? d.output
        recording = try c.decodeIfPresent(RecordingSettings.self, forKey: .recording) ?? d.recording
        transition = try c.decodeIfPresent(TransitionSettings.self, forKey: .transition) ?? d.transition
        broadcast = try c.decodeIfPresent(BroadcastSettings.self, forKey: .broadcast) ?? d.broadcast
        monitor = try c.decodeIfPresent(MonitorSettings.self, forKey: .monitor) ?? d.monitor
    }

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
