import AVFoundation
import Foundation
import ParallaxCore
import Testing
@testable import ParallaxMedia

/// Runs the real compositor → mixer → recorder path with sources that need
/// no permissions, then checks the file that comes out.
@MainActor
@Suite struct RecordingTests {
    @Test func recordsCompositedVideoAndAudio() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "parallax-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        var profile = Profile.makeDefault()
        profile.output = OutputSettings(width: 1280, height: 720, fps: 30)
        let color = VideoSource(name: "Red", kind: .color(RGBAColor(red: 1, green: 0, blue: 0)))
        profile.videoSources = [color]
        let green = RGBAColor(red: 0, green: 1, blue: 0)
        profile.scenes[0].items = [SceneItem(sourceID: color.id, frame: LayoutPreset.pipTopLeft.rect, contentMode: .stretch,
                                             cornerRadius: 0.5, border: ItemBorder(isEnabled: true, width: 12, color: green))]
        profile.recording = RecordingSettings(directoryPath: dir.path)

        let engine = MediaEngine()
        engine.apply(profile)
        engine.setProgram(profile.programSceneID, transition: TransitionSettings(kind: .cut))
        try await Task.sleep(for: .milliseconds(200))

        _ = try engine.startRecording(profile.recording)
        try await Task.sleep(for: .seconds(2))
        let url = try await engine.stopRecording()

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 1.5 && duration < 2.5)

        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 1280, height: 720))
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)

        // The PiP should be red with a green border and fully rounded
        // corners; the rest of the canvas black.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let inside = try pixel(frame, x: 0.1, y: 0.1)
        let outside = try pixel(frame, x: 0.7, y: 0.7)
        #expect(inside.r > 200 && inside.g < 60 && inside.b < 60)
        #expect(outside.r < 30 && outside.g < 30 && outside.b < 30)
        let topEdge = try pixel(frame, x: 0.15, y: 0.025 + 1.0 / 720)
        #expect(topEdge.g > 200 && topEdge.r < 60)
        let cornerOutsideRounding = try pixel(frame, x: 0.028, y: 0.03)
        #expect(cornerOutsideRounding.r < 30 && cornerOutsideRounding.g < 30)
    }

    private func pixel(_ image: CGImage, x: Double, y: Double) throws -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Draw so that the sample point lands on the single pixel (CG is bottom-left origin).
        let w = Double(image.width), h = Double(image.height)
        ctx.draw(image, in: CGRect(x: -x * w, y: -(1 - y) * h + 1, width: w, height: h))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
}
