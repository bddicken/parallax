import AppKit
import ParallaxCore
import SwiftUI

/// What the bottom of the left sidebar shows.
enum SidebarTab: String {
    case sources, music
}

struct SourcesOrMusicPanel: View {
    @AppStorage("sidebarTab") private var tab = SidebarTab.sources

    var body: some View {
        switch tab {
        case .sources: SourcesPanel()
        case .music: MusicPanel()
        }
    }
}

/// Header for the sidebar's Sources and Music panels, with a switch between them.
struct SidebarHeader<Accessory: View>: View {
    @AppStorage("sidebarTab") private var tab = SidebarTab.sources
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Picker("Show", selection: $tab) {
                Text("Sources").tag(SidebarTab.sources)
                Text("Music").tag(SidebarTab.music)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Music panel

struct MusicPanel: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<UUID>()
    @State private var search = ""
    @State private var removing: Set<UUID>?
    @State private var showingOptions = false
    @State private var dropTargeted = false

    var body: some View {
        let music = model.music
        VStack(spacing: 0) {
            SidebarHeader {
                Button { showingOptions.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless)
                    .help("Music options")
                    .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
                        MusicOptions().frame(width: 320)
                    }
                Menu {
                    Button("Open Suno") { music.openSuno() }
                    Button("Add Files…") { music.chooseFilesToImport() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add songs")
            }
            NowPlayingCard()
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            Divider()
            if music.library.tracks.isEmpty && music.importing.isEmpty {
                ContentUnavailableView {
                    Label("No Songs", systemImage: "music.note.list")
                } description: {
                    Text("Download songs from Suno right here in Parallax, or drag audio files in.")
                } actions: {
                    Button("Open Suno") { music.openSuno() }
                    Button("Add Files…") { music.chooseFilesToImport() }
                }
                .frame(maxHeight: .infinity)
            } else {
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                List(selection: $selection) {
                    ForEach(filteredTracks) { track in
                        TrackRow(track: track).tag(track.id)
                    }
                    // Reordering a filtered list would be confusing.
                    .onMove(perform: search.isEmpty ? { music.moveTracks(from: $0, to: $1) } : nil)
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    menu(for: ids)
                } primaryAction: { ids in
                    if let id = ids.first { music.play(id) }
                }
                .onDeleteCommand { if !selection.isEmpty { removing = selection } }
                if let note = footnote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            music.importFiles(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).padding(4)
            }
        }
        .confirmationDialog(removeTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { ids in
            Button("Move to Trash", role: .destructive) {
                music.remove(ids)
                selection.subtract(ids)
            }
        } message: { _ in
            Text("The song files go to the Trash. Suno doesn't count downloading a song again against your limit.")
        }
    }

    private var filteredTracks: [Song] {
        let tracks = model.music.library.tracks
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return tracks }
        return tracks.filter { $0.title.localizedCaseInsensitiveContains(query) || ($0.artist?.localizedCaseInsensitiveContains(query) ?? false) }
    }

    private var footnote: String? {
        let music = model.music
        if let name = music.importing.first {
            return music.importing.count > 1 ? "Adding \(music.importing.count) songs…" : "Adding \(name)…"
        }
        if let status = music.status { return status }
        let count = music.library.tracks.count
        return "\(count) \(count == 1 ? "song" : "songs")"
    }

    private var removeTitle: String {
        let count = removing?.count ?? 0
        if count == 1, let id = removing?.first, let track = model.music.library.track(id) {
            return "Remove “\(track.title)” from your music?"
        }
        return "Remove \(count) songs from your music?"
    }

    @ViewBuilder
    private func menu(for ids: Set<UUID>) -> some View {
        let music = model.music
        let tracks = music.library.tracks.filter { ids.contains($0.id) }
        if !tracks.isEmpty {
            Button("Play") { music.play(tracks[0].id) }
            Button("Play Next") {
                for track in tracks.reversed() { music.playAfterCurrent(track.id) }
            }
            Divider()
            let allExcluded = tracks.allSatisfy(\.isExcluded)
            Button(allExcluded ? "Include in Shuffle" : "Never Play in Shuffle") {
                music.setExcluded(!allExcluded, for: ids)
            }
            if tracks.count == 1, let page = tracks[0].sourceURL.flatMap(URL.init(string:)) {
                Button("Open on Suno") { music.openSuno(page) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(tracks.map(music.fileURL))
            }
            Divider()
            Button("Remove from Music…", role: .destructive) { removing = ids }
        }
    }
}

private struct NowPlayingCard: View {
    @Environment(AppModel.self) private var model
    /// Where the seek bar is being dragged to.
    @State private var scrub: Double?

    var body: some View {
        let music = model.music
        let track = music.nowPlaying
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(track?.title ?? (music.library.tracks.isEmpty ? "No songs yet" : "Not playing"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(track == nil ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button { music.setShuffle(!music.library.shuffle) } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(music.library.shuffle ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(music.library.shuffle ? "Shuffle is on" : "Shuffle is off (plays in list order)")
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let duration = max(track?.duration ?? 0, 1)
                let position = min(scrub ?? (track == nil ? 0 : music.position), duration)
                HStack(spacing: 6) {
                    Text(formatTime(position))
                        .frame(width: 34, alignment: .leading)
                    Slider(value: Binding(get: { position }, set: { scrub = $0 }), in: 0...duration) { editing in
                        guard !editing, let target = scrub else { return }
                        music.seek(to: target)
                        // Hold the thumb in place until the player gets there.
                        Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            if scrub == target { scrub = nil }
                        }
                    }
                    .controlSize(.mini)
                    .disabled(track == nil)
                    Text(formatTime(track?.duration ?? 0))
                        .frame(width: 34, alignment: .trailing)
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button(action: music.playPrevious) { Image(systemName: "backward.fill") }
                    .disabled(track == nil)
                    .help("Previous song (⌥⌘←)")
                Button(action: music.togglePlayPause) {
                    Image(systemName: music.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 26))
                }
                .disabled(music.library.tracks.isEmpty)
                .help(music.isPlaying ? "Pause (⌥⌘P)" : "Play (⌥⌘P)")
                Button(action: music.playNext) { Image(systemName: "forward.fill") }
                    .disabled(music.library.tracks.isEmpty)
                    .help("Next song (⌥⌘→)")
                Spacer(minLength: 8)
                MusicVolumeSlider().frame(minWidth: 60, maxWidth: 110)
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct TrackRow: View {
    @Environment(AppModel.self) private var model
    let track: Song
    @State private var editingVolume = false

    var body: some View {
        let music = model.music
        let isCurrent = music.nowPlayingID == track.id
        HStack(spacing: 6) {
            Group {
                if isCurrent {
                    Image(systemName: music.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .foregroundStyle(Color.accentColor)
                } else if track.isExcluded {
                    Image(systemName: "nosign").foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .frame(width: 16)
            Text(track.title)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(track.isExcluded ? .secondary : .primary)
                .lineLimit(1)
                .help(track.isExcluded ? "\(track.title) (never plays in shuffle)" : track.title)
            Spacer(minLength: 4)
            Button { editingVolume.toggle() } label: {
                if track.trimDB != 0 {
                    Text(String(format: "%+.0f dB", track.trimDB)).monospacedDigit()
                } else {
                    Image(systemName: "speaker.wave.1")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("This song's volume")
            .popover(isPresented: $editingVolume, arrowEdge: .trailing) {
                TrackVolumeEditor(track: track).padding().frame(width: 280)
            }
            Text(formatTime(track.duration))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// Turns one song up or down, remembered for next time.
private struct TrackVolumeEditor: View {
    @Environment(AppModel.self) private var model
    let track: Song

    var body: some View {
        let music = model.music
        let current = music.library.track(track.id) ?? track
        VStack(alignment: .leading, spacing: 8) {
            Text(current.title).font(.headline).lineLimit(1)
            HStack {
                Slider(value: Binding(get: { current.trimDB }, set: { music.setTrim($0, for: track.id) }),
                       in: MusicLibrary.trimRange, step: 1)
                Text(String(format: "%+.0f dB", current.trimDB))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(music.library.matchLoudness && current.loudness != nil
                     ? "On top of matching it to your other songs."
                     : "Applies every time this song plays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { music.setTrim(0, for: track.id) }
                    .disabled(current.trimDB == 0)
            }
        }
    }
}

private struct MusicOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let music = model.music
        Form {
            Section {
                Toggle("Match song loudness", isOn: Binding(get: { music.library.matchLoudness }, set: music.setMatchLoudness))
            } footer: {
                Text("Plays every song at about the same volume, so you rarely need to adjust one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let source = model.musicSource {
                Section("While you talk") { DuckingControls(source: source) }
            }
        }
        .formStyle(.grouped)
        // Ducking lives on the mixer's Music input.
        .onAppear { model.ensureMusicSource() }
    }
}

/// Turns an input down while you talk into a microphone.
struct DuckingControls: View {
    @Environment(AppModel.self) private var model
    let source: AudioSource

    var body: some View {
        Toggle("Lower while you talk", isOn: binding(\.duck.isEnabled))
            .help("Turns this down whenever a microphone picks up your voice")
        if source.duck.isEnabled {
            HStack {
                Slider(value: binding(\.duck.amountDB), in: DuckSettings.amountRange, step: 1)
                Text("\(Int(source.duck.amountDB)) dB").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<AudioSource, T>) -> Binding<T> {
        Binding(get: { source[keyPath: path] }, set: { v in model.updateAudioSource(source.id) { $0[keyPath: path] = v } })
    }
}

/// The Music input's fader: overall music volume.
struct MusicVolumeSlider: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { model.musicVolumeDB }, set: { model.setMusicVolume($0.rounded()) }),
                   in: AppModel.musicVolumeRange)
                .controlSize(.mini)
        }
        .help(String(format: "Music volume: %+.0f dB (⌥⌘↑ / ⌥⌘↓)", model.musicVolumeDB))
    }
}

/// Compact music controls for the bottom bar.
struct MusicMiniPlayer: View {
    /// Roomiest first; the bar picks the first that fits.
    enum Style: CaseIterable {
        case full, noTitle, buttonsOnly, hidden
    }

    @Environment(AppModel.self) private var model
    @AppStorage("sidebarTab") private var tab = SidebarTab.sources
    var style = Style.full

    var body: some View {
        let music = model.music
        HStack(spacing: 8) {
            if music.library.tracks.isEmpty {
                Button { tab = .music } label: { Label("Music", systemImage: "music.note") }
                    .help("Add songs from Suno")
            } else {
                Button(action: music.togglePlayPause) {
                    Image(systemName: music.isPlaying ? "pause.fill" : "play.fill").frame(width: 14)
                }
                .help(music.isPlaying ? "Pause music (⌥⌘P)" : "Play music (⌥⌘P)")
                Button(action: music.playNext) { Image(systemName: "forward.fill") }
                    .help("Next song (⌥⌘→)")
                if style == .full {
                    Button { tab = .music } label: {
                        Text(music.nowPlaying?.title ?? "Music")
                            .lineLimit(1)
                            .foregroundStyle(music.nowPlaying == nil ? .secondary : .primary)
                    }
                    .frame(maxWidth: 150, alignment: .leading)
                    .help("Show music")
                }
                if style == .full || style == .noTitle {
                    MusicVolumeSlider().frame(width: 80)
                }
            }
        }
        .buttonStyle(.borderless)
    }
}

struct MusicCommands: Commands {
    let model: AppModel

    var body: some Commands {
        let music = model.music
        let hasSongs = !music.library.tracks.isEmpty
        CommandMenu("Music") {
            Button(music.isPlaying ? "Pause" : "Play") { music.togglePlayPause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!hasSongs)
            Button("Next Song") { music.playNext() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!hasSongs)
            Button("Previous Song") { music.playPrevious() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(music.nowPlaying == nil)
            Toggle("Shuffle", isOn: Binding(get: { music.library.shuffle }, set: music.setShuffle))
            Divider()
            Button("Louder") { model.setMusicVolume(model.musicVolumeDB + 3) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Quieter") { model.setMusicVolume(model.musicVolumeDB - 3) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button("Open Suno") { music.openSuno() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Add Songs…") { music.chooseFilesToImport() }
        }
    }
}

/// "3:07"
func formatTime(_ seconds: Double) -> String {
    let total = Int(max(0, seconds).rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
}
