import CoreVideo
import Testing
@testable import ParallaxMedia

@Suite struct VideoFrameBufferTests {
    private func makeBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }

    /// The compositor reads the clock, then asks for each source's frame. A
    /// capture landing in between is newer than the compositor's time and
    /// has already replaced the previous frame; that must not blank the source.
    @Test func frameArrivingMidRenderStillShows() {
        let frames = VideoFrameBuffer()
        let a = makeBuffer(), b = makeBuffer()
        frames.push(a, time: 1.000)
        frames.push(b, time: 1.034)
        #expect(frames.frame(at: 1.033) === b)
    }

    @Test func delayedSourceWaitsUntilAFrameIsOldEnough() {
        let frames = VideoFrameBuffer()
        frames.setDelay(seconds: 0.5)
        let a = makeBuffer(), b = makeBuffer()
        frames.push(a, time: 1.0)
        frames.push(b, time: 1.2)
        #expect(frames.frame(at: 1.3) == nil)
        #expect(frames.frame(at: 1.5) != nil)
    }

    /// Same race with a delay: the push dropped the frame the compositor's
    /// slightly earlier clock would have picked.
    @Test func delayedFrameArrivingMidRenderStillShows() {
        let frames = VideoFrameBuffer()
        frames.setDelay(seconds: 0.5)
        let a = makeBuffer(), b = makeBuffer(), c = makeBuffer()
        frames.push(a, time: 1.0)
        frames.push(b, time: 1.2)
        frames.push(c, time: 1.8)
        #expect(frames.frame(at: 1.69) != nil)
    }
}
