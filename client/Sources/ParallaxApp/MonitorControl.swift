import ParallaxCore
import ParallaxMedia
import SwiftUI

/// Control-bar button + popover for choosing where program audio is monitored.
struct MonitorControl: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: model.monitorError != nil ? "exclamationmark.triangle.fill" : "headphones")
                    .foregroundStyle(iconColor)
                Text(label).lineLimit(1)
            }
            .frame(maxWidth: 170)
        }
        .help("Audio monitor")
        .popover(isPresented: $showing, arrowEdge: .top) {
            MonitorPopover().environment(model).padding(16).frame(width: 320)
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.environment["PARALLAX_DEBUG_SHOW_MONITOR"] != nil {
                try? await Task.sleep(for: .seconds(1))
                showing = true
            }
        }
        #endif
    }

    private var label: String {
        switch model.profile.monitor.output {
        case .off: "Monitor Off"
        case .systemDefault: model.devices.defaultOutputName ?? "System Default"
        case .device(let uid): model.devices.outputDevices.first { $0.id == uid }?.name ?? "Disconnected"
        }
    }

    private var iconColor: Color {
        if model.monitorError != nil { return .yellow }
        return model.profile.monitor.output == .off ? .secondary : .accentColor
    }
}

private struct MonitorPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio Monitor").font(.headline)
            Picker("Output", selection: $model.profile.monitor.output) {
                Text("None").tag(MonitorSettings.Output.off)
                Text("System Default\(model.devices.defaultOutputName.map { " (\($0))" } ?? "")")
                    .tag(MonitorSettings.Output.systemDefault)
                ForEach(model.devices.outputDevices) { device in
                    Text(device.name).tag(MonitorSettings.Output.device(uid: device.id))
                }
                if case .device(let uid) = model.profile.monitor.output,
                   !model.devices.outputDevices.contains(where: { $0.id == uid }) {
                    Text("Disconnected device").tag(model.profile.monitor.output)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $model.profile.monitor.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                Text("\(Int(model.profile.monitor.volume * 100))%")
                    .monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            .disabled(model.profile.monitor.output == .off)

            LevelMeter(level: model.masterLevel, dimmed: model.profile.monitor.output == .off)
                .frame(height: 6)
                .help("Program audio level")

            if let error = model.monitorError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.yellow)
            } else {
                Text("You hear the program mix, including audio delays. Use headphones so speakers don't feed back into your mic.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
