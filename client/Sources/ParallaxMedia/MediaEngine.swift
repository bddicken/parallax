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

    /// Recording in progress: one file per output, all started and stopped on
    /// the same frame.
    private struct Take {
        struct Output {
            let settings: RecordingOutput
            /// File name without extension, e.g. "Parallax 2026-09-25 14.02.11 - Camera".
            let name: String
            /// nil once it has given up after repeated failures.
            var recorder: Recorder?
            var part = 1
            var partStarted = hostNow()
            var quickFailures = 0
        }

        let id = UUID()
        let settings: RecordingSettings
        let directory: URL
        let canvas: OutputSettings
        let timecode = TimecodeClock()
        var outputs: [Output] = []
        /// Every file, in the order it was started.
        var recorders: [Recorder] = []
    }

    private var take: Take?
    /// Something went wrong mid-recording. Called on the main actor.
    public var onRecordingIssue: ((String) -> Void)?

    public var isRecording: Bool { take != nil }

    /// The files being written now (for tests).
    var activeRecorders: [Recorder] { take?.outputs.compactMap(\.recorder) ?? [] }

    /// Starts recording every output in `settings`: the program and/or
    /// individual scenes, each to its own file. Returns the files' URLs.
    public func startRecording(_ settings: RecordingSettings) throws -> [URL] {
        guard take == nil else { throw MediaError("Already recording.") }
        let sceneNames = Dictionary(scenes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let outputs = settings.outputs.filter { $0.sceneID.map { sceneNames[$0] != nil } ?? true }
        guard !outputs.isEmpty else {
            throw MediaError("Nothing to record. Turn on the program or a scene in Settings › Recording.")
        }
        let directory = URL(filePath: settings.directoryPath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Date().formatted(.verbatim(
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
            timeZone: .current, calendar: .current))
        let names = RecordingSettings.fileNames(stamp: stamp, scenes: outputs.map { $0.sceneID.map { sceneNames[$0] ?? "" } })

        var t = Take(settings: settings, directory: directory, canvas: compositor.outputSettings)
        t.outputs = zip(outputs, names).map { Take.Output(settings: $0, name: $1) }
        do {
            for i in t.outputs.indices {
                let r = try makeRecorder(t, output: i)
                t.outputs[i].recorder = r
                t.recorders.append(r)
            }
        } catch {
            t.recorders.forEach { $0.discard() }
            throw error
        }
        take = t
        // All at once, so every file starts on the same frame.
        sinks.add(t.outputs.map { ($0.recorder!, $0.settings.sceneID) })
        updateActivity()
        return t.recorders.map(\.url)
    }

    /// Stops every file in the take. Returns the files written, and anything
    /// that went wrong along the way.
    public func stopRecording() async -> FinishedRecording {
        guard let t = take else { return FinishedRecording(urls: [], problems: ["Not recording."]) }
        take = nil
        updateActivity()
        sinks.remove(t.outputs.compactMap(\.recorder))
        // Let frames and audio already handed out reach every file, so they
        // all end on the same frame and sample.
        await compositor.flush()
        await mixer.flush()
        var results = [Recorder.Result](repeating: Recorder.Result(), count: t.recorders.count)
        await withTaskGroup(of: (Int, Recorder.Result).self) { group in
            for (i, r) in t.recorders.enumerated() { group.addTask { (i, await r.finish()) } }
            for await (i, result) in group { results[i] = result }
        }
        return FinishedRecording(urls: results.compactMap(\.url), problems: results.compactMap(\.problem))
    }

    private func makeRecorder(_ t: Take, output index: Int) throws -> Recorder {
        let output = t.outputs[index]
        let name = output.part == 1 ? output.name : "\(output.name) (part \(output.part))"
        let url = t.directory.appending(path: "\(name).\(t.settings.container.rawValue)")
        let takeID = t.id, part = output.part
        return try Recorder(url: url, recording: t.settings, output: output.settings, canvas: t.canvas,
                            timecode: t.timecode) { [weak self] message in
            Task { @MainActor in self?.recorderFailed(take: takeID, output: index, part: part, message) }
        }
    }

    /// A file stopped being written partway (e.g. the encoder was reset or
    /// the disk hiccuped). Everything up to then is kept; carry on in a new
    /// part so a long take loses a moment instead of the rest of the take.
    /// The parts share the take's time-of-day timecode, so they still line up.
    private func recorderFailed(take id: UUID, output index: Int, part: Int, _ message: String) {
        guard var t = take, t.id == id, t.outputs[index].part == part, let failed = t.outputs[index].recorder else { return }
        sinks.remove(failed)
        let file = failed.url.lastPathComponent
        var output = t.outputs[index]
        output.quickFailures = hostNow() - output.partStarted < 10 ? output.quickFailures + 1 : 0
        output.recorder = nil
        output.part += 1
        output.partStarted = hostNow()
        t.outputs[index] = output
        defer { take = t }

        // Failing again straight away (disk full, folder gone) won't fix itself.
        guard output.quickFailures < 3 else {
            onRecordingIssue?("Stopped recording \(file): \(message). What was recorded is saved.")
            return
        }
        do {
            let r = try makeRecorder(t, output: index)
            t.outputs[index].recorder = r
            t.recorders.append(r)
            sinks.add(r, sceneID: output.settings.sceneID)
            onRecordingIssue?("\(file) hit an error (\(message)). Recording continues in part \(output.part); everything before the error is saved.")
        } catch {
            onRecordingIssue?("Stopped recording \(file): \(message). What was recorded is saved. Could not start a new part: \(error.localizedDescription)")
        }
    }

    // MARK: Power

    private var activity: NSObjectProtocol?

    /// While recording or streaming, keep the Mac and its displays awake
    /// (a sleeping display captures as black) and opt out of App Nap, which
    /// would throttle capture and encoding when Parallax is in the background.
    private func updateActivity() {
        let busy = take != nil || uplink != nil
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

/// The files a take left on disk, and anything that went wrong along the way.
public struct FinishedRecording: Sendable {
    public var urls: [URL]
    public var problems: [String]
}

extension VideoSourceKind {
    public var isScreen: Bool {
        switch self {
        case .display, .window: true
        default: false
        }
    }
}
