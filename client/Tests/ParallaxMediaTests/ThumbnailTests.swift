import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ParallaxMedia

@Suite struct ThumbnailTests {
    @Test func scalesLargeImagesToAJPEGThatFits() throws {
        let url = try Self.writePNG(width: 3840, height: 2160)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Thumbnail.jpegData(contentsOf: url)

        #expect(data.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(data.count <= Thumbnail.maxBytes)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 1280)
        #expect(image.height == 720)
    }

    @Test func rejectsFilesThatArentImages() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: Thumbnail.Failure.self) { try Thumbnail.jpegData(contentsOf: url) }
    }

    private static func writePNG(width: Int, height: Int) throws -> URL {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}
