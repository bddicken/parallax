import AppKit
import ParallaxCore
import ParallaxRemote
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            OutputSettingsView().tabItem { Label("Output", systemImage: "rectangle.on.rectangle") }
            RecordingSettingsView().tabItem { Label("Recording", systemImage: "record.circle") }
            ServerSettingsView().tabItem { Label("Server", systemImage: "server.rack") }
        }
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}

private struct OutputSettingsView: View {
    @Environment(AppModel.self) private var model

    private static let resolutions = [(1280, 720), (1920, 1080), (2560, 1440)]

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Resolution", selection: Binding(
                get: { "\(model.profile.output.width)x\(model.profile.output.height)" },
                set: { value in
                    let parts = value.split(separator: "x").compactMap { Int($0) }
                    if parts.count == 2 {
                        model.profile.output.width = parts[0]
                        model.profile.output.height = parts[1]
                    }
                })) {
                ForEach(Self.resolutions, id: \.0) { w, h in Text("\(w) × \(h)").tag("\(w)x\(h)") }
            }
            Picker("Frame rate", selection: $model.profile.output.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            if model.isRecording {
                Text("Stop recording to change output settings.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(model.isRecording)
    }
}

private struct RecordingSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            LabeledContent("Folder") {
                HStack {
                    Text(model.profile.recording.directoryPath).lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: chooseFolder)
                }
            }
            Picker("Codec", selection: $model.profile.recording.codec) {
                Text("H.264").tag(VideoCodec.h264)
                Text("HEVC").tag(VideoCodec.hevc)
            }
            Picker("Container", selection: $model.profile.recording.container) {
                Text("QuickTime (.mov)").tag(RecordingContainer.mov)
                Text("MPEG-4 (.mp4)").tag(RecordingContainer.mp4)
            }
            LabeledContent("Video bitrate") {
                Stepper("\(model.profile.recording.videoBitrateKbps / 1000) Mbps",
                        value: $model.profile.recording.videoBitrateKbps, in: 2_000...80_000, step: 2_000)
            }
            Picker("Audio bitrate", selection: $model.profile.recording.audioBitrateKbps) {
                ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isRecording)
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
                Text("Leave the URL empty to use the built-in mock server. The token is stored in your Keychain.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Save & Reconnect") {
                    Keychain.write(token, for: "server-token")
                    model.profile.broadcast.serverURL = url.trimmingCharacters(in: .whitespaces)
                    model.broadcast.connect(model.profile.broadcast)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            url = model.profile.broadcast.serverURL
            token = Keychain.read("server-token") ?? ""
        }
    }
}
