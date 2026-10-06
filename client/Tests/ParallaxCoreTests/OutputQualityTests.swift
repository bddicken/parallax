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

    @Test func olderSettingsDecodeWithNewDefaults() throws {
        let recording = #"{"directoryPath":"/tmp/x","codec":"hevc","container":"mov","videoBitrateKbps":20000,"audioBitrateKbps":256}"#
        let r = try JSONDecoder().decode(RecordingSettings.self, from: Data(recording.utf8))
        #expect(r.resolution == .canvas && r.codec == .hevc && r.videoBitrateKbps == 20_000)
        #expect(r.quality == .balanced, "older profiles move to the constant-quality default")
        let broadcast = #"{"serverURL":"","uplinkVideoBitrateKbps":8000}"#
        let b = try JSONDecoder().decode(BroadcastSettings.self, from: Data(broadcast.utf8))
        #expect(b.stream == StreamSettings())
        #expect(!b.useMockServer, "mock chat is off unless turned on")
        #expect(b.serverMode == .local, "no server set up, so use the built-in one")
        let remote = #"{"serverURL":"https://relay.example.com"}"#
        #expect(try JSONDecoder().decode(BroadcastSettings.self, from: Data(remote.utf8)).serverMode == .remote,
                "keeps a server set up before the built-in one existed")
    }

    @Test func qualityModesUseHEVCAtRisingQuality() throws {
        var r = RecordingSettings(directoryPath: "/tmp/x")
        r.codec = .h264
        #expect(r.effectiveCodec == .hevc)
        r.quality = .custom
        #expect(r.effectiveCodec == .h264)
        #expect(RecordingQuality.custom.encoderQuality == nil)
        #expect(RecordingQuality.custom.gigabytesPerHour(width: 3840, height: 2160, fps: 30, audioKbps: 256) == nil)

        let modes: [RecordingQuality] = [.small, .balanced, .high]
        let qualities = modes.compactMap(\.encoderQuality)
        #expect(qualities == qualities.sorted() && Set(qualities).count == 3 && qualities.allSatisfy { $0 > 0 && $0 < 1 })
        let sizes = try modes.map { try #require($0.gigabytesPerHour(width: 3840, height: 2160, fps: 30, audioKbps: 256)) }
        #expect(sizes.map(\.upperBound) == sizes.map(\.upperBound).sorted())
        // Two hours of 4K30 screen + camera at Balanced fits in 10 GB.
        #expect(sizes[1].upperBound * 2 <= 10.5)
        let hd = try #require(RecordingQuality.balanced.gigabytesPerHour(width: 1920, height: 1080, fps: 30, audioKbps: 256))
        let uhd60 = try #require(RecordingQuality.balanced.gigabytesPerHour(width: 3840, height: 2160, fps: 60, audioKbps: 256))
        #expect(hd.upperBound < sizes[1].upperBound && uhd60.upperBound > sizes[1].upperBound)
    }
}
