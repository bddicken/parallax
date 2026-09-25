import AVFoundation
import CoreImage
import Foundation
import ParallaxCore

/// Owns the whole local pipeline: sources → compositor/mixer → sinks.
/// The app describes what it wants with a `Profile`; the engine reconciles
/// running captures against it.
@MainActor
public final class MediaEngine {
    public let preview = PreviewSink()
    public var onLevels: ((MixerLevels) -> Void)?
    public var onSourceIssue: ((UUID, SourceIssue) -> Void)?

    private let sinks = SinkHub()
    private let registry = SourceRegistry()
    private let compositor: Compositor
    private let mixer: AudioMixer

    private var videoSources: [UUID: VideoSource] = [:]
    private var audioNodes: [UUID: (kind: AudioSourceKind, node: AudioInputNode)] = [:]
    private var captureFPS = 0
    private var canvas = OutputSettings(width: 0, height: 0)
    private var recorder: Recorder?
    private var uplink: Uplink?
    private var monitor: AudioMonitor?
    private var monitorSettings = MonitorSettings()
    /// Why monitoring isn't playing, if it should be (e.g. device unplugged).
    public private(set) var monitorError: String?
    public var onMonitorStateChanged: (() -> Void)?
    /// A source re-found its device under a new identity (display renumbered
    /// after a restart, camera replugged into another port, window reopened).
    /// Save it so next launch goes straight to the right device.
    public var onVideoSourceResolved: ((UUID, VideoSourceKind) -> Void)?
    public var onAudioSourceResolved: ((UUID, AudioSourceKind) -> Void)?

    private var feedLines: [ChatOverlayLine] = []
    private var feedSize = ChatOverlayRenderer.feedSize
    private var feedScale: CGFloat = 1
    private var chatTextSize = ChatTextSize.small
    private var feedImage = ChatOverlayRenderer.feed([])
    private var featuredImage: CIImage?
    private var scenes: [StudioScene] = []
    private var programID: UUID?

    public init() {
        compositor = Compositor(registry: registry, sinks: sinks)
        mixer = AudioMixer(sinks: sinks)
        sinks.add(preview)
        mixer.onLevels = { [weak self] levels in self?.onLevels?(levels) }
        compositor.start()
        mixer.start()
    }

    // MARK: Configuration

    public func apply(_ profile: Profile) {
        let fpsChanged = captureFPS != profile.output.fps
        let sizeChanged = canvas.width != profile.output.width || canvas.height != profile.output.height
        captureFPS = profile.output.fps
        canvas = profile.output

        let wantedVideo = Dictionary(uniqueKeysWithValues: profile.videoSources.map { ($0.id, $0) })
        for (id, running) in videoSources {
            // Screens capture at the canvas rate and size; cameras pick 4K or 1080p from it.
            let isCamera = if case .camera = running.kind { true } else { false }
            let needsRestart = (fpsChanged && running.kind.isScreen) || (sizeChanged && (running.kind.isScreen || isCamera))
            if wantedVideo[id]?.kind != running.kind || needsRestart {
                registry[id]?.stop()
                registry[id] = nil
                videoSources[id] = nil
            }
        }
        for source in profile.videoSources {
            if videoSources[source.id] == nil {
                let node = makeVideoNode(source)
                registry[source.id] = node
                node.start()
            }
            videoSources[source.id] = source
            registry[source.id]?.setDelay(ms: source.delayMs)
        }

        let wantedAudio = Dictionary(uniqueKeysWithValues: profile.audioSources.map { ($0.id, $0) })
        for (id, running) in audioNodes where wantedAudio[id]?.kind != running.kind {
            running.node.stop()
            audioNodes[id] = nil
        }
        mixer.configure(profile.audioSources)
        for source in profile.audioSources where audioNodes[source.id] == nil {
            let node = makeAudioNode(source)
            audioNodes[source.id] = (source.kind, node)
            node.start()
        }

        compositor.update(scenes: profile.scenes, output: profile.output)
        scenes = profile.scenes
        chatTextSize = profile.chatTextSize
        resizeChatFeed()
        applyMonitor(profile.monitor)
    }

    // MARK: Monitoring

    private func applyMonitor(_ settings: MonitorSettings) {
        let previous = monitorSettings
        monitorSettings = settings
        if settings.output == previous.output, monitor != nil || settings.output == .off {
            monitor?.setVolume(settings.volume)
            return
        }
        restartMonitor()
    }

    /// Rebuilds the monitor output, e.g. after a device is plugged in or the
    /// system default output changes.
    public func restartMonitor() {
        if let monitor {
            sinks.remove(monitor)
            monitor.stop()
        }
        monitor = nil
        monitorError = nil
        defer { onMonitorStateChanged?() }

        let deviceID: AudioDeviceID?
        switch monitorSettings.output {
        case .off:
            return
        case .systemDefault:
            deviceID = nil
        case .device(let uid):
            guard let id = CoreAudioOutputs.deviceID(forUID: uid) else {
                monitorError = "That output device isn't connected."
                return
            }
            deviceID = id
        }
        do {
            let m = try AudioMonitor(deviceID: deviceID, volume: monitorSettings.volume)
            monitor = m
            sinks.add(m)
        } catch {
            monitorError = error.localizedDescription
        }
    }

    public var isMonitoring: Bool { monitor?.isRunning ?? false }

    public func setProgram(_ sceneID: UUID?, transition: TransitionSettings) {
        compositor.setProgram(sceneID, transition: transition)
        programID = sceneID
        resizeChatFeed()
    }

    /// Pixel size of a source's current image, if it has produced one.
    public func sourceSize(_ id: UUID) -> CGSize? {
        registry[id]?.image(at: hostNow())?.extent.size
    }

    /// Restarts every capture that depends on `permission`, e.g. after the
    /// user grants it in System Settings.
    public func restartSources(needing permission: Permission) {
        for (id, source) in videoSources where source.kind.permission == permission {
            registry[id]?.stop()
            registry[id]?.start()
        }
        for entry in audioNodes.values where entry.kind.permission == permission {
            entry.node.stop()
            entry.node.start()
        }
    }

    // MARK: Chat overlays

    public func updateChat(feed: [ChatOverlayLine], featured: ChatOverlayLine?) {
        feedLines = feed
        feedImage = renderFeed()
        featuredImage = featured.map(ChatOverlayRenderer.banner)
        pushChatImages()
    }

    /// Draws the feed at its box's pixel size in the live scene, so resizing
    /// the box reflows messages instead of scaling the text. Text scales with
    /// the canvas and the chosen text size.
    private func resizeChatFeed() {
        let size = chatFeedBoxSize() ?? feedSize
        let scale = CGFloat(max(canvas.height, 1)) / 1080 * chatTextSize.scale
        guard size != feedSize || scale != feedScale else { return }
        feedSize = size
        feedScale = scale
        feedImage = renderFeed()
        pushChatImages()
    }

    private func chatFeedBoxSize() -> CGSize? {
        guard canvas.width > 0, canvas.height > 0,
              let scene = scenes.first(where: { $0.id == programID }) else { return nil }
        let feedIDs = Set(videoSources.values.filter { $0.kind == .chatFeed }.map(\.id))
        guard let item = scene.items.last(where: { feedIDs.contains($0.sourceID) }) else { return nil }
        let rect = item.frame.denormalized(in: CGSize(width: canvas.width, height: canvas.height))
        return CGSize(width: rect.width.rounded(), height: rect.height.rounded())
    }

    private func renderFeed() -> CIImage {
        ChatOverlayRenderer.feed(feedLines, size: feedSize, scale: feedScale)
    }

    private func pushChatImages() {
        for (id, source) in videoSources {
            guard let node = registry[id] as? StaticImageNode else { continue }
            switch source.kind {
            case .chatFeed: node.setImage(feedImage)
            case .featuredChat: node.setImage(featuredImage)
            default: break
            }
        }
    }

    // MARK: Recording

    public var isRecording: Bool { recorder != nil }

    public func startRecording(_ settings: RecordingSettings) throws -> URL {
        guard recorder == nil else { throw MediaError("Already recording.") }
        let r = try Recorder(directory: URL(filePath: settings.directoryPath, directoryHint: .isDirectory),
                             recording: settings, output: compositor.outputSettings)
        recorder = r
        sinks.add(r)
        return r.url
    }

    public func stopRecording() async throws -> URL {
        guard let r = recorder else { throw MediaError("Not recording.") }
        sinks.remove(r)
        recorder = nil
        return try await r.finish()
    }

    // MARK: Streaming

    public var isStreaming: Bool { uplink != nil }

    /// Starts sending the program to parallax-server at `url` (SRT).
    public func startStreaming(to url: URL, settings: StreamSettings, onState: @escaping @Sendable (UplinkState) -> Void) {
        stopStreaming()
        let u = Uplink(url: url, stream: settings, output: compositor.outputSettings, onState: onState)
        uplink = u
        sinks.add(u)
    }

    public func stopStreaming() {
        guard let u = uplink else { return }
        sinks.remove(u)
        u.stop()
        uplink = nil
    }

    // MARK: Nodes

    // Record the new identity as what's running before the app saves it, so
    // the resulting profile change doesn't restart a capture that's working.
    private func videoSourceResolved(_ id: UUID, _ kind: VideoSourceKind) {
        guard videoSources[id] != nil else { return }
        videoSources[id]?.kind = kind
        onVideoSourceResolved?(id, kind)
    }

    private func audioSourceResolved(_ id: UUID, _ kind: AudioSourceKind) {
        guard let entry = audioNodes[id] else { return }
        audioNodes[id] = (kind, entry.node)
        onAudioSourceResolved?(id, kind)
    }

    private func makeVideoNode(_ source: VideoSource) -> VideoSourceNode {
        let id = source.id
        let onError: SourceErrorHandler = { [weak self] issue in
            Task { @MainActor in self?.onSourceIssue?(id, issue) }
        }
        let onResolved: @Sendable (VideoSourceKind) -> Void = { [weak self] kind in
            Task { @MainActor in self?.videoSourceResolved(id, kind) }
        }
        switch source.kind.withNameHint(source.name) {
        case .camera(let uniqueID, let name, let modelID):
            return CameraNode(uniqueID: uniqueID, name: name, modelID: modelID, wants4K: canvas.height >= 2160,
                              onError: onError, onResolved: onResolved)
        case .display, .window:
            return ScreenNode(kind: source.kind.withNameHint(source.name), fps: captureFPS, maxWidth: canvas.width,
                              onError: onError, onResolved: onResolved)
        case .image(let path):
            let image = CIImage(contentsOf: URL(filePath: path))
            if image == nil { onError(.failed("Could not open image at \(path).")) }
            return StaticImageNode(image: image)
        case .color(let c):
            let color = CIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
            return StaticImageNode(image: CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080)))
        case .chatFeed:
            return StaticImageNode(image: feedImage)
        case .featuredChat:
            return StaticImageNode(image: featuredImage)
        }
    }

    private func makeAudioNode(_ source: AudioSource) -> AudioInputNode {
        let id = source.id
        let onBuffer: AudioBufferHandler = { [mixer] pcm in mixer.write(pcm, to: id) }
        let onError: SourceErrorHandler = { [weak self] issue in
            Task { @MainActor in self?.onSourceIssue?(id, issue) }
        }
        let onResolved: @Sendable (AudioSourceKind) -> Void = { [weak self] kind in
            Task { @MainActor in self?.audioSourceResolved(id, kind) }
        }
        switch source.kind.withNameHint(source.name) {
        case .device(let uniqueID, let name, let modelID):
            return DeviceAudioNode(uniqueID: uniqueID, name: name, modelID: modelID, onBuffer: onBuffer,
                                   onError: onError, onResolved: onResolved)
        case .systemAudio: return SystemAudioNode(onBuffer: onBuffer, onError: onError)
        }
    }
}

extension VideoSourceKind {
    public var isScreen: Bool {
        switch self {
        case .display, .window: true
        default: false
        }
    }
}
