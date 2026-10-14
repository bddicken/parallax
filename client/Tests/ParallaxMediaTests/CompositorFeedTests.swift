import CoreImage
import CoreMedia
import Foundation
import ParallaxCore
import Testing
@testable import ParallaxMedia

@Suite struct CompositorFeedTests {
    /// Keeps the last frame it was handed.
    private final class Capture: MediaSink, @unchecked Sendable {
        private let lock = NSLock()
        private var frame: CVPixelBuffer?
        var last: CVPixelBuffer? { lock.withLock { frame } }
        func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) { lock.withLock { frame = pixelBuffer } }
        func appendAudio(_ samples: UnsafeBufferPointer<Float>, frameCount: Int, pts: CMTime) {}
    }

    @Test func recordingFeedLeavesOutSourcesNotInTheRecording() async throws {
        let registry = SourceRegistry(), sinks = SinkHub()
        let blue = UUID(), red = UUID()
        registry[blue] = StaticImageNode(image: CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)))
        registry[red] = StaticImageNode(image: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)))
        let scene = StudioScene(name: "Main", items: [
            SceneItem(sourceID: blue, contentMode: .stretch),
            SceneItem(sourceID: red, frame: LayoutPreset.rightHalf.rect, contentMode: .stretch),
        ])
        let program = Capture(), recording = Capture()
        sinks.add(program)
        sinks.add(recording, feed: .recording)

        let compositor = Compositor(registry: registry, sinks: sinks)
        compositor.update(scenes: [scene], output: OutputSettings(width: 320, height: 180, fps: 30), notRecorded: [red])
        compositor.setProgram(scene.id, transition: TransitionSettings(kind: .cut))
        compositor.start()
        defer { compositor.stop() }
        try await Task.sleep(for: .milliseconds(200))

        let programFrame = try #require(program.last), recordingFrame = try #require(recording.last)
        #expect(try pixel(programFrame, x: 0.75, y: 0.5) == (r: 255, g: 0, b: 0))
        #expect(try pixel(recordingFrame, x: 0.75, y: 0.5) == (r: 0, g: 0, b: 255))
        // Everything else is the same in both.
        #expect(try pixel(recordingFrame, x: 0.25, y: 0.5) == (r: 0, g: 0, b: 255))
    }

    @Test func recordingSharesTheProgramFrameWhenNothingIsLeftOut() async throws {
        let registry = SourceRegistry(), sinks = SinkHub()
        let blue = UUID(), red = UUID()
        registry[blue] = StaticImageNode(image: CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)))
        let scene = StudioScene(name: "Main", items: [SceneItem(sourceID: blue, contentMode: .stretch)])
        let program = Capture(), recording = Capture()
        sinks.add(program)
        sinks.add(recording, feed: .recording)

        // `red` is left out of the recording but isn't in the scene.
        let compositor = Compositor(registry: registry, sinks: sinks)
        compositor.update(scenes: [scene], output: OutputSettings(width: 320, height: 180, fps: 30), notRecorded: [red])
        compositor.setProgram(scene.id, transition: TransitionSettings(kind: .cut))
        compositor.start()
        defer { compositor.stop() }
        try await Task.sleep(for: .milliseconds(200))

        let programFrame = try #require(program.last), recordingFrame = try #require(recording.last)
        #expect(programFrame === recordingFrame)
    }

    private func pixel(_ buffer: CVPixelBuffer, x: Double, y: Double) throws -> (r: Int, g: Int, b: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let px = Int(x * Double(CVPixelBufferGetWidth(buffer))), py = Int(y * Double(CVPixelBufferGetHeight(buffer)))
        let p = base + py * CVPixelBufferGetBytesPerRow(buffer) + px * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]))  // BGRA
    }
}
