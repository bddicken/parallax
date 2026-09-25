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
                    Button(mic.name) { model.addAudioSource(kind: mic.microphoneKind, name: mic.name) }
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
    @State private var showingEQ = false

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
                Button { showingEQ.toggle() } label: {
                    Text("EQ").font(.caption.weight(.semibold))
                        .foregroundStyle(source.eq.isEnabled && !source.eq.isFlat ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Equalizer")
                .popover(isPresented: $showingEQ, arrowEdge: .bottom) {
                    EQEditor(source: source).padding().frame(width: 360)
                }
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

private struct EQEditor: View {
    @Environment(AppModel.self) private var model
    let source: AudioSource

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Equalizer", isOn: Binding(get: { source.eq.isEnabled },
                                                  set: { v in model.updateAudioSource(source.id) { $0.eq.isEnabled = v } }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Button("Flat") { model.updateAudioSource(source.id) { $0.eq.gainsDB = EQSettings().gainsDB } }
                    .controlSize(.small)
                    .disabled(source.eq.isFlat)
            }
            EQCurve(settings: source.eq)
                .frame(height: 64)
            HStack(spacing: 0) {
                ForEach(EQSettings.frequencies.indices, id: \.self) { i in
                    VStack(spacing: 4) {
                        Text(String(format: "%+.0f", source.eq.gain(band: i)))
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(source.eq.gain(band: i) == 0 ? .secondary : .primary)
                        EQFader(value: band(i), label: "\(Self.label(EQSettings.frequencies[i])) Hz")
                            .frame(height: 120)
                        Text(Self.label(EQSettings.frequencies[i]))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .opacity(source.eq.isEnabled ? 1 : 0.5)
            Text("Drag a band to adjust. Double-click to reset it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Adjusting any band also turns the EQ on.
    private func band(_ i: Int) -> Binding<Double> {
        Binding(get: { source.eq.gain(band: i) }, set: { v in
            model.updateAudioSource(source.id) { src in
                if src.eq.gainsDB.count != EQSettings.frequencies.count { src.eq.gainsDB = EQSettings().gainsDB }
                src.eq.gainsDB[i] = v
                src.eq.isEnabled = true
            }
        })
    }

    private static func label(_ hz: Double) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }
}

/// The EQ's combined frequency response from 20 Hz to 20 kHz.
private struct EQCurve: View {
    let settings: EQSettings
    private static let range = 15.0

    var body: some View {
        Canvas { context, size in
            let x = { (hz: Double) in size.width * log10(hz / 20) / 3 }
            let y = { (db: Double) in size.height / 2 * (1 - min(max(db, -Self.range), Self.range) / Self.range) }
            for hz in EQSettings.frequencies {
                context.stroke(Path { $0.move(to: CGPoint(x: x(hz), y: 0)); $0.addLine(to: CGPoint(x: x(hz), y: size.height)) },
                               with: .color(.secondary.opacity(0.15)), lineWidth: 1)
            }
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y(0))); $0.addLine(to: CGPoint(x: size.width, y: y(0))) },
                           with: .color(.secondary.opacity(0.4)), lineWidth: 1)
            let steps = max(2, Int(size.width / 2))
            let curve = Path { p in
                for step in 0...steps {
                    let fraction = Double(step) / Double(steps)
                    let hz = 20 * pow(1000, fraction)
                    let point = CGPoint(x: size.width * fraction,
                                        y: settings.isEnabled ? y(GraphicEQ.responseDB(settings, at: hz)) : y(0))
                    if step == 0 { p.move(to: point) } else { p.addLine(to: point) }
                }
            }
            var fill = curve
            fill.addLine(to: CGPoint(x: size.width, y: y(0)))
            fill.addLine(to: CGPoint(x: 0, y: y(0)))
            fill.closeSubpath()
            context.fill(fill, with: .color(.accentColor.opacity(0.15)))
            context.stroke(curve, with: .color(settings.isEnabled ? .accentColor : .secondary), lineWidth: 1.5)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Vertical fader over `EQSettings.gainRange`. Drags are relative, so a
/// click doesn't jump the value; double-click resets to 0.
private struct EQFader: View {
    @Binding var value: Double
    let label: String
    @State private var dragStart: Double?

    private static let range = EQSettings.gainRange
    private static let step = 0.5

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, mid = geo.size.width / 2
            let y = { (v: Double) in h * (1 - (v - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound)) }
            ZStack(alignment: .topLeading) {
                Capsule().fill(.quaternary)
                    .frame(width: 4, height: h)
                    .offset(x: mid - 2)
                Rectangle().fill(.secondary.opacity(0.5))
                    .frame(width: 10, height: 1)
                    .offset(x: mid - 5, y: y(0))
                Rectangle().fill(Color.accentColor)
                    .frame(width: 4, height: abs(y(value) - y(0)))
                    .offset(x: mid - 2, y: min(y(value), y(0)))
                Capsule().fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .frame(width: 18, height: 8)
                    .offset(x: mid - 9, y: y(value) - 4)
            }
            .frame(width: geo.size.width, height: h)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        let start = dragStart ?? value
                        dragStart = start
                        let span = Self.range.upperBound - Self.range.lowerBound
                        let raw = start - drag.translation.height / h * span
                        let snapped = (raw / Self.step).rounded() * Self.step
                        let clamped = min(max(snapped, Self.range.lowerBound), Self.range.upperBound)
                        if clamped != value { value = clamped }
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { value = 0 }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%+.1f dB", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 1, Self.range.upperBound)
            case .decrement: value = max(value - 1, Self.range.lowerBound)
            @unknown default: break
            }
        }
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
