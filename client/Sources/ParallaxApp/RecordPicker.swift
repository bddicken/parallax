import ParallaxCore
import SwiftUI

/// Shown when Record is pressed, so each recording captures exactly what's
/// checked: the main feed (what's live) and/or scenes on their own, each to
/// its own file. Remembers the last choice.
struct RecordPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let outputs = model.profile.recording.outputs
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Record").font(.headline)
                Text("Each one is saved to its own file. They start and stop together, so they line up when you edit.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: chosen(nil)) {
                Text("Main feed")
                Text("What's live, with overlays and transitions").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Scenes on their own").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.profile.scenes) { scene in
                        Toggle(isOn: chosen(scene.id)) {
                            HStack(spacing: 4) {
                                Text(scene.name)
                                if scene.id == model.profile.programSceneID {
                                    Text("live").font(.caption2).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Text(outputs.isEmpty ? "Nothing chosen" : outputs.count == 1 ? "1 file" : "\(outputs.count) files")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Start Recording", action: model.startRecording)
                    .keyboardShortcut(.defaultAction)
                    .disabled(outputs.isEmpty)
            }
        }
        .toggleStyle(.checkbox)
        .padding()
        .frame(width: 300)
    }

    private func chosen(_ sceneID: UUID?) -> Binding<Bool> {
        Binding(get: { model.isRecordingOutput(sceneID) }, set: { model.setRecordingOutput(sceneID, $0) })
    }
}
