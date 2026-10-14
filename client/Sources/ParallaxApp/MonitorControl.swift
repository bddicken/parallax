import ParallaxCore
import ParallaxMedia
import SwiftUI

/// Control-bar button + popover for choosing where program audio is monitored.
struct MonitorControl: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false
    /// The device name truncates past this.
    var maxLabelWidth: CGFloat = 170

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: model.monitorError != nil ? "exclamationmark.triangle.fill" : "headphones")
                    .foregroundStyle(iconColor)
                Text(label).lineLimit(1)
            }
            .frame(maxWidth: maxLabelWidth)
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

            Picker("Hear", selection: $model.profile.monitor.mix) {
                Text("Stream Mix").tag(MonitorSettings.Mix.program)
                Text("Custom Mix").tag(MonitorSettings.Mix.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.profile.monitor.output == .off)
            .help("Hear exactly what viewers hear, or set your own level for each input")

            if model.profile.monitor.mix == .custom {
                MonitorLevels()
                    .disabled(model.profile.monitor.output == .off)
            }

            if let error = model.monitorError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.yellow)
            } else {
                Text(caption)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var caption: String {
        switch model.profile.monitor.mix {
        case .program:
            "You hear the program mix, including audio delays. Use headphones so speakers don't feed back into your mic."
        case .custom:
            "Only what you hear changes; the stream and recording keep their mix. Use headphones so speakers don't feed back into your mic."
        }
    }
}

/// One slider per input for the custom monitor mix, relative to its stream level.
private struct MonitorLevels: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sources = model.profile.activeAudioSources
        if sources.isEmpty {
            Text("No audio inputs.").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sources) { source in
                    row(source)
                }
            }
        }
    }

    private func row(_ source: AudioSource) -> some View {
        let level = level(source.id)
        return HStack(spacing: 8) {
            Button {
                level.wrappedValue = level.wrappedValue > 0 ? 0 : 1
            } label: {
                Image(systemName: level.wrappedValue > 0 ? source.kind.symbol : "speaker.slash.fill")
                    .foregroundStyle(level.wrappedValue > 0 ? Color.secondary : Color.red)
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(level.wrappedValue > 0 ? "Don't hear \(source.name)" : "Hear \(source.name)")
            Text(source.name).lineLimit(1).frame(width: 90, alignment: .leading)
            Slider(value: level, in: 0...1)
            Text("\(Int(level.wrappedValue * 100))%")
                .monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }

    private func level(_ id: UUID) -> Binding<Double> {
        Binding {
            model.profile.monitor.level(for: id)
        } set: {
            model.profile.monitor.levels[id] = $0
        }
    }
}
