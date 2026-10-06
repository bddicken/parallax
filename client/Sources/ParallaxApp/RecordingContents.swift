import ParallaxCore
import SwiftUI

/// Picks what goes into the local recording. Changes take effect right
/// away, mid-recording too, and never change the stream.
struct RecordingContentsButton: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        let leavesOut = !model.recordingLeavesOut.isEmpty
        Button { showing.toggle() } label: {
            Image(systemName: leavesOut ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .foregroundStyle(leavesOut ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .help("Choose what goes into the recording")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            RecordingContents().padding().frame(width: 280)
        }
    }
}

private struct RecordingContents: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let profile = model.profile
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("In the Recording").font(.headline)
                Text(model.isRecording
                     ? "Changes apply to this recording right away. The stream still gets everything."
                     : "Changes apply right away, mid-recording too. The stream still gets everything.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !profile.videoSources.isEmpty {
                group("Video") {
                    ForEach(profile.videoSources) { source in
                        Toggle(isOn: Binding(get: { source.isInRecording },
                                             set: { v in model.updateVideoSource(source.id) { $0.isInRecording = v } })) {
                            Label(source.name, systemImage: source.kind.symbol)
                        }
                    }
                }
            }
            if !profile.activeAudioSources.isEmpty {
                group("Audio") {
                    ForEach(profile.activeAudioSources) { source in
                        Toggle(isOn: Binding(get: { source.isInRecording },
                                             set: { v in model.updateAudioSource(source.id) { $0.isInRecording = v } })) {
                            Label(source.name, systemImage: source.kind.symbol)
                        }
                    }
                }
            }
            if profile.videoSources.isEmpty && profile.activeAudioSources.isEmpty {
                Text("No sources yet.").foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
