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

/// Ten-band graphic EQ at the ISO octave centers.
public struct EQSettings: Codable, Hashable, Sendable {
    public static let frequencies: [Double] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    public static let gainRange: ClosedRange<Double> = -12...12

    public var isEnabled: Bool = false
    /// One gain per entry in `frequencies`.
    public var gainsDB: [Double] = Array(repeating: 0, count: EQSettings.frequencies.count)

    public init(isEnabled: Bool = false, gainsDB: [Double] = Array(repeating: 0, count: EQSettings.frequencies.count)) {
        self.isEnabled = isEnabled
        self.gainsDB = gainsDB
    }

    public var isFlat: Bool { gainsDB.allSatisfy { $0 == 0 } }

    /// Gain for band `i`, clamped to `gainRange`; 0 for a missing band.
    public func gain(band i: Int) -> Double {
        gainsDB.indices.contains(i) ? min(max(gainsDB[i], Self.gainRange.lowerBound), Self.gainRange.upperBound) : 0
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
    public var eq: EQSettings

    public init(
        id: UUID = UUID(), name: String, kind: AudioSourceKind, gainDB: Double = 0, isMuted: Bool = false,
        delayMs: Int = 0, channelMode: ChannelMode = .mono, firstChannel: Int = 0,
        highPassEnabled: Bool = false, gate: NoiseGateSettings = NoiseGateSettings(), eq: EQSettings = EQSettings()
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
        self.eq = eq
    }

    // Decodes profiles saved before newer fields existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(AudioSourceKind.self, forKey: .kind)
        gainDB = try c.decode(Double.self, forKey: .gainDB)
        isMuted = try c.decode(Bool.self, forKey: .isMuted)
        delayMs = try c.decode(Int.self, forKey: .delayMs)
        channelMode = try c.decode(ChannelMode.self, forKey: .channelMode)
        firstChannel = try c.decode(Int.self, forKey: .firstChannel)
        highPassEnabled = try c.decode(Bool.self, forKey: .highPassEnabled)
        gate = try c.decode(NoiseGateSettings.self, forKey: .gate)
        eq = try c.decodeIfPresent(EQSettings.self, forKey: .eq) ?? EQSettings()
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

extension OutputSettings {
    public static let presets: [(width: Int, height: Int)] = [(3840, 2160), (2560, 1440), (1920, 1080), (1280, 720)]

    /// "4K", "1080p", … for the common sizes; otherwise "W × H".
    public var shortName: String { OutputResolution.name(forHeight: height) ?? "\(width) × \(height)" }
}

/// Size of a recording or stream relative to the canvas. Never upscales.
public enum OutputResolution: String, Codable, CaseIterable, Sendable {
    case canvas, p2160, p1440, p1080, p720

    public var height: Int? {
        switch self {
        case .canvas: nil
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        }
    }

    /// The encoded size for a canvas: same aspect, even dimensions, no larger than the canvas.
    public func size(for canvas: OutputSettings) -> (width: Int, height: Int) {
        guard let target = height, target < canvas.height else { return (canvas.width, canvas.height) }
        let width = Int((Double(canvas.width) * Double(target) / Double(canvas.height)).rounded())
        return (width - width % 2, target)
    }

    /// Whether this is an actual downscale for the canvas (so worth offering).
    public func isAvailable(for canvas: OutputSettings) -> Bool {
        height.map { $0 < canvas.height } ?? true
    }

    static func name(forHeight height: Int) -> String? {
        switch height {
        case 2160: "4K"
        case 1440: "1440p"
        case 1080: "1080p"
        case 720: "720p"
        default: nil
        }
    }
}

public enum Bitrates {
    /// Recording: high quality for editing later.
    public static func recording(height: Int, fps: Int, codec: VideoCodec) -> Int {
        let h264: Int = switch height {
        case 2160...: 60_000
        case 1440..<2160: 32_000
        case 1080..<1440: 16_000
        default: 8_000
        }
        let fpsFactor = fps > 30 ? 1.5 : 1
        let codecFactor = codec == .hevc ? 0.65 : 1
        return Int((Double(h264) * fpsFactor * codecFactor / 1000).rounded()) * 1000
    }

    /// Streaming: in line with YouTube's recommended ingest bitrates (H.264).
    public static func streaming(height: Int, fps: Int) -> Int {
        let high = fps > 30
        return switch height {
        case 2160...: high ? 40_000 : 30_000
        case 1440..<2160: high ? 18_000 : 12_000
        case 1080..<1440: high ? 9_000 : 6_000
        default: high ? 6_000 : 4_000
        }
    }

    public static func gigabytesPerHour(videoKbps: Int, audioKbps: Int) -> Double {
        Double(videoKbps + audioKbps) * 1000 * 3600 / 8 / 1_000_000_000
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
    public var resolution: OutputResolution = .canvas
    public var codec: VideoCodec = .h264
    public var container: RecordingContainer = .mov
    public var videoBitrateKbps: Int = 16_000
    public var audioBitrateKbps: Int = 256

    public init(directoryPath: String = RecordingSettings.defaultDirectory) {
        self.directoryPath = directoryPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecordingSettings()
        directoryPath = try c.decodeIfPresent(String.self, forKey: .directoryPath) ?? d.directoryPath
        resolution = try c.decodeIfPresent(OutputResolution.self, forKey: .resolution) ?? d.resolution
        codec = try c.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? d.codec
        container = try c.decodeIfPresent(RecordingContainer.self, forKey: .container) ?? d.container
        videoBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .videoBitrateKbps) ?? d.videoBitrateKbps
        audioBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .audioBitrateKbps) ?? d.audioBitrateKbps
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

/// What Parallax sends to parallax-server, which relays it unchanged to
/// each platform. Usually smaller than the canvas and the recording.
public struct StreamSettings: Codable, Hashable, Sendable {
    public var resolution: OutputResolution = .p1080
    public var videoBitrateKbps: Int = 6_000
    public var audioBitrateKbps: Int = 160
    public var keyframeIntervalSeconds: Int = 2

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StreamSettings()
        resolution = try c.decodeIfPresent(OutputResolution.self, forKey: .resolution) ?? d.resolution
        videoBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .videoBitrateKbps) ?? d.videoBitrateKbps
        audioBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .audioBitrateKbps) ?? d.audioBitrateKbps
        keyframeIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .keyframeIntervalSeconds) ?? d.keyframeIntervalSeconds
    }
}

/// Who can watch, for platforms that create a video per broadcast (YouTube).
public enum BroadcastPrivacy: String, Codable, CaseIterable, Sendable {
    case `public`, unlisted, `private`

    public var displayName: String { rawValue.capitalized }
}

/// Where parallax-server runs.
public enum ServerMode: String, Codable, CaseIterable, Sendable {
    /// Parallax runs it on this Mac while the app is open.
    case local
    /// One you run yourself, at `serverURL`.
    case remote
}

public struct BroadcastSettings: Codable, Hashable, Sendable {
    public var serverMode = ServerMode.local
    /// Base URL of a remote parallax-server. Empty means offline (or mock).
    public var serverURL: String = ""
    /// Use the built-in fake server (generated chat) when no URL is set.
    public var useMockServer = false
    public var stream = StreamSettings()
    /// Title for the next broadcast, where the platform asks for one (YouTube).
    public var title = ""
    public var privacy = BroadcastPrivacy.unlisted
    /// Destinations checked last time. Nil until you pick, which means each
    /// destination's own default.
    public var destinationIDs: [String]?

    public init(serverURL: String = "") {
        self.serverURL = serverURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
        // Profiles from before the built-in server keep the server they set up.
        serverMode = try c.decodeIfPresent(ServerMode.self, forKey: .serverMode) ?? (serverURL.isEmpty ? .local : .remote)
        useMockServer = try c.decodeIfPresent(Bool.self, forKey: .useMockServer) ?? false
        stream = try c.decodeIfPresent(StreamSettings.self, forKey: .stream) ?? StreamSettings()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        privacy = try c.decodeIfPresent(BroadcastPrivacy.self, forKey: .privacy) ?? .unlisted
        destinationIDs = try c.decodeIfPresent([String].self, forKey: .destinationIDs)
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

/// Text size of the on-stream chat feed; each step is 25% bigger.
public enum ChatTextSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public var scale: Double {
        switch self {
        case .small: 1
        case .medium: 1.25
        case .large: 1.5
        }
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
    public var chatTextSize = ChatTextSize.small

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
        chatTextSize = try c.decodeIfPresent(ChatTextSize.self, forKey: .chatTextSize) ?? d.chatTextSize
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
