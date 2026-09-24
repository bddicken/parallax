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
    private var recorder: Recorder?
    private var monitor: AudioMonitor?
    private var monitorSettings = MonitorSettings()
    /// Why monitoring isn't playing, if it should be (e.g. device unplugged).
    public private(set) var monitorError: String?
    public var onMonitorStateChanged: (() -> Void)?

    private var feedImage = ChatOverlayRenderer.feed([])
    private var featuredImage: CIImage?

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
        captureFPS = profile.output.fps

        let wantedVideo = Dictionary(uniqueKeysWithValues: profile.videoSources.map { ($0.id, $0) })
        for (id, running) in videoSources {
            let needsRestart = fpsChanged && running.kind.isScreen
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
        feedImage = ChatOverlayRenderer.feed(feed)
        featuredImage = featured.map(ChatOverlayRenderer.banner)
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

    // MARK: Nodes

    private func makeVideoNode(_ source: VideoSource) -> VideoSourceNode {
        let id = source.id
        let onError: SourceErrorHandler = { [weak self] issue in
            Task { @MainActor in self?.onSourceIssue?(id, issue) }
        }
        switch source.kind {
        case .camera(let uniqueID):
            return CameraNode(uniqueID: uniqueID, onError: onError)
        case .display(let displayID):
            return ScreenNode(target: .display(displayID), fps: captureFPS, onError: onError)
        case .window(let windowID):
            return ScreenNode(target: .window(windowID), fps: captureFPS, onError: onError)
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
        switch source.kind {
        case .device(let uniqueID): return DeviceAudioNode(uniqueID: uniqueID, onBuffer: onBuffer, onError: onError)
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
