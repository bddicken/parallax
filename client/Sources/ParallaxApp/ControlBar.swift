import AppKit
import ParallaxCore
import ParallaxRemote
import SwiftUI

struct ControlBar: View {
    @Environment(AppModel.self) private var model
    @State private var showingGoLive = false

    var body: some View {
        HStack(spacing: 14) {
            Picker("Transition", selection: transitionBinding(\.kind)) {
                Text("Cut").tag(TransitionKind.cut)
                Text("Fade").tag(TransitionKind.fade)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            if model.profile.transition.kind == .fade {
                Stepper(value: transitionBinding(\.durationMs), in: 100...3000, step: 100) {
                    Text("\(model.profile.transition.durationMs) ms").monospacedDigit()
                }
            }

            Divider().frame(height: 20)
            MonitorControl()

            Spacer()

            if let url = model.lastRecordingURL, !model.isRecording {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label(url.lastPathComponent, systemImage: "film")
                        .lineLimit(1)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .sheet(isPresented: $showingGoLive) {
            GoLiveSheet().environment(model)
        }
    }

    private var recordingSummary: String {
        let r = model.profile.recording, size = r.resolution.size(for: model.profile.output)
        return "Records \(size.width)×\(size.height) \(model.profile.output.fps) fps, \(r.codec == .hevc ? "HEVC" : "H.264") \(r.videoBitrateKbps / 1000) Mbps (⇧⌘R)"
    }

    private func transitionBinding<T>(_ path: WritableKeyPath<TransitionSettings, T>) -> Binding<T> {
        Binding(get: { model.profile.transition[keyPath: path] }, set: { model.profile.transition[keyPath: path] = $0 })
    }
}

struct GoLiveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    private var broadcast: BroadcastModel { model.broadcast }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(broadcast.status.live ? "You're live" : "Go Live").font(.title2.bold())
            let stream = model.profile.broadcast.stream, size = stream.resolution.size(for: model.profile.output)
            HStack {
                Text("Stream: \(String(size.width))×\(String(size.height)) · \(model.profile.output.fps) fps · \(String(format: "%.1f", Double(stream.videoBitrateKbps) / 1000)) Mbps")
                    .font(.callout).foregroundStyle(.secondary)
                SettingsLink { Text("Change…") }.buttonStyle(.link)
            }

            if broadcast.service.mode == .offline {
                Label("No server is set up yet, so there's nowhere to stream to. Add one in Settings › Server, or turn on Mock in the chat panel to try Go Live.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if broadcast.service.isMock {
                Label("Using the built-in mock server. Nothing is actually streamed until parallax-server and the uplink are built.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(broadcast.destinations) { dest in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { selected.contains(dest.id) },
                            set: { if $0 { selected.insert(dest.id) } else { selected.remove(dest.id) } }
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
                    Text(broadcast.connectionError ?? "No destinations configured on the server.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            if let error = broadcast.connectionError {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                if broadcast.status.live {
                    Button("End Broadcast", role: .destructive) { Task { await broadcast.stop() } }
                        .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button("Start Broadcast") { Task { await broadcast.start(Array(selected)) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty || broadcast.isBusy)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            await broadcast.refreshDestinations()
            selected = Set(broadcast.destinations.filter(\.enabled).map(\.id))
        }
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
