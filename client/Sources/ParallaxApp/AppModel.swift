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
    let deploy = DeployModel()
    var selectedItemID: UUID?
    var levels: [UUID: AudioLevel] = [:]
    var masterLevel = AudioLevel.silent
    var recordingStartedAt: Date?
    /// Sending video to the server; nil when not streaming.
    var uplinkState: UplinkState?
    var lastRecordingURL: URL?
    var sourceErrors: [UUID: String] = [:]
    var banner: String?
    var monitorError: String?
    /// A permission the user needs to grant; drives the permission sheet.
    var permissionPrompt: Permission? {
        didSet { if let permissionPrompt { shownPermission = permissionPrompt } }
    }
    @ObservationIgnored private var isRelaunching = false
    /// Permissions the user said "Not Now" to; not prompted again until they ask.
    @ObservationIgnored private var snoozedPermissions: Set<Permission> = []

    @ObservationIgnored let engine = MediaEngine()
    /// Set by the window so layout edits land in Edit › Undo.
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var lastUndo: (key: String, time: Date)?
    @ObservationIgnored private let store = ProfileStore()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var uplinkGeneration = 0

    init() {
        let firstRun = !FileManager.default.fileExists(atPath: store.url.path)
        profile = store.load()
        engine.onLevels = { [weak self] levels in
            self?.levels = levels.inputs
            self?.masterLevel = levels.master
        }
        engine.onSourceIssue = { [weak self] id, issue in
            guard let self else { return }
            switch issue {
            case .permissionDenied(let permission, let askedJustNow):
                // A source can fail for a moment around a grant; don't nag if access is there now.
                if permission.status == .granted {
                    permissionGranted(permission)
                    return
                }
                sourceErrors[id] = "\(permission.title) access is off. Click to fix."
                if askedJustNow {
                    // The user just answered macOS's own prompt; don't pile on.
                    snoozedPermissions.insert(permission)
                } else if permission == .screenRecording, !Permission.hasRequestedScreenRecording {
                    // First time: let macOS show its prompt (it has its own
                    // Open System Settings button) instead of ours.
                    snoozedPermissions.insert(permission)
                    Task { await permission.request() }
                } else if permissionPrompt == nil, !snoozedPermissions.contains(permission) {
                    permissionPrompt = permission
                }
            case .failed(let message):
                sourceErrors[id] = message
                banner = message
            case .waiting(let message):
                // Not an error: the source reconnects by itself. Show it on
                // the source's row only.
                sourceErrors[id] = message
            case .recovered:
                sourceErrors[id] = nil
            }
        }
        broadcast.onChatChanged = { [weak self] in self?.refreshChatOverlay() }
        deploy.onUse = { [weak self] url, token in self?.useServer(url: url, token: token) }
        deploy.onDestroyed = { [weak self] url in self?.forgetServer(url: url) }
        // Save identities that sources re-found (renumbered display, replugged
        // camera) so the next launch goes straight to the right device.
        engine.onVideoSourceResolved = { [weak self] id, kind in
            guard let self, let i = profile.videoSources.firstIndex(where: { $0.id == id }) else { return }
            profile.videoSources[i].kind = kind
        }
        engine.onAudioSourceResolved = { [weak self] id, kind in
            guard let self, let i = profile.audioSources.firstIndex(where: { $0.id == id }) else { return }
            profile.audioSources[i].kind = kind
        }
        engine.onMonitorStateChanged = { [weak self] in self?.monitorError = self?.engine.monitorError }
        // Follow device changes: a plugged-in headset, a new system default.
        devices.onOutputsChanged = { [weak self] in
            guard let self, profile.monitor.output != .off else { return }
            engine.restartMonitor()
        }
        if firstRun { addDefaultDevices() }
        engine.apply(profile)
        engine.setProgram(profile.programSceneID, transition: TransitionSettings(kind: .cut))
        broadcast.connect(profile.broadcast)
        #if DEBUG
        // Lets screenshots show selection chrome without driving the mouse.
        if ProcessInfo.processInfo.environment["PARALLAX_DEBUG_SELECT_TOP"] != nil {
            selectedItemID = programScene?.items.last?.id
        }
        // Repeatedly switches the canvas between 1080p and 4K, which restarts
        // cameras; used to reproduce restart races.
        if let flips = ProcessInfo.processInfo.environment["PARALLAX_DEBUG_CANVAS_FLIPS"].flatMap(Int.init) {
            Task { [weak self] in
                for i in 0..<flips {
                    try? await Task.sleep(for: .milliseconds(1500))
                    // Width then height as separate edits, like the old Canvas picker did.
                    let target = i % 2 == 0 ? (3840, 2160) : (1920, 1080)
                    self?.profile.output.width = target.0
                    self?.profile.output.height = target.1
                }
            }
        }
        if let raw = ProcessInfo.processInfo.environment["PARALLAX_DEBUG_PERMISSION"] {
            permissionPrompt = Permission(rawValue: raw)
        }
        #endif
    }

    private func addDefaultDevices() {
        if let mic = AVCaptureDevice.default(for: .audio) {
            addAudioSource(kind: .device(uniqueID: mic.uniqueID, name: mic.localizedName, modelID: mic.modelID), name: mic.localizedName)
        }
        if let camera = AVCaptureDevice.default(for: .video) {
            addVideoSource(kind: .camera(uniqueID: camera.uniqueID, name: camera.localizedName, modelID: camera.modelID),
                           name: camera.localizedName)
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

    // MARK: Undo

    /// Runs `body` as one undoable step. Repeated calls with the same `key`
    /// within a second (slider drags, preview drags) coalesce into one step.
    func edit(_ name: String, key: String? = nil, _ body: () -> Void) {
        let before = profile
        body()
        guard profile != before else { return }
        let now = Date()
        if let key, let last = lastUndo, last.key == key, now.timeIntervalSince(last.time) < 1 {
            lastUndo = (key, now)
            return
        }
        lastUndo = key.map { ($0, now) }
        registerUndo(name, restoring: before)
    }

    private func registerUndo(_ name: String, restoring snapshot: Profile) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            let current = model.profile
            model.restore(snapshot)
            model.registerUndo(name, restoring: current)
        }
        undoManager.setActionName(name)
    }

    /// Restores layout and settings but stays on the scene that's live now,
    /// so undo never cuts the program to a different scene.
    private func restore(_ snapshot: Profile) {
        lastUndo = nil
        let live = profile.programSceneID
        var next = snapshot
        if next.scene(live) != nil { next.programSceneID = live }
        profile = next
        if next.programSceneID != live { engine.setProgram(next.programSceneID, transition: profile.transition) }
        if selectedItem == nil { selectedItemID = nil }
    }

    // MARK: Scenes

    var programScene: StudioScene? { profile.scene(profile.programSceneID) }

    func selectScene(_ id: UUID) {
        guard id != profile.programSceneID else { return }
        profile.programSceneID = id
        selectedItemID = nil
        engine.setProgram(id, transition: profile.transition)
    }

    func addScene(_ template: SceneTemplate = .blank) {
        edit("New Scene") {
            let camera = template.needsCamera ? cameraSourceID() : nil
            let screen = template.needsScreen ? screenSourceID() : nil
            var scene = StudioScene(name: template == .blank ? uniqueSceneName("Scene") : uniqueSceneName(template.title))
            scene.items = template.items(camera: camera, screen: screen)
            profile.scenes.append(scene)
            selectScene(scene.id)
        }
    }

    private func uniqueSceneName(_ base: String) -> String {
        let names = Set(profile.scenes.map(\.name))
        if !names.contains(base) { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !names.contains($0) }!
    }

    /// The camera already used in the profile, else the system default.
    private func cameraSourceID() -> UUID? {
        if let existing = profile.videoSources.first(where: { if case .camera = $0.kind { true } else { false } }) {
            return existing.id
        }
        guard let device = AVCaptureDevice.default(for: .video) else { return nil }
        let source = VideoSource(name: device.localizedName,
                                 kind: .camera(uniqueID: device.uniqueID, name: device.localizedName, modelID: device.modelID))
        profile.videoSources.append(source)
        return source.id
    }

    /// The display already used in the profile, else the main display.
    private func screenSourceID() -> UUID? {
        if let existing = profile.videoSources.first(where: { if case .display = $0.kind { true } else { false } }) {
            return existing.id
        }
        let main = devices.displays.first { $0.id == CGMainDisplayID() }
        let source = VideoSource(name: main?.name ?? NSScreen.main?.localizedName ?? "Display",
                                 kind: main?.kind ?? .display(displayID: CGMainDisplayID()))
        profile.videoSources.append(source)
        return source.id
    }

    func duplicateScene(_ id: UUID) {
        guard let index = profile.scenes.firstIndex(where: { $0.id == id }) else { return }
        edit("Duplicate Scene") {
            var copy = profile.scenes[index]
            copy.id = UUID()
            copy.name = uniqueSceneName(copy.name + " Copy")
            copy.items = copy.items.map { var item = $0; item.id = UUID(); return item }
            profile.scenes.insert(copy, at: index + 1)
        }
    }

    func deleteScene(_ id: UUID) {
        guard profile.scenes.count > 1, let index = profile.scenes.firstIndex(where: { $0.id == id }) else { return }
        edit("Delete Scene") {
            if profile.programSceneID == id {
                selectScene(profile.scenes[index == 0 ? 1 : index - 1].id)
            }
            profile.scenes.remove(at: index)
            pruneUnusedVideoSources()
        }
    }

    func renameScene(_ id: UUID, to name: String) {
        edit("Rename Scene") { updateScene(id) { $0.name = name } }
    }

    func moveScenes(from: IndexSet, to: Int) {
        edit("Reorder Scenes") { profile.scenes.move(fromOffsets: from, toOffset: to) }
    }

    private func updateScene(_ id: UUID?, _ body: (inout StudioScene) -> Void) {
        guard let index = profile.scenes.firstIndex(where: { $0.id == id }) else { return }
        body(&profile.scenes[index])
    }

    // MARK: Scene items

    var selectedItem: SceneItem? { programScene?.items.first { $0.id == selectedItemID } }

    func addVideoSource(kind: VideoSourceKind, name: String) {
        edit("Add Source") { addVideoSourceWithoutUndo(kind: kind, name: name) }
    }

    private func addVideoSourceWithoutUndo(kind: VideoSourceKind, name: String) {
        let source: VideoSource
        // Same physical device (or same overlay kind) reuses the existing source.
        let reusable = { (existing: VideoSource) -> Bool in
            if let key = kind.deviceKey { return existing.kind.deviceKey == key }
            return existing.kind == kind && !kind.allowsDuplicates
        }
        if let existing = profile.videoSources.first(where: reusable) {
            source = existing
        } else {
            source = VideoSource(name: name, kind: kind)
            profile.videoSources.append(source)
        }
        insertItem(for: source.id)
    }

    func addExistingSource(_ sourceID: UUID) {
        edit("Add Source") { insertItem(for: sourceID) }
    }

    private func insertItem(for sourceID: UUID) {
        guard let source = profile.videoSource(sourceID) else { return }
        let isEmpty = programScene?.items.isEmpty ?? true
        var item = SceneItem(sourceID: sourceID)
        switch source.kind {
        case .camera:
            item.contentMode = .fill
            if !isEmpty {
                item.frame = LayoutPreset.pipTopRight.rect
                item.cornerRadius = 0.08
            }
        case .color: item.contentMode = .stretch
        case .chatFeed: item.frame = ChatPlacement.right.rect
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

    /// Edits an item in the live scene. Rapid edits under the same `undo`
    /// name coalesce, so a whole drag is one undo step.
    func updateItem(_ id: UUID, undo name: String = "Edit Source", _ body: (inout SceneItem) -> Void) {
        edit(name, key: "\(name)-\(id)") {
            updateScene(profile.programSceneID) { scene in
                guard let i = scene.items.firstIndex(where: { $0.id == id }) else { return }
                body(&scene.items[i])
            }
        }
    }

    func removeItem(_ id: UUID) {
        edit("Remove Source") {
            updateScene(profile.programSceneID) { $0.items.removeAll { $0.id == id } }
            if selectedItemID == id { selectedItemID = nil }
            pruneUnusedVideoSources()
        }
    }

    /// Moves an item toward the top (+1) or bottom (-1) of the stack.
    func moveItem(_ id: UUID, by offset: Int) {
        edit("Reorder Sources") {
            updateScene(profile.programSceneID) { scene in
                guard let i = scene.items.firstIndex(where: { $0.id == id }) else { return }
                let j = min(max(0, i + offset), scene.items.count - 1)
                scene.items.swapAt(i, j)
            }
        }
    }

    /// Reorders using offsets in the sources list, which shows the top item first.
    func moveItemsInList(from: IndexSet, to: Int) {
        edit("Reorder Sources") {
            updateScene(profile.programSceneID) { scene in
                var listed = Array(scene.items.reversed())
                listed.move(fromOffsets: from, toOffset: to)
                scene.items = listed.reversed()
            }
        }
    }

    /// Points an item at a different source (e.g. another display) while
    /// keeping its layout and style.
    func replaceSource(of itemID: UUID, with kind: VideoSourceKind, name: String) {
        edit("Change Source") {
            let sourceID: UUID
            if let existing = profile.videoSources.first(where: { $0.kind.deviceKey != nil && $0.kind.deviceKey == kind.deviceKey }) {
                sourceID = existing.id
            } else {
                let source = VideoSource(name: name, kind: kind)
                profile.videoSources.append(source)
                sourceID = source.id
            }
            updateScene(profile.programSceneID) { scene in
                guard let i = scene.items.firstIndex(where: { $0.id == itemID }) else { return }
                scene.items[i].sourceID = sourceID
            }
            pruneUnusedVideoSources()
        }
    }

    /// Crops in place: the kept part of the image stays where it is and the
    /// box resizes around it.
    func setCrop(_ id: UUID, _ edge: WritableKeyPath<CropInsets, Double>, to value: Double) {
        guard let item = programScene?.items.first(where: { $0.id == id }) else { return }
        var crop = item.crop
        crop[keyPath: edge] = value
        let canvas = CGSize(width: profile.output.width, height: profile.output.height)
        let updated = engine.sourceSize(item.sourceID).map { item.withCrop(crop, sourceSize: $0, canvas: canvas) }
        updateItem(id, undo: "Crop Source") { current in
            if let updated {
                current.crop = updated.crop
                current.frame = updated.frame
            } else {
                current.crop = crop
            }
        }
    }

    func nudgeSelected(dx: Double, dy: Double) {
        guard let id = selectedItemID else { return }
        updateItem(id, undo: "Move Source") { item in
            item.frame.x += dx
            item.frame.y += dy
            item.frame = item.frame.clamped()
        }
    }

    func updateVideoSource(_ id: UUID, _ body: (inout VideoSource) -> Void) {
        guard let i = profile.videoSources.firstIndex(where: { $0.id == id }) else { return }
        edit("Edit Source", key: "source-\(id)") { body(&profile.videoSources[i]) }
    }

    /// Sources not placed in any scene stop capturing.
    private func pruneUnusedVideoSources() {
        let used = Set(profile.scenes.flatMap { $0.items.map(\.sourceID) })
        profile.videoSources.removeAll { !used.contains($0.id) }
        sourceErrors = sourceErrors.filter { id, _ in used.contains(id) || profile.audioSources.contains { $0.id == id } }
    }

    // MARK: Audio

    func addAudioSource(kind: AudioSourceKind, name: String) {
        guard !profile.audioSources.contains(where: { $0.kind.deviceKey == kind.deviceKey }) else { return }
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

    // MARK: Permissions

    /// Called once macOS reports the permission granted: restart the captures
    /// that failed without it.
    @ObservationIgnored private var shownPermission: Permission?

    /// However the sheet closed (Not Now, Esc, granted), don't reopen it on
    /// its own this session unless access is still missing and the user asks.
    func permissionSheetDismissed() {
        if let shown = shownPermission, shown.status != .granted { snoozedPermissions.insert(shown) }
        shownPermission = nil
    }

    /// Opens the permission sheet on request (e.g. from a source's warning icon).
    func showPermission(_ permission: Permission) {
        snoozedPermissions.remove(permission)
        if permission.status == .granted {
            permissionGranted(permission)
        } else {
            permissionPrompt = permission
        }
    }

    func permissionGranted(_ permission: Permission) {
        snoozedPermissions.remove(permission)
        let affected = Set(profile.videoSources.filter { $0.kind.permission == permission }.map(\.id)
            + profile.audioSources.filter { $0.kind.permission == permission }.map(\.id))
        sourceErrors = sourceErrors.filter { !affected.contains($0.key) }
        engine.restartSources(needing: permission)
        if permissionPrompt == permission { permissionPrompt = nil }
    }

    /// Screen recording access only applies to a new process, so offer to
    /// relaunch. Any recording in progress is finished first.
    func relaunch() {
        guard !isRelaunching else { return }
        isRelaunching = true
        saveNow()
        // An open sheet makes AppKit refuse to terminate, which would leave
        // this copy running next to the new one.
        permissionPrompt = nil
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        let url = Bundle.main.bundleURL
        Task {
            await stopRecording()
            saveNow()
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            NSApp.terminate(nil)
            // Backstop in case something still vetoes termination.
            try? await Task.sleep(for: .seconds(2))
            exit(0)
        }
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

    // MARK: Broadcasting

    /// Starts sending video to the server, then asks it to go live on
    /// `destinationIDs`. The mock server only pretends, so nothing is sent.
    func goLive(_ destinationIDs: [String]) async {
        if broadcast.service.mode == .server {
            guard await startUplink() else { return }
        }
        let settings = profile.broadcast
        let request = StartBroadcastRequest(destinationIDs: destinationIDs,
                                            title: settings.title.trimmingCharacters(in: .whitespaces),
                                            privacy: settings.privacy.rawValue)
        if await !broadcast.start(request) {
            stopUplink()
        }
    }

    func endBroadcast() async {
        await broadcast.stop()
        stopUplink()
    }

    /// For when the server is live but this app isn't sending (e.g. it was
    /// restarted mid-broadcast).
    @discardableResult
    func startUplink() async -> Bool {
        guard let info = await broadcast.ingest() else { return false }
        guard let url = URL(string: info.srtURL) else {
            broadcast.connectionError = "The server sent a bad video address: \(info.srtURL)"
            return false
        }
        uplinkGeneration += 1
        let generation = uplinkGeneration
        uplinkState = .connecting
        engine.startStreaming(to: url, settings: profile.broadcast.stream) { [weak self] state in
            Task { @MainActor in
                guard let self, self.uplinkGeneration == generation, self.uplinkState != nil else { return }
                self.uplinkState = state
            }
        }
        return true
    }

    /// Points the app at a server (the token goes in the Keychain) and reconnects.
    func useServer(url: URL, token: String) {
        Keychain.write(token, for: "server-token")
        profile.broadcast.serverURL = url.absoluteString
        broadcast.connect(profile.broadcast)
    }

    /// Goes offline if `url` is the server in use (it was destroyed).
    func forgetServer(url: URL) {
        guard profile.broadcast.serverURL == url.absoluteString else { return }
        Keychain.write(nil, for: "server-token")
        profile.broadcast.serverURL = ""
        broadcast.connect(profile.broadcast)
    }

    func stopUplink() {
        uplinkGeneration += 1
        uplinkState = nil
        engine.stopStreaming()
    }

    // MARK: Chat

    func refreshChatOverlay() {
        let feed = broadcast.messages.suffix(8).map(overlayLine)
        let featured = broadcast.featuredMessage.map(overlayLine)
        engine.updateChat(feed: Array(feed), featured: featured)
    }

    /// The live scene's item showing `kind` (the chat feed or featured comment), if any.
    func chatItem(_ kind: VideoSourceKind) -> SceneItem? {
        programScene?.items.last { profile.videoSource($0.sourceID)?.kind == kind }
    }

    func isOnScreen(_ kind: VideoSourceKind) -> Bool { chatItem(kind)?.isVisible ?? false }

    /// Shows or hides chat on the stream. Hiding keeps the item, so turning
    /// it back on puts it where it was.
    func setOnScreen(_ kind: VideoSourceKind, _ on: Bool) {
        if let item = chatItem(kind) {
            updateItem(item.id, undo: on ? "Show Chat" : "Hide Chat") { $0.isVisible = on }
            selectedItemID = on ? item.id : (selectedItemID == item.id ? nil : selectedItemID)
        } else if on {
            addVideoSource(kind: kind, name: kind == .chatFeed ? "Chat Feed" : "Featured Comment")
        }
    }

    /// Moves the chat feed to a preset spot, adding it first if needed.
    func placeChat(_ placement: ChatPlacement) {
        edit("Place Chat") {
            if chatItem(.chatFeed) == nil { addVideoSourceWithoutUndo(kind: .chatFeed, name: "Chat Feed") }
            guard let id = chatItem(.chatFeed)?.id else { return }
            updateScene(profile.programSceneID) { scene in
                guard let i = scene.items.firstIndex(where: { $0.id == id }) else { return }
                scene.items[i].frame = placement.rect
                scene.items[i].isVisible = true
            }
            selectedItemID = id
        }
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
