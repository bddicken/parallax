import AVFoundation
import Foundation
import ParallaxCore

/// An input the mixer pulls from on its own clock instead of one that
/// pushes captured audio, e.g. the music player.
protocol AudioPullSource: AnyObject, Sendable {
    /// Fills `out` with `frames` frames of interleaved stereo at 48 kHz.
    func render(into out: UnsafeMutableBufferPointer<Float>, frames: Int)
}

public struct MixerLevels: Sendable {
    public var inputs: [UUID: AudioLevel]
    public var master: AudioLevel
}

/// Pulls fixed 10 ms chunks from every input on the host clock, runs each
/// through its channel strip, sums them, limits the master, and hands the mix
/// to the sinks. The monitor gets the same mix, or with a custom monitor mix,
/// its own sum of the strips at the monitor's per-input gains. While
/// recording, the recorder gets its own sum without the inputs left out of the
/// recording; taking one in or out mid-recording fades rather than cuts.
final class AudioMixer: @unchecked Sendable {
    static let chunkFrames = 480

    // A class so the multi-second ring buffer is mutated in place rather
    // than copied out of and back into the dictionary.
    private final class Strip {
        var settings: AudioSource
        var buffer = DelayBuffer()
        var processor: ChannelStripProcessor
        var ducker = Ducker()
        var level = AudioLevel.silent
        /// Ramps toward the monitor gain so changes don't click.
        var monitorGain: Float = 1
        /// Ramps toward 1 or 0 as it's taken into or out of the recording.
        var recordingGain: Float

        init(_ settings: AudioSource) {
            self.settings = settings
            processor = ChannelStripProcessor(source: settings)
            recordingGain = settings.isInRecording ? 1 : 0
        }

        /// Microphones and interfaces: what "talking" means for ducking.
        var isVoice: Bool {
            if case .device = settings.kind { true } else { false }
        }
    }

    private let sinks: SinkHub
    private let queue = DispatchQueue(label: "parallax.mixer", qos: .userInteractive)
    private let lock = NSLock()
    private var strips: [UUID: Strip] = [:]
    private var pullSources: [UUID: AudioPullSource] = [:]
    private var monitor: MediaSink?
    /// Per-input monitor gains; nil plays the program mix to the monitor.
    private var monitorGains: [UUID: Float]?

    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var startTime: Double = 0
    private var framesProduced: Int64 = 0
    private var limiter = PeakLimiter()
    private var masterLevel = AudioLevel.silent
    private var lastLevelReport: Double = 0
    private var scratch = [Float](repeating: 0, count: AudioMixer.chunkFrames * 2)
    private var mix = [Float](repeating: 0, count: AudioMixer.chunkFrames * 2)
    private var monitorMix = [Float](repeating: 0, count: AudioMixer.chunkFrames * 2)
    private var monitorLimiter = PeakLimiter()
    private var recordingMix = [Float](repeating: 0, count: AudioMixer.chunkFrames * 2)
    private var recordingLimiter = PeakLimiter()
    private let monitorSmoothing = Float(1 - exp(-1 / (0.01 * AudioFormat.sampleRate)))

    /// Called on the main queue about 20 times a second.
    var onLevels: (@MainActor @Sendable (MixerLevels) -> Void)?

    init(sinks: SinkHub) {
        self.sinks = sinks
    }

    func configure(_ sources: [AudioSource]) {
        lock.withLock {
            let ids = Set(sources.map(\.id))
            strips = strips.filter { ids.contains($0.key) }
            for source in sources {
                let strip = strips[source.id] ?? Strip(source)
                strip.settings = source
                strip.processor.configure(source)
                strip.buffer.setDelay(frames: AudioFormat.frames(forMilliseconds: source.delayMs))
                strips[source.id] = strip
            }
        }
    }

    /// The monitor isn't a regular sink: it may hear a different mix.
    func setMonitor(_ sink: MediaSink?) {
        lock.withLock { monitor = sink }
    }

    /// `gains` nil plays the program mix to the monitor; otherwise each input
    /// at its stream level times its gain (missing inputs at 1).
    func setMonitorMix(_ gains: [UUID: Float]?) {
        lock.withLock { monitorGains = gains }
    }

    /// Makes `id` read from `source` instead of its queued audio.
    func attach(_ source: AudioPullSource, to id: UUID) {
        lock.withLock { pullSources[id] = source }
    }

    func detach(_ id: UUID) {
        lock.withLock { _ = pullSources.removeValue(forKey: id) }
    }

    /// Maps the device's channels to stereo per the source's channel mode and
    /// queues them. Called from capture queues.
    func write(_ pcm: AVAudioPCMBuffer, to id: UUID) {
        guard let channels = pcm.floatChannelData else { return }
        let frames = Int(pcm.frameLength)
        let count = Int(pcm.format.channelCount)
        lock.withLock {
            guard let strip = strips[id] else { return }
            let first = min(max(0, strip.settings.firstChannel), count - 1)
            let left = channels[first]
            let right = strip.settings.channelMode == .stereo && first + 1 < count ? channels[first + 1] : left
            var interleaved = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                interleaved[i * 2] = left[i]
                interleaved[i * 2 + 1] = right[i]
            }
            interleaved.withUnsafeBufferPointer { strip.buffer.write($0) }
        }
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            startTime = hostNow()
            framesProduced = 0
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .microseconds(500))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func tick() {
        let now = hostNow()
        let due = Int64((now - startTime) * AudioFormat.sampleRate)
        // After a long stall (sleep, debugger), resync rather than burst.
        if due - framesProduced > Int64(AudioFormat.sampleRate) {
            framesProduced = due - Int64(Self.chunkFrames)
        }
        while framesProduced + Int64(Self.chunkFrames) <= due {
            mixChunk()
        }
        if now - lastLevelReport >= 0.05 {
            lastLevelReport = now
            reportLevels()
        }
    }

    /// Mixes and delivers the next 10 ms. Runs on `queue` (or a test's thread
    /// when the mixer isn't started).
    func mixChunk() {
        let n = Self.chunkFrames
        for i in mix.indices { mix[i] = 0 }
        for i in monitorMix.indices { monitorMix[i] = 0 }
        for i in recordingMix.indices { recordingMix[i] = 0 }
        let (programSinks, recordingSinks) = sinks.byFeed
        let recording = !recordingSinks.isEmpty
        let (monitor, monitorIsProgram) = lock.withLock { () -> (MediaSink?, Bool) in
            // Microphones first, so everything else can duck under them in
            // the same chunk.
            var voiceDB = AudioLevel.silent.rmsDB
            for (id, strip) in strips where strip.isVoice {
                let level = mixStrip(id, strip, frames: n, voiceDB: nil, recording: recording)
                if !strip.settings.isMuted { voiceDB = max(voiceDB, level.rmsDB) }
            }
            for (id, strip) in strips where !strip.isVoice {
                mixStrip(id, strip, frames: n, voiceDB: voiceDB, recording: recording)
            }
            // Once every gain has ramped back to 1, hear the program itself.
            let isProgram = monitorGains == nil && strips.values.allSatisfy { $0.monitorGain == 1 }
            return (self.monitor, isProgram)
        }
        mix.withUnsafeMutableBufferPointer { buf in
            limiter.process(buf)
            masterLevel = masterLevel.merged(with: AudioLevel.measure(UnsafeBufferPointer(buf)))
        }
        if monitor != nil && !monitorIsProgram {
            monitorMix.withUnsafeMutableBufferPointer { monitorLimiter.process($0) }
        }
        if recording {
            recordingMix.withUnsafeMutableBufferPointer { recordingLimiter.process($0) }
        }

        let pts = CMTime(hostSeconds: startTime) + CMTime(value: framesProduced, timescale: CMTimeScale(AudioFormat.sampleRate))
        framesProduced += Int64(n)
        mix.withUnsafeBufferPointer { buf in
            for sink in programSinks { sink.appendAudio(buf, frameCount: n, pts: pts) }
        }
        recordingMix.withUnsafeBufferPointer { buf in
            for sink in recordingSinks { sink.appendAudio(buf, frameCount: n, pts: pts) }
        }
        if let monitor {
            (monitorIsProgram ? mix : monitorMix).withUnsafeBufferPointer {
                monitor.appendAudio($0, frameCount: n, pts: pts)
            }
        }
    }

    /// Reads, processes, and adds one strip to the mix. Call with `lock` held.
    @discardableResult
    private func mixStrip(_ id: UUID, _ strip: Strip, frames n: Int, voiceDB: Float?, recording: Bool) -> AudioLevel {
        let level = scratch.withUnsafeMutableBufferPointer { buf in
            if let source = pullSources[id] {
                source.render(into: buf, frames: n)
            } else {
                strip.buffer.read(into: buf, frames: n)
            }
            if let voiceDB { strip.ducker.process(buf, keyDB: voiceDB, settings: strip.settings.duck) }
            return strip.processor.process(buf)
        }
        strip.level = strip.level.merged(with: level)
        for i in mix.indices { mix[i] += scratch[i] }
        let recordingTarget: Float = strip.settings.isInRecording ? 1 : 0
        strip.recordingGain = recording
            ? Self.add(scratch, to: &recordingMix, gain: strip.recordingGain, toward: recordingTarget, smoothing: monitorSmoothing)
            : recordingTarget

        // The monitor bus follows the strip's gain toward its target, and
        // ramps back to 1 when the monitor returns to the program mix.
        let target = monitorGains.map { $0[id] ?? 1 } ?? 1
        strip.monitorGain = Self.add(scratch, to: &monitorMix, gain: strip.monitorGain, toward: target, smoothing: monitorSmoothing)
        return level
    }

    /// Adds `samples` to `bus` at `gain`, easing it toward `target` so a
    /// change doesn't click. Returns where the gain ended up.
    private static func add(_ samples: [Float], to bus: inout [Float], gain: Float, toward target: Float, smoothing: Float) -> Float {
        var gain = gain
        if gain == target {
            if gain != 0 { for i in bus.indices { bus[i] += samples[i] * gain } }
            return gain
        }
        var i = 0
        while i + 1 < bus.count {
            gain += (target - gain) * smoothing
            bus[i] += samples[i] * gain
            bus[i + 1] += samples[i + 1] * gain
            i += 2
        }
        return abs(target - gain) < 1e-4 ? target : gain
    }

    private func reportLevels() {
        let inputs = lock.withLock { () -> [UUID: AudioLevel] in
            var out: [UUID: AudioLevel] = [:]
            for (id, strip) in strips {
                out[id] = strip.level
                strip.level = .silent
            }
            return out
        }
        let levels = MixerLevels(inputs: inputs, master: masterLevel)
        masterLevel = .silent
        guard let onLevels else { return }
        DispatchQueue.main.async { onLevels(levels) }
    }
}
