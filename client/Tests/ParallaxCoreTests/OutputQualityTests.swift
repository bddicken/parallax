import Foundation
import Testing
@testable import ParallaxCore

@Suite struct OutputQualityTests {
    let uhd = OutputSettings(width: 3840, height: 2160, fps: 30)

    @Test func downscalesKeepingAspectAndEvenWidth() {
        #expect(OutputResolution.p1080.size(for: uhd) == (1920, 1080))
        #expect(OutputResolution.canvas.size(for: uhd) == (3840, 2160))
        let ultrawide = OutputSettings(width: 3440, height: 1440, fps: 30)
        let w = OutputResolution.p1080.size(for: ultrawide)
        #expect(w.height == 1080 && w.width % 2 == 0 && abs(Double(w.width) / 1080 - 3440.0 / 1440) < 0.01)
    }

    @Test func neverUpscales() {
        let hd = OutputSettings(width: 1920, height: 1080, fps: 30)
        #expect(OutputResolution.p2160.size(for: hd) == (1920, 1080))
        #expect(!OutputResolution.p2160.isAvailable(for: hd))
        #expect(!OutputResolution.p1080.isAvailable(for: hd))
        #expect(OutputResolution.p720.isAvailable(for: hd))
    }

    @Test func recommendedBitratesScaleWithSizeFpsAndCodec() {
        #expect(Bitrates.recording(height: 2160, fps: 30, codec: .h264) == 60_000)
        #expect(Bitrates.recording(height: 2160, fps: 30, codec: .hevc) < 60_000)
        #expect(Bitrates.recording(height: 1080, fps: 60, codec: .h264) > Bitrates.recording(height: 1080, fps: 30, codec: .h264))
        #expect(Bitrates.streaming(height: 1080, fps: 30) == 6_000)
        #expect(abs(Bitrates.gigabytesPerHour(videoKbps: 50_000, audioKbps: 0) - 22.5) < 0.01)
    }

    @Test func turningRecordingOutputsOnAndOff() {
        var r = RecordingSettings()
        r.outputs[0].videoBitrateKbps = 40_000
        let camera = UUID(), screen = UUID()
        r.setRecording(camera, true)
        r.setRecording(screen, true)
        r.setRecording(camera, true)
        #expect(r.outputs.map(\.sceneID) == [nil, camera, screen], "no duplicates, in the order turned on")
        #expect(r.output(for: screen)?.videoBitrateKbps == 40_000, "starts at the program's settings")
        r.setRecording(nil, false)
        r.setRecording(nil, true)
        #expect(r.outputs.first?.isProgram == true, "the program stays first")
        r.setRecording(camera, false)
        #expect(r.output(for: camera) == nil)
    }

    @Test func recordingFileNames() {
        #expect(RecordingSettings.fileNames(stamp: "S", scenes: [nil]) == ["Parallax S"])
        #expect(RecordingSettings.fileNames(stamp: "S", scenes: [nil, "Camera", "Screen: Left/Right", "Camera", " "])
            == ["Parallax S - Program", "Parallax S - Camera", "Parallax S - Screen- Left-Right", "Parallax S - Camera 2", "Parallax S - Scene"])
        #expect(RecordingSettings.fileNames(stamp: "S", scenes: ["Camera"]) == ["Parallax S - Camera"])
    }

    @Test func olderSettingsDecodeWithNewDefaults() throws {
        let recording = #"{"directoryPath":"/tmp/x","codec":"hevc","container":"mov","videoBitrateKbps":20000,"audioBitrateKbps":256}"#
        let r = try JSONDecoder().decode(RecordingSettings.self, from: Data(recording.utf8))
        #expect(r.outputs == [RecordingOutput(resolution: .canvas, videoBitrateKbps: 20_000)] && r.codec == .hevc)
        let scaled = #"{"resolution":"p1080","videoBitrateKbps":30000}"#
        #expect(try JSONDecoder().decode(RecordingSettings.self, from: Data(scaled.utf8)).outputs
            == [RecordingOutput(resolution: .p1080, videoBitrateKbps: 30_000)], "old settings become the program output")
        var many = RecordingSettings()
        many.outputs = [RecordingOutput(sceneID: UUID(), resolution: .p720)]
        let roundTrip = try JSONDecoder().decode(RecordingSettings.self, from: JSONEncoder().encode(many))
        #expect(roundTrip == many, "no outputs from new settings are mistaken for old ones")
        let broadcast = #"{"serverURL":"","uplinkVideoBitrateKbps":8000}"#
        let b = try JSONDecoder().decode(BroadcastSettings.self, from: Data(broadcast.utf8))
        #expect(b.stream == StreamSettings())
        #expect(!b.useMockServer, "mock chat is off unless turned on")
        #expect(b.serverMode == .local, "no server set up, so use the built-in one")
        let remote = #"{"serverURL":"https://relay.example.com"}"#
        #expect(try JSONDecoder().decode(BroadcastSettings.self, from: Data(remote.utf8)).serverMode == .remote,
                "keeps a server set up before the built-in one existed")
    }
}
