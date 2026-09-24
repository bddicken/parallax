import ParallaxCore
import ParallaxMedia
import SwiftUI
import UniformTypeIdentifiers

struct AddSourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .camera
    @State private var color = Color(red: 0.1, green: 0.1, blue: 0.14)
    @State private var importingImage = false

    enum Tab: String, CaseIterable {
        case camera = "Camera", screen = "Screen", window = "Window", overlay = "Overlay", existing = "Existing"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to \(model.programScene?.name ?? "Scene")").font(.title3.bold())
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case .camera: cameras
                case .screen: displays
                case .window: windows
                case .overlay: overlays
                case .existing: existing
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 240, alignment: .topLeading)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task(id: tab) {
            if tab == .screen || tab == .window { await model.devices.refreshShareableContent() }
        }
        .fileImporter(isPresented: $importingImage, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { add(.image(path: url.path), url.deletingPathExtension().lastPathComponent) }
        }
    }

    private var cameras: some View {
        pickList(model.devices.cameras.map { ($0.id, $0.name) }, empty: "No cameras found.") { id, name in
            add(.camera(uniqueID: id), name)
        }
    }

    @ViewBuilder
    private var displays: some View {
        if let error = model.devices.screenCaptureError {
            Text(error).foregroundStyle(.secondary)
        } else {
            pickList(model.devices.displays.map { ($0.id, $0.name) }, empty: "Loading displays…") { id, name in
                add(.display(displayID: id), name)
            }
        }
    }

    @ViewBuilder
    private var windows: some View {
        if let error = model.devices.screenCaptureError {
            Text(error).foregroundStyle(.secondary)
        } else {
            pickList(model.devices.windows.map { ($0.id, $0.title.isEmpty ? $0.appName : "\($0.appName) — \($0.title)") },
                     empty: "Loading windows…") { id, name in
                add(.window(windowID: id), name)
            }
        }
    }

    private var overlays: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Chat Feed", systemImage: "bubble.left.and.bubble.right.fill", detail: "Recent messages from every platform") {
                add(.chatFeed, "Chat Feed")
            }
            row("Featured Comment", systemImage: "text.bubble.fill", detail: "The comment you star in the chat panel") {
                add(.featuredChat, "Featured Comment")
            }
            row("Image…", systemImage: "photo", detail: "PNG, JPEG, HEIC…") { importingImage = true }
            HStack {
                ColorPicker("", selection: $color).labelsHidden()
                row("Color", systemImage: "paintpalette.fill", detail: "Solid background") {
                    let c = color.resolve(in: EnvironmentValues())
                    add(.color(RGBAColor(red: Double(c.red), green: Double(c.green), blue: Double(c.blue), alpha: Double(c.opacity))), "Color")
                }
            }
        }
    }

    private var existing: some View {
        pickList(model.profile.videoSources.map { ($0.id, $0.name) }, empty: "No sources yet.") { id, _ in
            model.addExistingSource(id)
            dismiss()
        }
    }

    private func pickList<ID: Hashable>(_ items: [(ID, String)], empty: String, pick: @escaping (ID, String) -> Void) -> some View {
        Group {
            if items.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            } else {
                List(items, id: \.0) { item in
                    Button { pick(item.0, item.1) } label: {
                        Text(item.1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.bordered)
            }
        }
    }

    private func row(_ title: String, systemImage: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage).frame(width: 24)
                VStack(alignment: .leading) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func add(_ kind: VideoSourceKind, _ name: String) {
        model.addVideoSource(kind: kind, name: name)
        dismiss()
    }
}
