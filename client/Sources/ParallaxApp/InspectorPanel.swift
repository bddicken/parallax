import ParallaxCore
import SwiftUI

struct InspectorPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Inspector")
            if let item = model.selectedItem, let source = model.profile.videoSource(item.sourceID) {
                ScrollView {
                    ItemInspector(item: item, source: source)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            } else {
                Text("Select a source in the list or preview.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ItemInspector: View {
    @Environment(AppModel.self) private var model
    let item: SceneItem
    let source: VideoSource

    private let presetColumns = [GridItem(.adaptive(minimum: 88), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: sourceBinding(\.name))
                .textFieldStyle(.roundedBorder)
                .font(.body.weight(.medium))

            if let error = model.sourceErrors[source.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }

            section("Layout") {
                LazyVGrid(columns: presetColumns, alignment: .leading, spacing: 6) {
                    ForEach(LayoutPreset.allCases) { preset in
                        Button(preset.title) { model.updateItem(item.id) { $0.frame = preset.rect } }
                            .controlSize(.small)
                    }
                }
                Picker("Fit", selection: itemBinding(\.contentMode)) {
                    ForEach(ContentMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow {
                        percentField("X", itemBinding(\.frame.x))
                        percentField("Y", itemBinding(\.frame.y))
                    }
                    GridRow {
                        percentField("W", itemBinding(\.frame.width))
                        percentField("H", itemBinding(\.frame.height))
                    }
                }
            }

            section("Crop") {
                cropSlider("Top", \.crop.top)
                cropSlider("Bottom", \.crop.bottom)
                cropSlider("Left", \.crop.left)
                cropSlider("Right", \.crop.right)
            }

            if source.kind.isLive {
                section("Video Delay") {
                    HStack {
                        Slider(value: delayBinding, in: 0...2000, step: 10)
                        Text("\(source.delayMs) ms").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                    Text("Applies to this source in every scene.").font(.caption).foregroundStyle(.secondary)
                }
            }

            if case .color(let c) = source.kind {
                section("Color") {
                    ColorPicker("Fill", selection: Binding(
                        get: { Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha) },
                        set: { color in
                            let resolved = color.resolve(in: EnvironmentValues())
                            model.updateVideoSource(source.id) {
                                $0.kind = .color(RGBAColor(red: Double(resolved.red), green: Double(resolved.green),
                                                           blue: Double(resolved.blue), alpha: Double(resolved.opacity)))
                            }
                        }))
                }
            }

            HStack {
                Button { model.moveItem(item.id, by: 1) } label: { Label("Forward", systemImage: "square.2.layers.3d.top.filled") }
                Button { model.moveItem(item.id, by: -1) } label: { Label("Backward", systemImage: "square.2.layers.3d.bottom.filled") }
                Spacer()
                Button(role: .destructive) { model.removeItem(item.id) } label: { Image(systemName: "trash") }
                    .help("Remove from scene")
            }
            .controlSize(.small)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func percentField(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary).frame(width: 14)
            TextField(label, value: value, format: .percent.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
        }
    }

    private func cropSlider(_ label: String, _ path: WritableKeyPath<SceneItem, Double>) -> some View {
        HStack {
            Text(label).frame(width: 50, alignment: .leading).foregroundStyle(.secondary)
            Slider(value: itemBinding(path), in: 0...0.49)
            Text(item[keyPath: path], format: .percent.precision(.fractionLength(0)))
                .monospacedDigit().frame(width: 40, alignment: .trailing)
        }
        .controlSize(.small)
    }

    private func itemBinding<T>(_ path: WritableKeyPath<SceneItem, T>) -> Binding<T> {
        Binding(get: { item[keyPath: path] }, set: { v in model.updateItem(item.id) { $0[keyPath: path] = v } })
    }

    private func sourceBinding<T>(_ path: WritableKeyPath<VideoSource, T>) -> Binding<T> {
        Binding(get: { source[keyPath: path] }, set: { v in model.updateVideoSource(source.id) { $0[keyPath: path] = v } })
    }

    private var delayBinding: Binding<Double> {
        Binding(get: { Double(source.delayMs) }, set: { v in model.updateVideoSource(source.id) { $0.delayMs = Int(v) } })
    }
}

extension VideoSourceKind {
    var isLive: Bool {
        switch self {
        case .camera, .display, .window: true
        default: false
        }
    }
}
