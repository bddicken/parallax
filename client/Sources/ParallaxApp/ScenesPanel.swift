import ParallaxCore
import SwiftUI

struct ScenesPanel: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: UUID?
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Scenes") {
                Menu {
                    Section("New scene from layout") {
                        ForEach(SceneTemplate.allCases) { template in
                            Button(template.title) { model.addScene(template) }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                } primaryAction: {
                    model.addScene(.blank)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .help("Click to add a blank scene; hold for layouts")

                Button { if let id = model.profile.programSceneID { model.deleteScene(id) } } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(model.profile.scenes.count <= 1)
                .help("Delete the current scene")
            }
            // Native selection (not a tap gesture) so rows can be dragged to reorder.
            // Selecting a scene makes it live; double-click renames.
            List(selection: programSelection) {
                ForEach(Array(model.profile.scenes.enumerated()), id: \.element.id) { index, scene in
                    row(scene, index: index).tag(scene.id)
                }
                .onMove { model.moveScenes(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let scene = model.profile.scene(id) {
                    Button("Rename") { startRename(scene) }
                    Button("Duplicate") { model.duplicateScene(id) }
                    Toggle("Record to Its Own File", isOn: Binding(
                        get: { model.isRecordingOutput(id) }, set: { model.setRecordingOutput(id, $0) }))
                        .disabled(model.isRecording)
                    Divider()
                    Button("Delete", role: .destructive) { model.deleteScene(id) }
                        .disabled(model.profile.scenes.count <= 1)
                }
            } primaryAction: { ids in
                if let id = ids.first, let scene = model.profile.scene(id) { startRename(scene) }
            }
        }
        .frame(minHeight: 180)
    }

    @ViewBuilder
    private func row(_ scene: StudioScene, index: Int) -> some View {
        let isProgram = scene.id == model.profile.programSceneID
        HStack {
            if renaming == scene.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFocused)
                    .onSubmit { commitRename(scene.id) }
                    .onExitCommand { renaming = nil }
                    .onChange(of: renameFocused) { _, focused in if !focused { commitRename(scene.id) } }
            } else {
                Text(scene.name)
                    .fontWeight(isProgram ? .semibold : .regular)
                Text("\(scene.items.count)")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help("\(scene.items.count) sources")
            }
            Spacer()
            if index < 9 {
                Text("⌘\(index + 1)").font(.caption).foregroundStyle(.tertiary)
            }
            if model.isRecordingOutput(scene.id) {
                Image(systemName: "record.circle")
                    .font(.caption)
                    .foregroundStyle(model.isRecording ? .red : .secondary)
                    .help("Recorded to its own file")
            }
            if isProgram {
                Circle().fill(.red).frame(width: 8, height: 8).help("Live")
            }
        }
        .padding(.vertical, 3)
    }

    private var programSelection: Binding<UUID?> {
        Binding(
            get: { model.profile.programSceneID },
            set: { if let id = $0 { model.selectScene(id) } }
        )
    }

    private func startRename(_ scene: StudioScene) {
        draftName = scene.name
        renaming = scene.id
        renameFocused = true
    }

    private func commitRename(_ id: UUID) {
        guard renaming == id else { return }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { model.renameScene(id, to: name) }
        renaming = nil
    }
}
