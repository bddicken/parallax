import ParallaxCore
import SwiftUI

struct SourcesPanel: View {
    @Environment(AppModel.self) private var model
    @State private var showingAdd = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PanelHeader(title: "Sources") {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add source to this scene")
            }
            let items = Array((model.programScene?.items ?? []).reversed())
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No Sources", systemImage: "rectangle.on.rectangle.slash")
                } description: {
                    Text("Add a camera, screen, or overlay to this scene.")
                } actions: {
                    Button("Add Source") { showingAdd = true }
                }
                .frame(maxHeight: .infinity)
            } else {
                // Listed top-of-stack first, like layers in a design tool.
                List(selection: $model.selectedItemID) {
                    ForEach(items) { item in
                        SourceRow(item: item).tag(item.id)
                    }
                }
                .listStyle(.sidebar)
                .onDeleteCommand {
                    if let id = model.selectedItemID { model.removeItem(id) }
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddSourceSheet().environment(model)
        }
    }
}

private struct SourceRow: View {
    @Environment(AppModel.self) private var model
    let item: SceneItem

    var body: some View {
        let source = model.profile.videoSource(item.sourceID)
        HStack(spacing: 8) {
            Image(systemName: source?.kind.symbol ?? "questionmark")
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(source?.name ?? "Missing")
                .lineLimit(1)
                .foregroundStyle(item.isVisible ? .primary : .tertiary)
            if model.sourceErrors[item.sourceID] != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(model.sourceErrors[item.sourceID] ?? "")
            }
            Spacer()
            Button {
                model.updateItem(item.id) { $0.isVisible.toggle() }
            } label: {
                Image(systemName: item.isVisible ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .help(item.isVisible ? "Hide" : "Show")
        }
        .contextMenu {
            Button("Bring Forward") { model.moveItem(item.id, by: 1) }
            Button("Send Backward") { model.moveItem(item.id, by: -1) }
            Divider()
            Button("Remove", role: .destructive) { model.removeItem(item.id) }
        }
    }
}

extension VideoSourceKind {
    var symbol: String {
        switch self {
        case .camera: "video.fill"
        case .display: "display"
        case .window: "macwindow"
        case .image: "photo"
        case .color: "paintpalette.fill"
        case .chatFeed: "bubble.left.and.bubble.right.fill"
        case .featuredChat: "text.bubble.fill"
        }
    }
}
