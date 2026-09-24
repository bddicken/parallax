import AVFoundation
import CoreAudio
import Foundation
import ParallaxCore

/// Plays the program mix to an output device so the host can hear it.
///
/// The mixer pushes 10 ms chunks on its own clock; the output device pulls
/// on its clock. A small `DelayBuffer` sits between them to absorb jitter
/// and drift, keeping monitor latency around 20–60 ms.
final class AudioMonitor: MediaSink, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let lock = NSLock()
    private var buffer = DelayBuffer(
        capacity: AudioFormat.frames(forMilliseconds: 500),
        prebufferFrames: AudioFormat.frames(forMilliseconds: 20),
        maxDriftFrames: AudioFormat.frames(forMilliseconds: 40))
    private let scratchFrames = 8192
    private let scratch: UnsafeMutablePointer<Float>

    /// `deviceID` nil plays to the system default output. `offline` renders
    /// into memory instead of a device (for tests).
    init(deviceID: AudioDeviceID?, volume: Double, offline: Bool = false) throws {
        scratch = .allocate(capacity: scratchFrames * 2)
        scratch.initialize(repeating: 0, count: scratchFrames * 2)

        let format = AVAudioFormat(standardFormatWithSampleRate: AudioFormat.sampleRate, channels: 2)!
        if offline {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        } else if let deviceID {
            guard let unit = engine.outputNode.audioUnit else { throw MediaError("No audio output unit.") }
            var id = deviceID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw MediaError("Couldn't use that output device (\(status)).") }
        }

        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            self.render(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(bufferList))
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        // The main mixer converts to the device's sample rate.
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = Float(volume)
        engine.prepare()
        try engine.start()
    }

    deinit {
        engine.stop()
        scratch.deallocate()
    }

    var isRunning: Bool { engine.isRunning }

    /// Pulls `frames` of output in offline mode; returns the left channel.
    func renderOffline(frames: Int) throws -> [Float] {
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(frames))!
        _ = try engine.renderOffline(AVAudioFrameCount(frames), to: out)
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    func setVolume(_ volume: Double) {
        engine.mainMixerNode.outputVolume = Float(min(1, max(0, volume)))
    }

    func stop() {
        engine.stop()
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {}

    func appendAudio(_ samples: UnsafeBufferPointer<Float>, frameCount: Int, pts: CMTime) {
        lock.withLock { buffer.write(samples) }
    }

    /// Runs on the audio device's real-time thread.
    private func render(frames: Int, into list: UnsafeMutableAudioBufferListPointer) {
        let n = min(frames, scratchFrames)
        lock.withLock {
            _ = buffer.read(into: UnsafeMutableBufferPointer(start: scratch, count: n * 2), frames: n)
        }
        guard list.count >= 2,
              let left = list[0].mData?.assumingMemoryBound(to: Float.self),
              let right = list[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        for i in 0..<n {
            left[i] = scratch[i * 2]
            right[i] = scratch[i * 2 + 1]
        }
        for i in n..<frames {
            left[i] = 0
            right[i] = 0
        }
    }
}
