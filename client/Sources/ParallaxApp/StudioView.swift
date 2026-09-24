import SwiftUI

struct StudioView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        HSplitView {
            VStack(spacing: 0) {
                ScenesPanel()
                Divider()
                SourcesPanel()
            }
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 340)

            GeometryReader { geo in
                // The preview gets just enough height for the canvas at this
                // width; the inspector and mixer take the rest.
                let aspect = Double(model.profile.output.height) / Double(model.profile.output.width)
                let bottomMin: CGFloat = 250, controls: CGFloat = 52
                let preview = min(max(260, geo.size.height - bottomMin - controls), geo.size.width * aspect + 32)
                VStack(spacing: 0) {
                    PreviewPanel()
                        .frame(height: preview)
                    Divider()
                    HStack(alignment: .top, spacing: 0) {
                        InspectorPanel()
                            .frame(width: 340)
                        Divider()
                        MixerPanel()
                    }
                    .frame(maxHeight: .infinity)
                    Divider()
                    ControlBar()
                }
            }
            .frame(minWidth: 680)

            ChatPanel()
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 440)
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.banner)
        .sheet(item: $model.permissionPrompt, onDismiss: model.permissionSheetDismissed) { permission in
            PermissionSheet(permission: permission).environment(model)
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
    }
}

struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text).font(.callout).lineLimit(3)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
        .frame(maxWidth: 560)
        .task(id: text) {
            try? await Task.sleep(for: .seconds(8))
            dismiss()
        }
    }
}

/// A titled section with an optional trailing accessory, used by every panel.
struct PanelHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

extension PanelHeader where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}
