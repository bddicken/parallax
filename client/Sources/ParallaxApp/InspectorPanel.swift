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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Name", text: sourceBinding(\.name))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.weight(.medium))
                SourceSwapMenu(item: item, source: source)
            }

            if let error = model.sourceErrors[source.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }

            section("Layout") {
                HStack(spacing: 4) {
                    ForEach(LayoutPreset.allCases) { preset in
                        Button { model.updateItem(item.id, undo: "Apply Layout") { $0.frame = preset.rect } } label: {
                            Image(systemName: preset.symbol)
                                .frame(width: 22, height: 16)
                        }
                        .help(preset.title)
                        .background(item.frame == preset.rect ? Color.accentColor.opacity(0.35) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                HStack {
                    Text("Size").foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                    Slider(value: sizeBinding, in: 0.05...1)
                    Text(item.frame.width, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                .controlSize(.small)
                .help("Scales from the nearest corner, so a corner PiP stays put")
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

            section("Style") {
                HStack {
                    Text("Corners").foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                    Slider(value: itemBinding(\.cornerRadius), in: 0...0.5)
                    Text(item.cornerRadius == 0.5 ? "Round" : "\(Int(item.cornerRadius * 200))%")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .controlSize(.small)
                HStack {
                    Toggle("Border", isOn: itemBinding(\.border.isEnabled))
                    if item.border.isEnabled {
                        Stepper("\(Int(item.border.width)) px", value: itemBinding(\.border.width), in: 1...40)
                        ColorPicker("", selection: borderColor).labelsHidden()
                    }
                }
                .controlSize(.small)
            }

            section("Shadow") {
                Toggle("Drop shadow", isOn: itemBinding(\.shadow.isEnabled))
                    .controlSize(.small)
                if item.shadow.isEnabled {
                    styleSlider("Distance", \.shadow.distance, 0...100, "\(Int(item.shadow.distance)) px")
                    styleSlider("Direction", \.shadow.angle, 0...360, "\(Int(item.shadow.angle))°")
                    styleSlider("Blur", \.shadow.blur, 0...100, "\(Int(item.shadow.blur)) px")
                    styleSlider("Opacity", \.shadow.opacity, 0...1, "\(Int(item.shadow.opacity * 100))%")
                    HStack {
                        Text("Color").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        ColorPicker("", selection: shadowColor).labelsHidden()
                        Spacer()
                        Button("Reset") { model.updateItem(item.id, undo: "Reset Shadow") { $0.shadow = ItemShadow(isEnabled: true) } }
                    }
                    .controlSize(.small)
                }
            }

            section("Crop") {
                cropSlider("Top", \.top)
                cropSlider("Bottom", \.bottom)
                cropSlider("Left", \.left)
                cropSlider("Right", \.right)
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

    private func cropSlider(_ label: String, _ edge: WritableKeyPath<CropInsets, Double>) -> some View {
        HStack {
            Text(label).frame(width: 50, alignment: .leading).foregroundStyle(.secondary)
            Slider(value: Binding(get: { item.crop[keyPath: edge] }, set: { model.setCrop(item.id, edge, to: $0) }), in: 0...0.49)
            Text(item.crop[keyPath: edge], format: .percent.precision(.fractionLength(0)))
                .monospacedDigit().frame(width: 40, alignment: .trailing)
        }
        .controlSize(.small)
    }

    private func itemBinding<T>(_ path: WritableKeyPath<SceneItem, T>) -> Binding<T> {
        Binding(get: { item[keyPath: path] }, set: { v in model.updateItem(item.id, undo: "Edit \(source.name)") { $0[keyPath: path] = v } })
    }

    private func sourceBinding<T>(_ path: WritableKeyPath<VideoSource, T>) -> Binding<T> {
        Binding(get: { source[keyPath: path] }, set: { v in model.updateVideoSource(source.id) { $0[keyPath: path] = v } })
    }

    private var sizeBinding: Binding<Double> {
        Binding(get: { item.frame.width }, set: { w in
            model.updateItem(item.id, undo: "Resize Source") { $0.frame = $0.frame.scaled(by: w / max(0.001, $0.frame.width)) }
        })
    }

    private func styleSlider(_ label: String, _ path: WritableKeyPath<SceneItem, Double>, _ range: ClosedRange<Double>, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Slider(value: itemBinding(path), in: range)
            Text(value).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
        .controlSize(.small)
    }

    private var shadowColor: Binding<Color> {
        Binding(get: { item.shadow.color.color }, set: { color in
            let c = color.resolve(in: EnvironmentValues())
            model.updateItem(item.id, undo: "Shadow Color") {
                $0.shadow.color = RGBAColor(red: Double(c.red), green: Double(c.green), blue: Double(c.blue), alpha: Double(c.opacity))
            }
        })
    }

    private var borderColor: Binding<Color> {
        Binding(get: { item.border.color.color }, set: { color in
            let c = color.resolve(in: EnvironmentValues())
            model.updateItem(item.id, undo: "Border Color") {
                $0.border.color = RGBAColor(red: Double(c.red), green: Double(c.green), blue: Double(c.blue), alpha: Double(c.opacity))
            }
        })
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

extension LayoutPreset {
    var symbol: String {
        switch self {
        case .fullscreen: "rectangle.fill"
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .pipTopLeft: "rectangle.inset.topleft.filled"
        case .pipTopRight: "rectangle.inset.topright.filled"
        case .pipBottomLeft: "rectangle.inset.bottomleft.filled"
        case .pipBottomRight: "rectangle.inset.bottomright.filled"
        }
    }
}

/// Swaps which camera, display, or window a layer shows.
private struct SourceSwapMenu: View {
    @Environment(AppModel.self) private var model
    let item: SceneItem
    let source: VideoSource

    var body: some View {
        Menu {
            switch source.kind {
            case .camera:
                ForEach(model.devices.cameras) { camera in
                    option(camera.name, .camera(uniqueID: camera.id))
                }
            case .display, .window:
                Section("Displays") {
                    ForEach(model.devices.displays) { display in
                        option(display.name, .display(displayID: display.id))
                    }
                }
                Section("Windows") {
                    ForEach(model.devices.windows.prefix(30)) { window in
                        option(window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)", .window(windowID: window.id))
                    }
                }
            default:
                Text("This source can't be swapped")
            }
        } label: {
            Image(systemName: "arrow.triangle.swap")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show a different camera or screen in this layer")
        .task(id: source.id) {
            if source.kind.isScreen { await model.devices.refreshShareableContent() }
        }
    }

    private func option(_ name: String, _ kind: VideoSourceKind) -> some View {
        Button {
            model.replaceSource(of: item.id, with: kind, name: name)
        } label: {
            if kind == source.kind { Label(name, systemImage: "checkmark") } else { Text(name) }
        }
    }
}
