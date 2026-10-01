import AppKit
import Foundation
import Observation
import ParallaxCore
import ParallaxMedia
import UniformTypeIdentifiers

/// The music library and what's playing. Songs play through the Music input
/// in the mixer, whose fader is the overall music volume.
///
/// In Suno Player mode the same controls drive Suno's own web player in the
/// Suno window instead, whose sound reaches the mixer through the Suno Player
/// input.
@Observable
final class MusicModel {
    enum PlaybackState {
        case stopped, playing, paused
    }

    private(set) var library: MusicLibrary
    private(set) var state = PlaybackState.stopped
    private(set) var nowPlayingID: UUID?
    /// Names of files being added right now.
    private(set) var importing: [String] = []
    /// A short note about the last thing that happened, e.g. a song added.
    private(set) var status: String?
    /// Set by `AppModel` from the profile.
    var mode = MusicMode.library {
        didSet {
            guard mode != oldValue else { return }
            suno.mode = mode
            switch mode {
            case .library: if suno.isOpen { suno.perform(.pause) }
            case .sunoPlayer: stop()
            }
        }
    }
    /// What Suno's web player is doing, once the Suno window has loaded.
    private(set) var web: SunoPlayerScript.State?

    /// Makes sure the mixer has a Music input to play through.
    @ObservationIgnored var ensureOutput: () -> Void = {}
    @ObservationIgnored var onProblem: (String) -> Void = { _ in }
    @ObservationIgnored private(set) var queue = MusicQueue()
    @ObservationIgnored let store: MusicLibraryStore
    @ObservationIgnored private let player: SongPlayer
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// Songs that wouldn't play this session; left out of what plays next.
    @ObservationIgnored private var unplayable = Set<UUID>()
    @ObservationIgnored private lazy var suno: SunoBrowser = {
        let browser = SunoBrowser(incoming: store.incomingDirectory)
        browser.onDownload = { [weak self] file, page in
            self?.importFiles([file], sourceURL: page?.absoluteString, moveFiles: true)
        }
        browser.onProblem = { [weak self] in self?.onProblem($0) }
        browser.onPlayerState = { [weak self] in self?.web = $0 }
        browser.mode = mode
        return browser
    }()

    init(player: SongPlayer, directory: URL) {
        store = MusicLibraryStore(directory: directory)
        library = store.load()
        // Leftovers from downloads interrupted by a quit or crash.
        try? FileManager.default.removeItem(at: store.incomingDirectory)
        self.player = player
        player.onEvent = { [weak self] event in self?.handle(event) }
    }

    var nowPlaying: Song? { library.track(nowPlayingID) }

    // What the controls show, for either mode.
    var isPlaying: Bool { mode == .library ? state == .playing : web?.playing ?? false }
    var nowPlayingTitle: String? { mode == .library ? nowPlaying?.title : web?.title }
    var nowPlayingDuration: Double? { mode == .library ? nowPlaying?.duration : web?.duration }
    /// Whether play/next can do anything.
    var canPlay: Bool { mode == .sunoPlayer || !library.tracks.isEmpty }
    var canGoBack: Bool { mode == .sunoPlayer || nowPlaying != nil }
    /// Seconds into the current song. Not observable in Library mode; poll it.
    var position: Double { mode == .library ? player.position : web?.position ?? 0 }

    // MARK: Playback

    func play(_ id: UUID) {
        guard let track = library.track(id) else { return }
        unplayable.remove(id)
        ensureOutput()
        state = .playing
        player.play(item(for: track))
    }

    func togglePlayPause() {
        if mode == .sunoPlayer {
            guard suno.isOpen else { return openSuno() }
            return suno.perform(isPlaying ? .pause : .play)
        }
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .stopped: playNext()
        }
    }

    func pause() {
        guard state == .playing else { return }
        player.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        ensureOutput()
        player.resume()
        state = .playing
    }

    func stop() {
        state = .stopped
        nowPlayingID = nil
        player.stop()
    }

    func playNext() {
        if mode == .sunoPlayer { return suno.perform(.nexttrack) }
        if let id = nextSong(after: nowPlayingID) {
            play(id)
        } else {
            stop()
        }
    }

    /// Back to the start of the song, or to the one before if it just began.
    func playPrevious() {
        if mode == .sunoPlayer { return suno.perform(.previoustrack) }
        if position < 3, let id = queue.previous(before: nowPlayingID, in: library.tracks) {
            play(id)
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: Double) {
        if mode == .sunoPlayer { return suno.seek(to: seconds) }
        player.seek(to: seconds)
    }

    /// Plays `id` after the current song.
    func playAfterCurrent(_ id: UUID) {
        queue.upNext.removeAll { $0 == id }
        queue.upNext.insert(id, at: 0)
        refreshUpcoming()
    }

    private func nextSong(after id: UUID?) -> UUID? {
        queue.next(after: id, in: library.tracks.filter { !unplayable.contains($0.id) }, shuffle: library.shuffle)
    }

    func setShuffle(_ on: Bool) {
        library.shuffle = on
        libraryChanged()
    }

    private func handle(_ event: SongPlayer.Event) {
        switch event {
        case .started(let id):
            nowPlayingID = id
            queue.didStart(id)
            update(id) {
                $0.playCount += 1
                $0.lastPlayedAt = Date()
            }
        case .stopped:
            nowPlayingID = nil
            // The last song ended on its own; keep the music going.
            if state == .playing { playNext() }
        case .failed(let id, let message):
            onProblem("Couldn't play “\(library.track(id)?.title ?? "a song")”: \(message)")
            unplayable.insert(id)
            if let playing = player.currentID, playing != id {
                // It was lined up next; the current song plays on.
                refreshUpcoming()
            } else if state == .playing, let next = nextSong(after: id) {
                play(next)
            } else {
                stop()
            }
        }
    }

    /// Tells the player what follows the current song, so it starts with no gap.
    private func refreshUpcoming() {
        guard let current = player.currentID else { return }
        player.setUpcoming(nextSong(after: current).flatMap(library.track).map(item), after: current)
    }

    private func item(for track: Song) -> SongPlayer.Item {
        SongPlayer.Item(id: track.id, url: store.fileURL(for: track), gainDB: library.gainDB(for: track))
    }

    // MARK: Library

    func setTrim(_ db: Double, for id: UUID) {
        update(id) { $0.trimDB = min(max(db, MusicLibrary.trimRange.lowerBound), MusicLibrary.trimRange.upperBound) }
        if let track = library.track(id) { player.setGain(library.gainDB(for: track), for: id) }
    }

    func setMatchLoudness(_ on: Bool) {
        library.matchLoudness = on
        for track in library.tracks { player.setGain(library.gainDB(for: track), for: track.id) }
        libraryChanged()
    }

    /// Excluded songs never come up in shuffle or play on their own.
    func setExcluded(_ excluded: Bool, for ids: Set<UUID>) {
        for id in ids { update(id) { $0.isExcluded = excluded } }
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = trimmed }
    }

    func moveTracks(from: IndexSet, to: Int) {
        library.tracks.move(fromOffsets: from, toOffset: to)
        libraryChanged()
    }

    /// Takes songs out of the library and moves their files to the Trash.
    func remove(_ ids: Set<UUID>) {
        if let playing = nowPlayingID, ids.contains(playing) {
            let remaining = library.tracks.filter { !ids.contains($0.id) }
            if state == .playing,
               let next = queue.next(after: playing, in: remaining.filter { !unplayable.contains($0.id) }, shuffle: library.shuffle) {
                play(next)
            } else {
                stop()
            }
        }
        for track in library.tracks where ids.contains(track.id) {
            try? FileManager.default.trashItem(at: store.fileURL(for: track), resultingItemURL: nil)
            queue.remove(track.id)
        }
        library.tracks.removeAll { ids.contains($0.id) }
        libraryChanged()
    }

    func fileURL(for track: Song) -> URL { store.fileURL(for: track) }

    private func update(_ id: UUID, _ body: (inout Song) -> Void) {
        guard let i = library.tracks.firstIndex(where: { $0.id == id }) else { return }
        body(&library.tracks[i])
        libraryChanged()
    }

    private func libraryChanged() {
        refreshUpcoming()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do { try store.save(library) } catch { onProblem("Couldn't save your music library: \(error.localizedDescription)") }
    }

    private func showStatus(_ text: String) {
        status = text
        suno.showStatus(text)
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.status = nil
        }
    }

    // MARK: Adding songs

    /// Opens Suno in Parallax, at `page` if given.
    func openSuno(_ page: URL? = nil) {
        suno.show(page)
    }

    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.message = "Choose songs to add to your music."
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// Copies songs into the library (or moves them, for downloads), skipping
    /// ones that are already in it.
    func importFiles(_ urls: [URL], sourceURL: String? = nil, moveFiles: Bool = false) {
        Task {
            for url in urls { await importFile(url, sourceURL: sourceURL, moveFile: moveFiles) }
        }
    }

    private func importFile(_ url: URL, sourceURL: String?, moveFile: Bool) async {
        let name = url.lastPathComponent
        guard MusicImporter.isAudioFile(url) else {
            return onProblem("\(name) isn't a song Parallax can play. Add MP3, WAV, M4A, AIFF, or FLAC files.")
        }
        importing.append(name)
        defer {
            if let i = importing.firstIndex(of: name) { importing.remove(at: i) }
            // Downloads land in a folder of their own under Incoming.
            let folder = url.deletingLastPathComponent()
            if moveFile, folder.path.hasPrefix(store.incomingDirectory.path) { try? FileManager.default.removeItem(at: folder) }
        }
        do {
            let (hash, analysis) = try await Task.detached(priority: .userInitiated) {
                (try MusicImporter.contentHash(of: url), try await MusicImporter.analyze(url))
            }.value
            if let existing = library.tracks.first(where: { $0.contentHash == hash }) {
                if existing.sourceURL == nil, let page = sourceURL ?? analysis.sunoURL?.absoluteString {
                    update(existing.id) { $0.sourceURL = page }
                }
                return showStatus("“\(existing.title)” is already in your music.")
            }
            let id = UUID()
            let fileName = "\(id.uuidString).\(url.pathExtension.lowercased())"
            try FileManager.default.createDirectory(at: store.songsDirectory, withIntermediateDirectories: true)
            let destination = store.songsDirectory.appending(path: fileName)
            if moveFile {
                try FileManager.default.moveItem(at: url, to: destination)
            } else {
                try FileManager.default.copyItem(at: url, to: destination)
            }
            let track = Song(id: id, title: analysis.title ?? url.deletingPathExtension().lastPathComponent,
                                   artist: analysis.artist, fileName: fileName, duration: analysis.duration,
                                   loudness: analysis.loudness, sourceURL: sourceURL ?? analysis.sunoURL?.absoluteString,
                                   contentHash: hash)
            // Newest first, where you'll look for what you just downloaded.
            library.tracks.insert(track, at: 0)
            libraryChanged()
            showStatus("Added “\(track.title)” to your music.")
        } catch {
            onProblem("Couldn't add \(name): \(error.localizedDescription)")
        }
    }
}
