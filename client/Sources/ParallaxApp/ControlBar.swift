import AppKit
import ParallaxCore
import ParallaxRemote
import SwiftUI

struct ControlBar: View {
    @Environment(AppModel.self) private var model
    @State private var showingGoLive = false

    var body: some View {
        // The bar must never be wider than the column: that would stretch the
        // preview, inspector, and mixer above it past the column's edge. As
        // space runs out, the music controls shrink, then go (the Music tab
        // still has them).
        ViewThatFits(in: .horizontal) {
            ForEach(MusicMiniPlayer.Style.allCases, id: \.self) { bar(music: $0) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .sheet(isPresented: $showingGoLive) {
            GoLiveSheet().environment(model)
        }
    }

    private func bar(music: MusicMiniPlayer.Style) -> some View {
        HStack(spacing: 12) {
            Picker("Transition", selection: transitionBinding(\.kind)) {
                Text("Cut").tag(TransitionKind.cut)
                Text("Fade").tag(TransitionKind.fade)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            if model.profile.transition.kind == .fade {
                Stepper(value: transitionBinding(\.durationMs), in: 100...3000, step: 100) {
                    Text("\(model.profile.transition.durationMs) ms").monospacedDigit().fixedSize()
                }
            }

            Divider().frame(height: 20)
            // Music buttons matter more than the full headphone name.
            MonitorControl(maxLabelWidth: music == .full || music == .noTitle ? 170 : 100)
            if music != .hidden {
                Divider().frame(height: 20)
                MusicMiniPlayer(style: music)
            }

            Spacer()

            if let url = model.lastRecordingURLs.first, !model.isRecording {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(model.lastRecordingURLs)
                } label: {
                    Label(url.lastPathComponent, systemImage: "film")
                        .lineLimit(1)
                        .frame(maxWidth: 180)
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }

            Button(action: model.toggleRecording) {
                HStack(spacing: 6) {
                    Image(systemName: model.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(.red)
                    if let started = model.recordingStartedAt {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(Duration.seconds(context.date.timeIntervalSince(started)),
                                 format: .time(pattern: .hourMinuteSecond))
                                .monospacedDigit()
                        }
                    } else {
                        Text("Record")
                    }
                }
                .frame(minWidth: 90)
            }
            .controlSize(.large)
            .help(recordingSummary)

            Button { showingGoLive = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(model.broadcast.status.live ? .red : .secondary).frame(width: 8, height: 8)
                    Text(model.broadcast.status.live ? "Live" : "Go Live")
                }
                .frame(minWidth: 80)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(model.broadcast.status.live ? .red : .accentColor)

            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
        }
    }

    private var recordingSummary: String {
        let r = model.profile.recording, size = r.resolution.size(for: model.profile.output)
        let quality = switch r.quality {
        case .small: "HEVC, smaller files"
        case .balanced: "HEVC, balanced quality"
        case .high: "HEVC, high quality"
        case .custom: "\(r.codec == .hevc ? "HEVC" : "H.264") \(r.videoBitrateKbps / 1000) Mbps"
        }
        return "Records \(size.width)×\(size.height) \(model.profile.output.fps) fps, \(quality) (⇧⌘R)"
    }

    private func transitionBinding<T>(_ path: WritableKeyPath<TransitionSettings, T>) -> Binding<T> {
        Binding(get: { model.profile.transition[keyPath: path] }, set: { model.profile.transition[keyPath: path] = $0 })
    }
}

struct GoLiveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var broadcast: BroadcastModel { model.broadcast }

    /// While live, what's actually streaming; otherwise what you checked last
    /// time (or each destination's default).
    private var selected: Set<String> {
        if broadcast.status.live {
            return Set(broadcast.status.destinations.map(\.destinationID))
        }
        let available = broadcast.destinations
        guard let remembered = model.profile.broadcast.destinationIDs else {
            return Set(available.filter(\.enabled).map(\.id))
        }
        return Set(available.map(\.id)).intersection(remembered)
    }

    private func setSelected(_ id: String, _ on: Bool) {
        var ids = selected
        if on { ids.insert(id) } else { ids.remove(id) }
        model.profile.broadcast.destinationIDs = ids.sorted()
    }

    private var youTubeSelected: Bool {
        broadcast.destinations.contains { $0.platform == .youtube && selected.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(broadcast.status.live ? "You're live" : "Go Live").font(.title2.bold())
            let stream = model.profile.broadcast.stream, size = stream.resolution.size(for: model.profile.output)
            HStack {
                Text("Stream: \(String(size.width))×\(String(size.height)) · \(model.profile.output.fps) fps · \(String(format: "%.1f", Double(stream.videoBitrateKbps) / 1000)) Mbps")
                    .font(.callout).foregroundStyle(.secondary)
                SettingsLink { Text("Change…") }.buttonStyle(.link)
            }

            if case .offline(let reason?) = broadcast.connection {
                Label(reason, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if broadcast.service.mode == .offline {
                Label("No server is set up yet, so there's nowhere to stream to. Add one in Settings › Server, or turn on Mock in the chat panel to try Go Live.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if broadcast.service.isMock {
                Label("Using the built-in mock server, so nothing is actually streamed.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                UplinkRow()
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(broadcast.destinations) { dest in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { selected.contains(dest.id) },
                            set: { setSelected(dest.id, $0) }
                        )) {
                            HStack(spacing: 6) {
                                PlatformBadge(platform: dest.platform)
                                Text(dest.name)
                            }
                        }
                        .disabled(broadcast.status.live)
                        Spacer()
                        if let status = broadcast.status.destinations.first(where: { $0.destinationID == dest.id }) {
                            StatusPill(state: status.state, error: status.error)
                        }
                    }
                }
                if broadcast.destinations.isEmpty {
                    HStack {
                        Text(broadcast.connectionError ?? "No destinations yet. Connect Twitch in Settings › Server.")
                            .foregroundStyle(.secondary)
                        if broadcast.connectionError == nil {
                            SettingsLink { Text("Open…") }.buttonStyle(.link)
                        }
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            if youTubeSelected {
                YouTubeOptions()
            }

            if let error = broadcast.connectionError {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                if broadcast.status.live {
                    Button("End Broadcast", role: .destructive) { Task { await model.endBroadcast() } }
                        .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button("Start Broadcast") { Task { await model.goLive(Array(selected)) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty || broadcast.isBusy)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { await broadcast.refreshDestinations() }
    }
}

/// YouTube makes a new video for each broadcast, so it needs a title and
/// visibility, and can take a thumbnail. Remembered for next time.
private struct YouTubeOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let live = model.broadcast.status.live
        Grid(alignment: .leading, verticalSpacing: 8) {
            GridRow {
                Text("Title")
                TextField("Title", text: $model.profile.broadcast.title, prompt: Text("What's this stream about?"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .disabled(live)
            }
            GridRow {
                Text("YouTube")
                Picker("Visibility", selection: $model.profile.broadcast.privacy) {
                    ForEach(BroadcastPrivacy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(live)
            }
            GridRow {
                Text("Thumbnail")
                ThumbnailPicker()
            }
            if let problem = model.broadcast.thumbnailProblem {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
    }
}

/// Picks the image file for the YouTube thumbnail. It's uploaded when you go
/// live, or right away if you change it while live.
private struct ThumbnailPicker: View {
    @Environment(AppModel.self) private var model
    @State private var preview: NSImage?

    var body: some View {
        let path = model.profile.broadcast.thumbnailPath
        HStack(spacing: 8) {
            if let path {
                Group {
                    if let preview {
                        Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .help("Can't open \(path)")
                    }
                }
                .frame(width: 64, height: 36)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(URL(filePath: path).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                    .help(path)
                Button("Change…", action: choose)
                Button {
                    model.profile.broadcast.thumbnailPath = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Don't use a thumbnail")
            } else {
                Button("Choose…", action: choose)
                Text("JPEG or PNG, ideally 1280 × 720").foregroundStyle(.secondary)
            }
            if model.broadcast.isUploadingThumbnail {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: path) { preview = path.flatMap(NSImage.init(contentsOfFile:)) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .image]
        if let path = model.profile.broadcast.thumbnailPath {
            panel.directoryURL = URL(filePath: path).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.profile.broadcast.thumbnailPath = url.path
        if model.broadcast.isLive(on: .youtube) {
            Task { await model.broadcast.setThumbnail(contentsOf: url) }
        }
    }
}

/// Whether this Mac is sending video to the server.
private struct UplinkRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            switch model.uplinkState {
            case nil:
                if model.broadcast.status.live {
                    Label("Live on the server, but this Mac isn't sending video.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Send Video") { Task { await model.startUplink() } }
                } else {
                    Label("Video goes to the server once you start.", systemImage: "arrow.up.circle")
                        .foregroundStyle(.secondary)
                }
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting to the server…").foregroundStyle(.secondary)
            case .sending:
                Label(model.broadcast.status.ingestActive ? "Sending video to the server" : "Sending video…",
                      systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(.green)
            case .retrying(let reason):
                Label(reason, systemImage: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.orange)
                    .help("Parallax keeps retrying on its own.")
            }
        }
        .font(.callout)
    }
}

private struct StatusPill: View {
    let state: DestinationState
    let error: String?

    var body: some View {
        Text(state.rawValue.capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
            .help(error ?? "")
    }

    private var color: Color {
        switch state {
        case .idle: .secondary
        case .connecting: .orange
        case .live: .green
        case .error: .red
        }
    }
}
