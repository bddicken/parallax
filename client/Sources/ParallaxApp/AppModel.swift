import AppKit
import AVFoundation
import Foundation
import Observation
import ParallaxCore
import ParallaxMedia
import ParallaxRemote

/// The single source of truth for the UI. Every edit goes through `profile`,
/// which is pushed to the media engine and saved.
@Observable
final class AppModel {
    var profile: Profile {
        didSet {
            guard profile != oldValue else { return }
            engine.apply(profile)
            scheduleSave()
        }
    }

    let devices = DeviceCatalog()
    let broadcast = BroadcastModel()
    var selectedItemID: UUID?
    var levels: [UUID: AudioLevel] = [:]
    var masterLevel = AudioLevel.silent
    var recordingStartedAt: Date?
    var lastRecordingURL: URL?
    var sourceErrors: [UUID: String] = [:]
    var banner: String?

    @ObservationIgnored let engine = MediaEngine()
    @ObservationIgnored private let store = ProfileStore()
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        let firstRun = !FileManager.default.fileExists(atPath: store.url.path)
        profile = store.load()
        engine.onLevels = { [weak self] levels in
            self?.levels = levels.inputs
            self?.masterLevel = levels.master
        }
        engine.onSourceError = { [weak self] id, message in
            self?.sourceErrors[id] = message
            self?.banner = message
        }
        broadcast.onChatChanged = { [weak self] in self?.refreshChatOverlay() }
        if firstRun { addDefaultDevices() }
        engine.apply(profile)
        engine.setProgram(profile.programSceneID, transition: TransitionSettings(kind: .cut))
        broadcast.connect(profile.broadcast)
    }

    private func addDefaultDevices() {
        if let mic = AVCaptureDevice.default(for: .audio) {
            addAudioSource(kind: .device(uniqueID: mic.uniqueID), name: mic.localizedName)
        }
        if let camera = AVCaptureDevice.default(for: .video) {
            addVideoSource(kind: .camera(uniqueID: camera.uniqueID), name: camera.localizedName)
        }
        selectedItemID = nil
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            do { try store.save(profile) } catch { banner = "Couldn't save settings: \(error.localizedDescription)" }
        }
    }

    func saveNow() {
        saveTask?.cancel()
        try? store.save(profile)
    }

    // MARK: Scenes

    var programScene: StudioScene? { profile.scene(profile.programSceneID) }

    func selectScene(_ id: UUID) {
        guard id != profile.programSceneID else { return }
        profile.programSceneID = id
        selectedItemID = nil
        engine.setProgram(id, transition: profile.transition)
    }

    func addScene() {
        let scene = StudioScene(name: "Scene \(profile.scenes.count + 1)")
        profile.scenes.append(scene)
        selectScene(scene.id)
    }

    func duplicateScene(_ id: UUID) {
        guard let index = profile.scenes.firstIndex(where: { $0.id == id }) else { return }
        var copy = profile.scenes[index]
        copy.id = UUID()
        copy.name += " Copy"
        copy.items = copy.items.map { var item = $0; item.id = UUID(); return item }
        profile.scenes.insert(copy, at: index + 1)
    }

    func deleteScene(_ id: UUID) {
        guard profile.scenes.count > 1, let index = profile.scenes.firstIndex(where: { $0.id == id }) else { return }
        if profile.programSceneID == id {
            selectScene(profile.scenes[index == 0 ? 1 : index - 1].id)
        }
        profile.scenes.remove(at: index)
        pruneUnusedVideoSources()
    }

    func renameScene(_ id: UUID, to name: String) {
        updateScene(id) { $0.name = name }
    }

    func moveScenes(from: IndexSet, to: Int) {
        profile.scenes.move(fromOffsets: from, toOffset: to)
    }

    private func updateScene(_ id: UUID?, _ body: (inout StudioScene) -> Void) {
        guard let index = profile.scenes.firstIndex(where: { $0.id == id }) else { return }
        body(&profile.scenes[index])
    }

    // MARK: Scene items

    var selectedItem: SceneItem? { programScene?.items.first { $0.id == selectedItemID } }

    func addVideoSource(kind: VideoSourceKind, name: String) {
        let source: VideoSource
        if let existing = profile.videoSources.first(where: { $0.kind == kind && !kind.allowsDuplicates }) {
            source = existing
        } else {
            source = VideoSource(name: name, kind: kind)
            profile.videoSources.append(source)
        }
        addExistingSource(source.id)
    }

    func addExistingSource(_ sourceID: UUID) {
        guard let source = profile.videoSource(sourceID) else { return }
        let isEmpty = programScene?.items.isEmpty ?? true
        var item = SceneItem(sourceID: sourceID)
        switch source.kind {
        case .camera: item.frame = isEmpty ? .full : LayoutPreset.pipBottomRight.rect
        case .color: item.contentMode = .stretch
        case .chatFeed: item.frame = NormalizedRect(x: 0.72, y: 0.04, width: 0.26, height: 0.92)
        case .featuredChat: item.frame = NormalizedRect(x: 0.05, y: 0.74, width: 0.9, height: 0.2)
        default: break
        }
        updateScene(profile.programSceneID) { scene in
            if case .color = source.kind { scene.items.insert(item, at: 0) } else { scene.items.append(item) }
        }
        selectedItemID = item.id
        if case .chatFeed = source.kind { refreshChatOverlay() }
        if case .featuredChat = source.kind { refreshChatOverlay() }
    }

    func updateItem(_ id: UUID, _ body: (inout SceneItem) -> Void) {
        updateScene(profile.programSceneID) { scene in
            guard let i = scene.items.firstIndex(where: { $0.id == id }) else { return }
            body(&scene.items[i])
        }
    }

    func removeItem(_ id: UUID) {
        updateScene(profile.programSceneID) { $0.items.removeAll { $0.id == id } }
        if selectedItemID == id { selectedItemID = nil }
        pruneUnusedVideoSources()
    }

    /// Moves an item toward the top (+1) or bottom (-1) of the stack.
    func moveItem(_ id: UUID, by offset: Int) {
        updateScene(profile.programSceneID) { scene in
            guard let i = scene.items.firstIndex(where: { $0.id == id }) else { return }
            let j = min(max(0, i + offset), scene.items.count - 1)
            scene.items.swapAt(i, j)
        }
    }

    func updateVideoSource(_ id: UUID, _ body: (inout VideoSource) -> Void) {
        guard let i = profile.videoSources.firstIndex(where: { $0.id == id }) else { return }
        body(&profile.videoSources[i])
    }

    /// Sources not placed in any scene stop capturing.
    private func pruneUnusedVideoSources() {
        let used = Set(profile.scenes.flatMap { $0.items.map(\.sourceID) })
        profile.videoSources.removeAll { !used.contains($0.id) }
        sourceErrors = sourceErrors.filter { id, _ in used.contains(id) || profile.audioSources.contains { $0.id == id } }
    }

    // MARK: Audio

    func addAudioSource(kind: AudioSourceKind, name: String) {
        guard !profile.audioSources.contains(where: { $0.kind == kind }) else { return }
        profile.audioSources.append(AudioSource(name: name, kind: kind, channelMode: kind == .systemAudio ? .stereo : .mono))
    }

    func updateAudioSource(_ id: UUID, _ body: (inout AudioSource) -> Void) {
        guard let i = profile.audioSources.firstIndex(where: { $0.id == id }) else { return }
        body(&profile.audioSources[i])
    }

    func removeAudioSource(_ id: UUID) {
        profile.audioSources.removeAll { $0.id == id }
        sourceErrors[id] = nil
    }

    // MARK: Recording

    var isRecording: Bool { recordingStartedAt != nil }

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            do {
                _ = try engine.startRecording(profile.recording)
                recordingStartedAt = Date()
            } catch {
                banner = error.localizedDescription
            }
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        recordingStartedAt = nil
        do {
            lastRecordingURL = try await engine.stopRecording()
        } catch {
            banner = "Recording failed: \(error.localizedDescription)"
        }
    }

    // MARK: Chat

    func refreshChatOverlay() {
        let feed = broadcast.messages.suffix(8).map(overlayLine)
        let featured = broadcast.featuredMessage.map(overlayLine)
        engine.updateChat(feed: Array(feed), featured: featured)
    }

    private func overlayLine(_ message: ChatMessage) -> ChatOverlayLine {
        ChatOverlayLine(author: message.author.displayName, text: message.text, accent: message.platform.accent)
    }
}

extension VideoSourceKind {
    /// Kinds where adding twice creates a second source rather than reusing one.
    var allowsDuplicates: Bool {
        switch self {
        case .color, .image: true
        default: false
        }
    }
}
