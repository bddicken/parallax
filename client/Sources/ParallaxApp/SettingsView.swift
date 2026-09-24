import AppKit
import ParallaxCore
import ParallaxRemote
import SwiftUI

struct SettingsView: View {
    @State private var tab = Self.initialTab

    var body: some View {
        TabView(selection: $tab) {
            CanvasSettingsView().tabItem { Label("Canvas", systemImage: "rectangle.on.rectangle") }.tag("canvas")
            RecordingSettingsView().tabItem { Label("Recording", systemImage: "record.circle") }.tag("recording")
            StreamingSettingsView().tabItem { Label("Streaming", systemImage: "antenna.radiowaves.left.and.right") }.tag("streaming")
            ServerSettingsView().tabItem { Label("Server", systemImage: "server.rack") }.tag("server")
        }
        .frame(width: 540)
        .padding(.vertical, 8)
    }
}

extension SettingsView {
    static var initialTab: String {
        #if DEBUG
        ProcessInfo.processInfo.environment["PARALLAX_DEBUG_SETTINGS_TAB"] ?? "canvas"
        #else
        "canvas"
        #endif
    }
}

private struct CanvasSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Resolution", selection: Binding(
                    get: { "\(model.profile.output.width)x\(model.profile.output.height)" },
                    set: { value in
                        let parts = value.split(separator: "x").compactMap { Int($0) }
                        // One edit, so captures restart once rather than twice.
                        if parts.count == 2 {
                            model.profile.output = OutputSettings(width: parts[0], height: parts[1], fps: model.profile.output.fps)
                        }
                    })) {
                    ForEach(OutputSettings.presets, id: \.height) { w, h in
                        Text("\(OutputSettings(width: w, height: h).shortName) (\(String(w)) × \(String(h)))").tag("\(w)x\(h)")
                    }
                }
                Picker("Frame rate", selection: $model.profile.output.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
            } footer: {
                Text("Every scene is composed at this size. Recording and streaming can each be scaled down from it (see their tabs), so a 4K canvas can record in 4K and stream in 1080p.")
                    .foregroundStyle(.secondary)
            }
            if model.isRecording {
                Text("Stop recording to change canvas settings.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(model.isRecording)
    }
}

/// Picker for recording/stream size; only offers sizes at or below the canvas.
private struct ResolutionPicker: View {
    let canvas: OutputSettings
    @Binding var selection: OutputResolution

    var body: some View {
        Picker("Resolution", selection: $selection) {
            Text("Same as canvas (\(canvas.shortName))").tag(OutputResolution.canvas)
            ForEach(OutputResolution.allCases.filter { $0 != .canvas && $0.isAvailable(for: canvas) }, id: \.self) { r in
                let size = r.size(for: canvas)
                Text("\(OutputSettings(width: size.width, height: size.height).shortName) (\(String(size.width)) × \(String(size.height)))").tag(r)
            }
        }
    }
}

private struct RecordingSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let rec = model.profile.recording
        let size = rec.resolution.size(for: model.profile.output)
        let recommended = Bitrates.recording(height: size.height, fps: model.profile.output.fps, codec: rec.codec)
        Form {
            Section {
                ResolutionPicker(canvas: model.profile.output, selection: $model.profile.recording.resolution)
                Picker("Codec", selection: $model.profile.recording.codec) {
                    Text("H.264").tag(VideoCodec.h264)
                    Text("HEVC (smaller files, recommended for 4K)").tag(VideoCodec.hevc)
                }
                LabeledContent("Video bitrate") {
                    HStack {
                        Stepper("\(rec.videoBitrateKbps / 1000) Mbps",
                                value: $model.profile.recording.videoBitrateKbps, in: 2_000...150_000, step: 2_000)
                        Button("Use recommended (\(recommended / 1000) Mbps)") {
                            model.profile.recording.videoBitrateKbps = recommended
                        }
                        .disabled(rec.videoBitrateKbps == recommended)
                    }
                }
                Picker("Audio bitrate", selection: $model.profile.recording.audioBitrateKbps) {
                    ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                }
            } footer: {
                Text(summary(size: size, rec: rec)).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text(rec.directoryPath).lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("Container", selection: $model.profile.recording.container) {
                    Text("QuickTime (.mov)").tag(RecordingContainer.mov)
                    Text("MPEG-4 (.mp4)").tag(RecordingContainer.mp4)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isRecording)
    }

    private func summary(size: (width: Int, height: Int), rec: RecordingSettings) -> String {
        let gb = Bitrates.gigabytesPerHour(videoKbps: rec.videoBitrateKbps, audioKbps: rec.audioBitrateKbps)
        return "Records \(size.width) × \(size.height) at \(model.profile.output.fps) fps, \(rec.codec == .hevc ? "HEVC" : "H.264") \(rec.videoBitrateKbps / 1000) Mbps: about \(String(format: "%.0f", gb)) GB per hour."
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(filePath: model.profile.recording.directoryPath)
        if panel.runModal() == .OK, let url = panel.url {
            model.profile.recording.directoryPath = url.path
        }
    }
}

private struct StreamingSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let stream = model.profile.broadcast.stream
        let size = stream.resolution.size(for: model.profile.output)
        let recommended = Bitrates.streaming(height: size.height, fps: model.profile.output.fps)
        Form {
            Section {
                ResolutionPicker(canvas: model.profile.output, selection: $model.profile.broadcast.stream.resolution)
                LabeledContent("Video bitrate") {
                    HStack {
                        Stepper("\(String(format: "%.1f", Double(stream.videoBitrateKbps) / 1000)) Mbps",
                                value: $model.profile.broadcast.stream.videoBitrateKbps, in: 1_000...60_000, step: 500)
                        Button("Use recommended (\(recommended / 1000) Mbps)") {
                            model.profile.broadcast.stream.videoBitrateKbps = recommended
                        }
                        .disabled(stream.videoBitrateKbps == recommended)
                    }
                }
                Picker("Audio bitrate", selection: $model.profile.broadcast.stream.audioBitrateKbps) {
                    ForEach([128, 160, 192, 256], id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Picker("Keyframe interval", selection: $model.profile.broadcast.stream.keyframeIntervalSeconds) {
                    ForEach([1, 2, 4], id: \.self) { Text("\($0) s").tag($0) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Streams \(String(size.width)) × \(String(size.height)) at \(model.profile.output.fps) fps, H.264 \(String(format: "%.1f", Double(stream.videoBitrateKbps) / 1000)) Mbps. Parallax uploads this once; the server relays it unchanged to every platform, so pick a bitrate your upload can sustain (aim for under ~70% of it).")
                    if stream.videoBitrateKbps > 6_000 || stream.keyframeIntervalSeconds != 2 {
                        Text("Twitch needs 2 s keyframes and at most 6 Mbps.").foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(model.broadcast.status.live)
    }
}

private struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var token = ""

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $url, prompt: Text("https://relay.example.com"))
                SecureField("Token", text: $token)
            } footer: {
                Text("Leave the URL empty to stay offline (turn on Mock in the chat panel to try things with fake chat). The token is stored in your Keychain.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Save & Reconnect") {
                    Keychain.write(token.trimmingCharacters(in: .whitespacesAndNewlines), for: "server-token")
                    model.profile.broadcast.serverURL = url.trimmingCharacters(in: .whitespaces)
                    model.broadcast.connect(model.profile.broadcast)
                }
            }
            if model.broadcast.service.mode == .server {
                Section("Accounts") {
                    AccountRow(platform: .twitch)
                }
            }
            if let error = model.broadcast.connectionError {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            url = model.profile.broadcast.serverURL
            token = Keychain.read("server-token") ?? ""
        }
    }
}

/// A platform sign-in on the server. Connecting shows a code to enter on the
/// platform's site (OAuth device flow), so the server needs no public URL.
private struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let platform: Platform

    private var account: Account? { model.broadcast.account(platform) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PlatformBadge(platform: platform)
                Text(platform.displayName)
                Spacer()
                switch account?.state {
                case .connected:
                    Text(account?.displayName ?? account?.login ?? "Connected").foregroundStyle(.secondary)
                    Button("Disconnect") { Task { await model.broadcast.disconnectAccount(platform) } }
                case .pending:
                    ProgressView().controlSize(.small)
                    Button("Cancel") { Task { await model.broadcast.disconnectAccount(platform) } }
                default:
                    Button("Connect \(platform.displayName)…", action: connect)
                }
            }
            if account?.state == .pending, let code = account?.pending {
                PendingCodeView(platform: platform, code: code)
            }
            if let error = account?.error, account?.state != .connected {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private func connect() {
        Task {
            if let code = await model.broadcast.connectAccount(platform), let url = URL(string: code.verificationURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

private struct PendingCodeView: View {
    let platform: Platform
    let code: DeviceCode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Approve Parallax in your browser. If \(platform.displayName) asks for a code, enter:")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(code.userCode)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy")
                Spacer()
                if let url = URL(string: code.verificationURL) {
                    Link("Open \(url.host() ?? "browser")", destination: url)
                }
            }
            Text("Expires \(code.expiresAt, style: .relative).").font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
