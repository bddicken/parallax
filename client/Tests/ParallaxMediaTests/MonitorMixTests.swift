import AVFoundation
import CoreMedia
import Foundation
import ParallaxCore
import Testing
@testable import ParallaxMedia

@Suite struct MonitorMixTests {
    /// Keeps the last chunk it was handed.
    private final class Capture: MediaSink, @unchecked Sendable {
        var last: [Float] = []
        func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {}
        func appendAudio(_ samples: UnsafeBufferPointer<Float>, frameCount: Int, pts: CMTime) { last = Array(samples) }
    }

    private let mic = AudioSource(name: "Mic", kind: .device(uniqueID: "mic"))
    private let music = AudioSource(name: "Music", kind: .systemAudio)

    private func makeMixer() -> (AudioMixer, program: Capture, monitor: Capture) {
        let sinks = SinkHub()
        let program = Capture(), monitor = Capture()
        sinks.add(program)
        let mixer = AudioMixer(sinks: sinks)
        mixer.configure([mic, music])
        mixer.setMonitor(monitor)
        return (mixer, program, monitor)
    }

    /// Writes 10 ms of a constant to each input, then mixes it.
    private func mix(_ mixer: AudioMixer, mic micValue: Float, music musicValue: Float, chunks: Int = 1) {
        let format = AVAudioFormat(standardFormatWithSampleRate: AudioFormat.sampleRate, channels: 1)!
        for _ in 0..<chunks {
            for (id, value) in [(mic.id, micValue), (music.id, musicValue)] {
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(AudioMixer.chunkFrames))!
                pcm.frameLength = pcm.frameCapacity
                for i in 0..<AudioMixer.chunkFrames { pcm.floatChannelData![0][i] = value }
                mixer.write(pcm, to: id)
            }
            mixer.mixChunk()
        }
    }

    @Test func monitorHearsTheProgramByDefault() {
        let (mixer, program, monitor) = makeMixer()
        mix(mixer, mic: 0.1, music: 0.2, chunks: 5)
        #expect(program.last.allSatisfy { abs($0 - 0.3) < 0.001 })
        #expect(monitor.last == program.last)
    }

    @Test func customMixDropsTheMicFromTheMonitorOnly() {
        let (mixer, program, monitor) = makeMixer()
        mixer.setMonitorMix([mic.id: 0, music.id: 0.5])
        // Let the gains ramp down.
        mix(mixer, mic: 0.1, music: 0.2, chunks: 20)
        #expect(program.last.allSatisfy { abs($0 - 0.3) < 0.001 })
        #expect(monitor.last.allSatisfy { abs($0 - 0.1) < 0.001 })

        // Back to the program: ramps up, then plays the program itself.
        mixer.setMonitorMix(nil)
        mix(mixer, mic: 0.1, music: 0.2, chunks: 20)
        #expect(monitor.last == program.last)
    }
}
