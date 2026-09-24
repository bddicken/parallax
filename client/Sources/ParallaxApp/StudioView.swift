import SwiftUI

struct StudioView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ScenesPanel()
                Divider()
                SourcesPanel()
            }
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 340)

            VStack(spacing: 0) {
                PreviewPanel()
                    .layoutPriority(1)
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    InspectorPanel()
                        .frame(width: 320)
                    Divider()
                    MixerPanel()
                }
                .frame(height: 270)
                Divider()
                ControlBar()
            }
            .frame(minWidth: 660)

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
