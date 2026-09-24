import ParallaxCore
import ParallaxMedia
import SwiftUI

struct MixerPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Audio") {
                LevelMeter(level: model.masterLevel)
                    .frame(width: 140, height: 8)
                    .help("Master")
                AddAudioMenu()
            }
            if model.profile.audioSources.isEmpty {
                Text("No audio inputs. Add a microphone or system audio.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.profile.audioSources) { source in
                            ChannelStrip(source: source, level: model.levels[source.id] ?? .silent)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

private struct AddAudioMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Section("Inputs") {
                ForEach(model.devices.microphones) { mic in
                    Button(mic.name) { model.addAudioSource(kind: .device(uniqueID: mic.id), name: mic.name) }
                }
            }
            Button("System Audio") { model.addAudioSource(kind: .systemAudio, name: "System Audio") }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add audio input")
    }
}

private struct ChannelStrip: View {
    @Environment(AppModel.self) private var model
    let source: AudioSource
    let level: AudioLevel
    @State private var showingOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: source.kind == .systemAudio ? "speaker.wave.2.fill" : "mic.fill")
                    .foregroundStyle(.secondary)
                Text(source.name).lineLimit(1)
                if let error = model.sourceErrors[source.id] {
                    SourceWarning(message: error, permission: source.kind.permission)
                }
                Spacer()
                Button { showingOptions.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
                        ChannelOptions(source: source).padding().frame(width: 300)
                    }
                Button {
                    model.updateAudioSource(source.id) { $0.isMuted.toggle() }
                } label: {
                    Image(systemName: source.isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundStyle(source.isMuted ? .red : .primary)
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(source.isMuted ? "Unmute" : "Mute")
            }
            LevelMeter(level: level, dimmed: source.isMuted).frame(height: 8)
            HStack {
                Text("Gain").font(.caption).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                Slider(value: binding(\.gainDB), in: -60...20)
                    .controlSize(.small)
                Text(String(format: "%+.1f dB", source.gainDB))
                    .font(.caption).monospacedDigit().frame(width: 60, alignment: .trailing)
            }
            // Applied live: raising it inserts a gap of silence, lowering it
            // skips ahead, so you can dial in sync by ear while talking.
            HStack {
                Text("Delay").font(.caption).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                Slider(value: Binding(get: { Double(min(source.delayMs, Self.maxDelayMs)) },
                                      set: { v in model.updateAudioSource(source.id) { $0.delayMs = Int(v.rounded()) } }),
                       in: 0...Double(Self.maxDelayMs))
                    .controlSize(.small)
                Text("\(source.delayMs) ms")
                    .font(.caption).monospacedDigit().frame(width: 60, alignment: .trailing)
            }
            .help("Delay this input to line up with a slower camera")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Reset Gain") { model.updateAudioSource(source.id) { $0.gainDB = 0 } }
            Button("Reset Delay") { model.updateAudioSource(source.id) { $0.delayMs = 0 } }
            Button("Remove", role: .destructive) { model.removeAudioSource(source.id) }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<AudioSource, T>) -> Binding<T> {
        Binding(get: { source[keyPath: path] }, set: { v in model.updateAudioSource(source.id) { $0[keyPath: path] = v } })
    }

    private static let maxDelayMs = 1000
}

private struct ChannelOptions: View {
    @Environment(AppModel.self) private var model
    let source: AudioSource

    var body: some View {
        Form {
            TextField("Name", text: binding(\.name))
            if case .device = source.kind {
                Section("Channels") {
                    Picker("Mode", selection: binding(\.channelMode)) {
                        Text("Mono").tag(ChannelMode.mono)
                        Text("Stereo").tag(ChannelMode.stereo)
                    }
                    Stepper("Input \(source.firstChannel + 1)\(source.channelMode == .stereo ? "–\(source.firstChannel + 2)" : "")",
                            value: binding(\.firstChannel), in: 0...31)
                }
            }
            Section("Processing") {
                Toggle("High-pass filter (80 Hz)", isOn: binding(\.highPassEnabled))
                Toggle("Noise gate", isOn: binding(\.gate.isEnabled))
                if source.gate.isEnabled {
                    HStack {
                        Slider(value: binding(\.gate.thresholdDB), in: -80 ... -10)
                        Text("\(Int(source.gate.thresholdDB)) dB").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding<T>(_ path: WritableKeyPath<AudioSource, T>) -> Binding<T> {
        Binding(get: { source[keyPath: path] }, set: { v in model.updateAudioSource(source.id) { $0[keyPath: path] = v } })
    }
}

/// Horizontal meter from -60 dBFS to 0: RMS as the bar, peak as a tick.
struct LevelMeter: View {
    let level: AudioLevel
    var dimmed = false

    var body: some View {
        GeometryReader { geo in
            let rms = fraction(level.rmsDB), peak = fraction(level.peakDB)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                LinearGradient(stops: [
                    .init(color: .green, location: 0), .init(color: .green, location: 0.7),
                    .init(color: .yellow, location: 0.85), .init(color: .red, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
                .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * rms) }
                .clipShape(Capsule())
                Rectangle()
                    .fill(peak > 0.95 ? .red : .white)
                    .frame(width: 2)
                    .offset(x: max(0, geo.size.width * peak - 2))
                    .opacity(peak > 0 ? 1 : 0)
            }
            .opacity(dimmed ? 0.4 : 1)
            .animation(.linear(duration: 0.05), value: level)
        }
    }

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat(min(1, max(0, (db + 60) / 60)))
    }
}
