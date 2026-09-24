import AVFoundation
import Foundation
import ParallaxCore

public struct MixerLevels: Sendable {
    public var inputs: [UUID: AudioLevel]
    public var master: AudioLevel
}

/// Pulls fixed 10 ms chunks from every input on the host clock, runs each
/// through its channel strip, sums them, limits the master, and hands the mix
/// to the sinks.
final class AudioMixer: @unchecked Sendable {
    static let chunkFrames = 480

    // A class so the multi-second ring buffer is mutated in place rather
    // than copied out of and back into the dictionary.
    private final class Strip {
        var settings: AudioSource
        var buffer = DelayBuffer()
        var processor: ChannelStripProcessor
        var level = AudioLevel.silent

        init(_ settings: AudioSource) {
            self.settings = settings
            processor = ChannelStripProcessor(source: settings)
        }
    }

    private let sinks: SinkHub
    private let queue = DispatchQueue(label: "parallax.mixer", qos: .userInteractive)
    private let lock = NSLock()
    private var strips: [UUID: Strip] = [:]

    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var startTime: Double = 0
    private var framesProduced: Int64 = 0
    private var limiter = PeakLimiter()
    private var masterLevel = AudioLevel.silent
    private var lastLevelReport: Double = 0
    private var scratch = [Float](repeating: 0, count: AudioMixer.chunkFrames * 2)
    private var mix = [Float](repeating: 0, count: AudioMixer.chunkFrames * 2)

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

    private func mixChunk() {
        let n = Self.chunkFrames
        for i in mix.indices { mix[i] = 0 }
        lock.withLock {
            for strip in strips.values {
                scratch.withUnsafeMutableBufferPointer { buf in
                    strip.buffer.read(into: buf, frames: n)
                    strip.level = strip.level.merged(with: strip.processor.process(buf))
                }
                for i in mix.indices { mix[i] += scratch[i] }
            }
        }
        mix.withUnsafeMutableBufferPointer { buf in
            limiter.process(buf)
            masterLevel = masterLevel.merged(with: AudioLevel.measure(UnsafeBufferPointer(buf)))
        }

        let pts = CMTime(hostSeconds: startTime) + CMTime(value: framesProduced, timescale: CMTimeScale(AudioFormat.sampleRate))
        framesProduced += Int64(n)
        let outputs = sinks.all
        mix.withUnsafeBufferPointer { buf in
            for sink in outputs { sink.appendAudio(buf, frameCount: n, pts: pts) }
        }
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
