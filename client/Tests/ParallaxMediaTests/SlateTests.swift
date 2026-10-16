import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ParallaxMedia

@Suite struct SlateTests {
    @Test(arguments: [(1920, 1080), (1280, 720), (1080, 1920)])
    func drawsAPNGAtTheStreamSize(width: Int, height: Int) throws {
        let data = try Slate.pngData(width: width, height: height)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == width && image.height == height)
    }

    @Test func rejectsAnEmptySize() {
        #expect(throws: Slate.Failure.self) { try Slate.pngData(width: 0, height: 720) }
    }
}
