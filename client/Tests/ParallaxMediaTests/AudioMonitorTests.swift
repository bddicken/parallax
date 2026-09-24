import CoreMedia
import Foundation
import ParallaxCore
import Testing
@testable import ParallaxMedia

@Suite struct AudioMonitorTests {
    private func push(_ monitor: AudioMonitor, value: Float, ms: Int) {
        let frames = AudioFormat.frames(forMilliseconds: ms)
        let samples = [Float](repeating: value, count: frames * 2)
        samples.withUnsafeBufferPointer { monitor.appendAudio($0, frameCount: frames, pts: .zero) }
    }

    @Test func playsProgramAudioAtMonitorVolume() throws {
        let monitor = try AudioMonitor(deviceID: nil, volume: 0.5, offline: true)
        // Feed it the way the mixer does: 10 ms at a time, device pulling 10 ms.
        push(monitor, value: 0.8, ms: 30)
        var out: [Float] = []
        for _ in 0..<10 {
            push(monitor, value: 0.8, ms: 10)
            out = try monitor.renderOffline(frames: 480)
        }
        #expect(out.allSatisfy { abs($0 - 0.4) < 0.01 })

        // Volume changes ramp briefly (no clicks), so check after the ramp.
        monitor.setVolume(0)
        var muted: [Float] = []
        for _ in 0..<3 {
            push(monitor, value: 0.8, ms: 10)
            muted = try monitor.renderOffline(frames: 480)
        }
        #expect(muted.allSatisfy { abs($0) < 0.001 })
    }

    @Test func outputsSilenceUntilAudioArrives() throws {
        let monitor = try AudioMonitor(deviceID: nil, volume: 1, offline: true)
        let out = try monitor.renderOffline(frames: 512)
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test func listsOutputDevicesWithStableIDs() {
        let devices = CoreAudioOutputs.all()
        #expect(Set(devices.map(\.id)).count == devices.count)
        if let defaultID = CoreAudioOutputs.defaultOutput() {
            #expect(devices.contains { $0.deviceID == defaultID })
        }
    }
}
