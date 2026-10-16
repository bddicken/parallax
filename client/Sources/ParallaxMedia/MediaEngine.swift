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
    /// Plays into the mixer through the profile's Music input, if it has one.
    public let music = SongPlayer()
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
    /// A recording file failed partway through. `stopped` is true if the
    /// recorder couldn't carry on in a new file; call `stopRecording()`.
    public var onRecordingProblem: ((_ message: String, _ stopped: Bool) -> Void)?

    private var feedLines: [ChatOverlayLine] = []
    private var feedSize = ChatOverlayRenderer.feedSize
    private var feedScale: CGFloat = 1
    private var chatTextSize = ChatTextSize.small
    private var feedLayers = ChatOverlayRenderer.feedLayers([], arriving: 0)
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

        // Only the music input for the current music mode runs.
        let audioSources = profile.activeAudioSources
        let wantedAudio = Dictionary(uniqueKeysWithValues: audioSources.map { ($0.id, $0) })
        for (id, running) in audioNodes where wantedAudio[id]?.kind != running.kind {
            running.node.stop()
            audioNodes[id] = nil
        }
        mixer.configure(audioSources)
        for source in audioSources where audioNodes[source.id] == nil {
            let node = makeAudioNode(source)
            audioNodes[source.id] = (source.kind, node)
            node.start()
        }

        compositor.update(scenes: profile.scenes, output: profile.output,
                          notRecorded: Set(profile.videoSources.filter { !$0.isInRecording }.map(\.id)))
        scenes = profile.scenes
        chatTextSize = profile.chatTextSize
        resizeChatFeed()
        applyMonitor(profile.monitor)
    }

    // MARK: Monitoring

    private func applyMonitor(_ settings: MonitorSettings) {
        let previous = monitorSettings
        monitorSettings = settings
        mixer.setMonitorMix(settings.customGains)
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
            mixer.setMonitor(nil)
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
            mixer.setMonitor(m)
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
        // Messages after the newest one already showing slide in.
        let arriving: Int
        if let newest = feedLines.last, let i = feed.lastIndex(where: { $0.id == newest.id }) {
            arriving = feed.count - 1 - i
        } else {
            arriving = feedLines.isEmpty ? feed.count : 0
        }
        featuredImage = featured.map(ChatOverlayRenderer.banner)
        // Leave the feed alone (it may be mid-slide) if only the featured
        // message changed.
        guard feed != feedLines else { return pushChatImages(feed: false) }
        feedLines = feed
        feedLayers = renderFeed(arriving: arriving)
        pushChatImages(animated: arriving > 0)
    }

    /// Draws the feed at its box's pixel size in the live scene, so resizing
    /// the box reflows messages instead of scaling the text. Text scales with
    /// the canvas and the chosen text size.
    private func resizeChatFeed() {
        let size = chatFeedBoxSize() ?? feedSize
        let scale = CGFloat(Double(max(canvas.height, 1)) / 1080 * chatTextSize.scale)
        guard size != feedSize || scale != feedScale else { return }
        feedSize = size
        feedScale = scale
        feedLayers = renderFeed(arriving: 0)
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

    private func renderFeed(arriving: Int) -> ChatFeedLayers {
        ChatOverlayRenderer.feedLayers(feedLines, arriving: arriving, size: feedSize, scale: feedScale)
    }

    private func pushChatImages(feed: Bool = true, animated: Bool = false) {
        for (id, source) in videoSources {
            switch source.kind {
            case .chatFeed where feed: (registry[id] as? ChatFeedNode)?.show(feedLayers, animated: animated)
            case .featuredChat: (registry[id] as? StaticImageNode)?.setImage(featuredImage)
            default: break
            }
        }
    }

    // MARK: Recording

    /// One per output being recorded (the program and/or scenes on their
    /// own), all started and stopped on the same frame.
    private var recorders: [Recorder] = []
    /// Recorders that couldn't carry on. Recording as a whole stops only
    /// once none can.
    private var stoppedRecorders: Set<ObjectIdentifier> = []

    public var isRecording: Bool { !recorders.isEmpty }

    /// The files being written now (for tests).
    var activeRecorders: [Recorder] { recorders }

    /// Starts recording every output in `settings`, each to its own file:
    /// the program and/or scenes on their own. Returns the files' URLs.
    public func startRecording(_ settings: RecordingSettings) throws -> [URL] {
        guard recorders.isEmpty else { throw MediaError("Already recording.") }
        let sceneNames = Dictionary(scenes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let outputs = settings.outputs.filter { $0.sceneID.map { sceneNames[$0] != nil } ?? true }
        guard !outputs.isEmpty else {
            throw MediaError("Nothing to record. Choose the main feed or a scene.")
        }
        let directory = URL(filePath: settings.directoryPath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Date().formatted(.verbatim(
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
            timeZone: .current, calendar: .current))
        let names = RecordingSettings.fileNames(stamp: stamp, scenes: outputs.map { $0.sceneID.map { sceneNames[$0] ?? "" } })
        let timecode = TimecodeClock()
        let canvas = compositor.outputSettings
        var made: [Recorder] = []
        do {
            for (file, name) in zip(outputs, names) {
                let url = directory.appending(path: "\(name).\(settings.container.rawValue)")
                made.append(try Recorder(url: url, recording: settings, target: file, output: canvas, timecode: timecode) {
                    [weak self] recorder, message, stopped in
                    Task { @MainActor in self?.recorderProblem(recorder, message, stopped: stopped) }
                })
            }
        } catch {
            made.forEach { $0.discard() }
            throw error
        }
        recorders = made
        stoppedRecorders = []
        // All at once, so every file starts on the same frame.
        sinks.add(zip(made, outputs).map { ($0, $1.sceneID.map(OutputFeed.scene) ?? .recording) })
        updateActivity()
        return made.map(\.url)
    }

    private func recorderProblem(_ recorder: Recorder, _ message: String, stopped: Bool) {
        // Ignore a recording that has already been stopped.
        guard recorders.contains(where: { $0 === recorder }) else { return }
        if stopped { stoppedRecorders.insert(ObjectIdentifier(recorder)) }
        let named = recorders.count > 1 ? "\(recorder.url.lastPathComponent): \(message)" : message
        onRecordingProblem?(named, stoppedRecorders.count == recorders.count)
    }

    /// Stops every file. Throws only if nothing at all was saved.
    public func stopRecording() async throws -> RecordingResult {
        guard !recorders.isEmpty else { throw MediaError("Not recording.") }
        let stopping = recorders
        recorders = []
        updateActivity()
        sinks.remove(stopping)
        // Let frames and audio already handed out reach every file, so they
        // all end on the same frame and sample.
        await compositor.flush()
        await mixer.flush()
        var results = [Result<RecordingResult, Error>?](repeating: nil, count: stopping.count)
        await withTaskGroup(of: (Int, Result<RecordingResult, Error>).self) { group in
            for (i, r) in stopping.enumerated() {
                group.addTask {
                    do { return (i, .success(try await r.finish())) } catch { return (i, .failure(error)) }
                }
            }
            for await (i, result) in group { results[i] = result }
        }
        var files: [URL] = [], problems: [String] = []
        for (recorder, result) in zip(stopping, results) {
            let prefix = stopping.count > 1 ? "\(recorder.url.lastPathComponent): " : ""
            switch result {
            case .success(let r):
                files += r.files
                if let problem = r.problem { problems.append(prefix + problem) }
            case .failure(let error):
                problems.append(prefix + error.localizedDescription)
            case nil:
                break
            }
        }
        guard !files.isEmpty else { throw MediaError(problems.first ?? "Nothing was recorded.") }
        return RecordingResult(files: files, problem: problems.isEmpty ? nil : problems.joined(separator: "\n"))
    }

    // MARK: Power

    private var activity: NSObjectProtocol?

    /// While recording or streaming, keep the Mac and its displays awake
    /// (a sleeping display captures as black) and opt out of App Nap, which
    /// would throttle capture and encoding while Parallax is in the background.
    private func updateActivity() {
        let busy = !recorders.isEmpty || uplink != nil
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical],
                reason: "Recording or streaming")
        } else if !busy, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    // MARK: Streaming

    public var isStreaming: Bool { uplink != nil }

    /// Starts sending the program to parallax-server at `url` (SRT).
    public func startStreaming(to url: URL, settings: StreamSettings, onState: @escaping @Sendable (UplinkState) -> Void) {
        stopStreaming()
        let u = Uplink(url: url, stream: settings, output: compositor.outputSettings, onState: onState)
        uplink = u
        sinks.add(u)
        updateActivity()
    }

    public func stopStreaming() {
        guard let u = uplink else { return }
        sinks.remove(u)
        u.stop()
        uplink = nil
        updateActivity()
    }

    /// Like `stopStreaming`, but blocks (briefly) until the connection
    /// closes. For app quit.
    public func stopStreamingAndWait(timeout: TimeInterval = 1) {
        guard let u = uplink else { return }
        sinks.remove(u)
        uplink = nil
        u.stopAndWait(timeout: timeout)
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
            return ChatFeedNode(feedLayers)
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
        case .music: return MusicNode(player: music, mixer: mixer, id: id)
        case .webPlayer: return WebAudioNode(onBuffer: onBuffer, onError: onError)
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
