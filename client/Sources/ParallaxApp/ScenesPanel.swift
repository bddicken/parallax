import ParallaxCore
import SwiftUI

struct ScenesPanel: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: UUID?
    @State private var draftName = ""

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Scenes") {
                Button { model.addScene() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add scene")
            }
            List {
                ForEach(Array(model.profile.scenes.enumerated()), id: \.element.id) { index, scene in
                    row(scene, index: index)
                }
                .onMove { model.moveScenes(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
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
                    .onSubmit { commitRename(scene.id) }
                    .onExitCommand { renaming = nil }
            } else {
                Text(scene.name)
                    .fontWeight(isProgram ? .semibold : .regular)
            }
            Spacer()
            if index < 9 {
                Text("⌘\(index + 1)").font(.caption).foregroundStyle(.tertiary)
            }
            if isProgram {
                Circle().fill(.red).frame(width: 8, height: 8).help("On program")
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
        .listRowBackground(isProgram ? Color.accentColor.opacity(0.18) : Color.clear)
        .onTapGesture { model.selectScene(scene.id) }
        .contextMenu {
            Button("Rename") {
                draftName = scene.name
                renaming = scene.id
            }
            Button("Duplicate") { model.duplicateScene(scene.id) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteScene(scene.id) }
                .disabled(model.profile.scenes.count <= 1)
        }
    }

    private func commitRename(_ id: UUID) {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { model.renameScene(id, to: name) }
        renaming = nil
    }
}
