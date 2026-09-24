import AppKit
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
            if isProgram {
                Circle().fill(.red).frame(width: 8, height: 8).help("Live")
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
        .listRowBackground(isProgram ? Color.accentColor.opacity(0.18) : Color.clear)
        .onTapGesture {
            // Single-click switches immediately; the second click of a double-click renames.
            if NSApp.currentEvent?.clickCount == 2 {
                startRename(scene)
            } else {
                model.selectScene(scene.id)
            }
        }
        .contextMenu {
            Button("Rename") { startRename(scene) }
            Button("Duplicate") { model.duplicateScene(scene.id) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteScene(scene.id) }
                .disabled(model.profile.scenes.count <= 1)
        }
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
