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
        let url = try await stopSingle(engine)

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
        let url = try await stopSingle(engine)

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
        profile.recording.outputs[0].resolution = .p720

        let engine = MediaEngine()
        engine.apply(profile)
        engine.setProgram(profile.programSceneID, transition: TransitionSettings(kind: .cut))
        try await Task.sleep(for: .milliseconds(200))
        _ = try engine.startRecording(profile.recording)
        try await Task.sleep(for: .seconds(1))
        let url = try await stopSingle(engine)

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
        profile.recording.outputs[0].videoBitrateKbps = Bitrates.recording(height: 2160, fps: 30, codec: codec)

        let engine = MediaEngine()
        engine.apply(profile)
        engine.setProgram(profile.programSceneID, transition: TransitionSettings(kind: .cut))
        try await Task.sleep(for: .milliseconds(200))
        _ = try engine.startRecording(profile.recording)
        try await Task.sleep(for: .seconds(2))
        let url = try await stopSingle(engine)

        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 3840, height: 2160))
        #expect(try await asset.load(.duration).seconds > 1.5)
        let fps = try await video.load(.nominalFrameRate)
        #expect(fps > 25, "4K compositing/encoding kept up at \(fps) fps")
    }

    /// Program plus two scenes on their own: three files that start and stop
    /// on the same frame and sample, carry the same timecode, and each show
    /// their own scene.
    @Test func recordsScenesToSeparateFilesInSync() async throws {
        let dir = ProcessInfo.processInfo.environment["PARALLAX_KEEP_TEST_RECORDINGS"].map { URL(filePath: $0) }
            ?? FileManager.default.temporaryDirectory.appending(path: "parallax-test-\(UUID().uuidString)")
        defer { if ProcessInfo.processInfo.environment["PARALLAX_KEEP_TEST_RECORDINGS"] == nil { try? FileManager.default.removeItem(at: dir) } }

        var profile = Profile.makeDefault()
        profile.output = OutputSettings(width: 1280, height: 720, fps: 30)
        let red = VideoSource(name: "Red", kind: .color(RGBAColor(red: 1, green: 0, blue: 0)))
        let blue = VideoSource(name: "Blue", kind: .color(RGBAColor(red: 0, green: 0, blue: 1)))
        profile.videoSources = [red, blue]
        profile.scenes[0].items = [SceneItem(sourceID: red.id, contentMode: .stretch)]
        profile.scenes[1].items = [SceneItem(sourceID: blue.id, contentMode: .stretch)]
        profile.scenes[1].name = "Screen"
        profile.recording = RecordingSettings(directoryPath: dir.path)
        profile.recording.setRecording(profile.scenes[0].id, true)
        profile.recording.setRecording(profile.scenes[1].id, true)
        profile.recording.outputs[2].resolution = .p720

        let engine = MediaEngine()
        engine.apply(profile)
        // "Be Right Back" (empty, so black) is live; the scene files ignore it.
        engine.setProgram(profile.scenes[2].id, transition: TransitionSettings(kind: .cut))
        try await Task.sleep(for: .milliseconds(200))
        let started = try engine.startRecording(profile.recording)
        #expect(started.map(\.lastPathComponent).map { $0.components(separatedBy: " - ").last } == ["Program.mov", "Main.mov", "Screen.mov"])
        try await Task.sleep(for: .seconds(1.5))
        let result = await engine.stopRecording()
        #expect(result.problems.isEmpty)
        #expect(result.urls == started)
        let files = result.urls.map { AVURLAsset(url: $0) }
        #expect(files.count == 3)

        // Same frames at the same times, and the same audio.
        var videoTimes: [[Chunk]] = [], audioTimes: [[Chunk]] = [], timecodes: [Int32] = []
        var colors: [(r: Int, g: Int, b: Int)] = []
        for asset in files {
            videoTimes.append(try await sampleTimes(asset, .video))
            audioTimes.append(try await sampleTimes(asset, .audio))
            timecodes.append(try await startTimecode(asset))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            colors.append(try pixel(try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image, x: 0.5, y: 0.5))
        }
        #expect(videoTimes[0].map(\.samples).reduce(0, +) > 30)
        #expect(videoTimes[1] == videoTimes[0] && videoTimes[2] == videoTimes[0])
        #expect(audioTimes[0].map(\.samples).reduce(0, +) > 50, "AAC packets")
        #expect(audioTimes[1] == audioTimes[0] && audioTimes[2] == audioTimes[0])

        // Matching time-of-day timecode, close to the wall clock.
        #expect(timecodes[1] == timecodes[0] && timecodes[2] == timecodes[0])
        let now = Date().timeIntervalSince(Calendar.current.startOfDay(for: Date()))
        #expect(abs(Double(timecodes[0]) / 30 - now) < 10)

        // Each file shows its own scene.
        #expect(colors[0].r < 30 && colors[0].b < 30, "program: the empty live scene")
        #expect(colors[1].r > 200 && colors[1].b < 60, "Main: red")
        #expect(colors[2].b > 200 && colors[2].r < 60, "Screen: blue")
    }

    /// A file that fails mid-take keeps what it had, and recording carries
    /// on in a new part rather than losing the rest of the take.
    @Test func continuesInANewPartAfterAWriteFailure() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "parallax-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        var profile = Profile.makeDefault()
        profile.output = OutputSettings(width: 640, height: 360, fps: 30)
        let red = VideoSource(name: "Red", kind: .color(RGBAColor(red: 1, green: 0, blue: 0)))
        profile.videoSources = [red]
        profile.scenes[0].items = [SceneItem(sourceID: red.id, contentMode: .stretch)]
        profile.recording = RecordingSettings(directoryPath: dir.path)

        let engine = MediaEngine()
        var issues: [String] = []
        engine.onRecordingIssue = { issues.append($0) }
        engine.apply(profile)
        engine.setProgram(profile.programSceneID, transition: TransitionSettings(kind: .cut))
        try await Task.sleep(for: .milliseconds(200))
        _ = try engine.startRecording(profile.recording)
        try await Task.sleep(for: .seconds(3))

        // A frame from the past makes the writer fail, as an encoder reset would.
        let first = try #require(engine.activeRecorders.first)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer)
        first.appendVideo(try #require(buffer), pts: .zero)
        try await Task.sleep(for: .seconds(1))
        #expect(issues.count == 1)
        #expect(issues.first?.contains("part 2") == true)
        #expect(engine.activeRecorders.first !== first)

        let result = await engine.stopRecording()
        #expect(result.urls.map(\.lastPathComponent) == [first.url.lastPathComponent,
                                                         first.url.deletingPathExtension().lastPathComponent + " (part 2).mov"])
        #expect(result.problems.count == 1)
        // Part 1 keeps what was written before the failure, less at most one
        // fragment; part 2 has the rest.
        let durations = try await [AVURLAsset(url: result.urls[0]).load(.duration).seconds,
                                   AVURLAsset(url: result.urls[1]).load(.duration).seconds]
        #expect(durations[0] > 1.5 && durations[0] < 3.5, "part 1: \(durations[0]) s")
        #expect(durations[1] > 0.5 && durations[1] < 1.5, "part 2: \(durations[1]) s")
    }

    @Test func refusesToRecordNothing() throws {
        var settings = RecordingSettings(directoryPath: FileManager.default.temporaryDirectory.path)
        settings.outputs = []
        let engine = MediaEngine()
        engine.apply(Profile.makeDefault())
        #expect(throws: MediaError.self) { try engine.startRecording(settings) }
        #expect(!engine.isRecording)
    }

    private func stopSingle(_ engine: MediaEngine) async throws -> URL {
        let result = await engine.stopRecording()
        #expect(result.problems.isEmpty)
        return try #require(result.urls.first)
    }

    /// A run of samples as read back from a file.
    private struct Chunk: Equatable {
        var time: CMTime
        var samples: Int
    }

    /// Where every sample in the file's track sits, as stored.
    private func sampleTimes(_ asset: AVAsset, _ type: AVMediaType) async throws -> [Chunk] {
        let track = try #require(try await asset.loadTracks(withMediaType: type).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var times: [Chunk] = []
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            if count > 0 { times.append(Chunk(time: CMSampleBufferGetPresentationTimeStamp(sample), samples: count)) }
        }
        return times
    }

    /// The frame number in the file's timecode track.
    private func startTimecode(_ asset: AVAsset) async throws -> Int32 {
        let track = try #require(try await asset.loadTracks(withMediaType: .timecode).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var block: CMBlockBuffer?
        while block == nil, let sample = output.copyNextSampleBuffer() { block = CMSampleBufferGetDataBuffer(sample) }
        let data = try #require(block)
        var frame: Int32 = 0
        #expect(CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: 4, destination: &frame) == noErr)
        return Int32(bigEndian: frame)
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

