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

    @Test func drawsDropShadowBelowItem() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "parallax-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        var profile = Profile.makeDefault()
        profile.output = OutputSettings(width: 1280, height: 720, fps: 30)
        let white = VideoSource(name: "White", kind: .color(RGBAColor(red: 1, green: 1, blue: 1)))
        let red = VideoSource(name: "Red", kind: .color(RGBAColor(red: 1, green: 0, blue: 0)))
        profile.videoSources = [white, red]
        let pip = NormalizedRect(x: 0.3, y: 0.2, width: 0.3, height: 0.3)
        profile.scenes[0].items = [
            SceneItem(sourceID: white.id, contentMode: .stretch),
            SceneItem(sourceID: red.id, frame: pip, contentMode: .stretch,
                      shadow: ItemShadow(isEnabled: true, distance: 40, angle: 90, blur: 4, opacity: 0.8)),
        ]
        profile.recording = RecordingSettings(directoryPath: dir.path)

        let engine = MediaEngine()
        engine.apply(profile)
        engine.setProgram(profile.programSceneID, transition: TransitionSettings(kind: .cut))
        try await Task.sleep(for: .milliseconds(200))
        _ = try engine.startRecording(profile.recording)
        try await Task.sleep(for: .seconds(1))
        let url = try await engine.stopRecording()

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let frame = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image

        // 40px at 1080p is ~27px at 720p: just below the PiP should be shadowed,
        // at about 80% black over white (sRGB ~51).
        let below = try pixel(frame, x: 0.45, y: 0.5 + 12.0 / 720)
        #expect(below.r < 75 && below.g < 75 && below.b < 75)
        // No shadow to the left, since it falls straight down.
        let left = try pixel(frame, x: 0.3 - 6.0 / 1280, y: 0.35)
        #expect(left.r > 230 && left.g > 230)
        // Above the PiP (shadow falls down) and far away stay white.
        let above = try pixel(frame, x: 0.45, y: 0.2 - 12.0 / 720)
        #expect(above.r > 230 && above.g > 230)
        let far = try pixel(frame, x: 0.9, y: 0.9)
        #expect(far.r > 230 && far.g > 230 && far.b > 230)
        // The item itself is unaffected.
        let inside = try pixel(frame, x: 0.45, y: 0.35)
        #expect(inside.r > 200 && inside.g < 60)
    }

    @Test func recordsAtAScaledDownResolution() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "parallax-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        var profile = Profile.makeDefault()
        profile.output = OutputSettings(width: 2560, height: 1440, fps: 30)
        let red = VideoSource(name: "Red", kind: .color(RGBAColor(red: 1, green: 0, blue: 0)))
        profile.videoSources = [red]
        profile.scenes[0].items = [SceneItem(sourceID: red.id, frame: LayoutPreset.leftHalf.rect, contentMode: .stretch)]
        profile.recording = RecordingSettings(directoryPath: dir.path)
        profile.recording.resolution = .p720

        let engine = MediaEngine()
        engine.apply(profile)
        engine.setProgram(profile.programSceneID, transition: TransitionSettings(kind: .cut))
        try await Task.sleep(for: .milliseconds(200))
        _ = try engine.startRecording(profile.recording)
        try await Task.sleep(for: .seconds(1))
        let url = try await engine.stopRecording()

        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 1280, height: 720))
        // Scaled, not cropped: the left half is still red, the right half black.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let frame = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let left = try pixel(frame, x: 0.45, y: 0.5), right = try pixel(frame, x: 0.55, y: 0.5)
        #expect(left.r > 200 && right.r < 30)
    }

    @Test(arguments: [VideoCodec.h264, .hevc])
    func records4KCanvas(codec: VideoCodec) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "parallax-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        var profile = Profile.makeDefault()
        profile.output = OutputSettings(width: 3840, height: 2160, fps: 30)
        let red = VideoSource(name: "Red", kind: .color(RGBAColor(red: 1, green: 0, blue: 0)))
        profile.videoSources = [red]
        profile.scenes[0].items = [SceneItem(sourceID: red.id, frame: LayoutPreset.pipTopRight.rect, contentMode: .stretch)]
        profile.recording = RecordingSettings(directoryPath: dir.path)
        profile.recording.codec = codec
        profile.recording.videoBitrateKbps = Bitrates.recording(height: 2160, fps: 30, codec: codec)

        let engine = MediaEngine()
        engine.apply(profile)
        engine.setProgram(profile.programSceneID, transition: TransitionSettings(kind: .cut))
        try await Task.sleep(for: .milliseconds(200))
        _ = try engine.startRecording(profile.recording)
        try await Task.sleep(for: .seconds(2))
        let url = try await engine.stopRecording()

        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 3840, height: 2160))
        #expect(try await asset.load(.duration).seconds > 1.5)
        let fps = try await video.load(.nominalFrameRate)
        #expect(fps > 25, "4K compositing/encoding kept up at \(fps) fps")
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
