import CoreImage
import Foundation
import ImageIO
import ParallaxCore
import Testing
import UniformTypeIdentifiers
@testable import ParallaxMedia

@MainActor
@Suite struct ChatOverlayTests {
    private let lines = [
        ChatOverlayLine(author: "alice", text: "First!", accent: RGBAColor(red: 0.6, green: 0.4, blue: 1)),
        ChatOverlayLine(author: "bob", text: "This one is long enough that it wraps onto a second line in the feed.",
                        accent: RGBAColor(red: 1, green: 0.3, blue: 0.3)),
        ChatOverlayLine(author: "carol", text: "hi from YouTube", accent: RGBAColor(red: 1, green: 0.2, blue: 0.2)),
    ]

    /// All messages share one box: down its right edge (clear of text) the
    /// background is unbroken from the bottom to the box's top, and clear above.
    @Test func messagesShareOneBox() throws {
        let size = CGSize(width: 500, height: 990)
        let image = try render(ChatOverlayRenderer.feed(lines, size: size), size: size)
        if let path = ProcessInfo.processInfo.environment["PARALLAX_CHAT_PREVIEW"] { try save(image, to: path) }

        let x = Int(size.width) - 4
        // Rows from the bottom of the image up (CGImage rows run top-down).
        let column = (0..<Int(size.height)).map { alpha(image, x: x, y: Int(size.height) - 1 - $0) }
        // Skip the rounded corner at the bottom.
        let top = try #require(column.lastIndex { $0 > 0 })
        #expect(top > 100 && top < 600, "the box fits the messages, not the whole feed")
        #expect(column[16...(top - 16)].allSatisfy { $0 > 100 && $0 < 200 }, "one semi-transparent box, no gaps")
        #expect(column[(top + 1)...].allSatisfy { $0 == 0 })
    }

    @Test func noChatNoBox() throws {
        let size = CGSize(width: 500, height: 990)
        let image = try render(ChatOverlayRenderer.feed([], size: size), size: size)
        #expect(stride(from: 0, to: Int(size.height), by: 10).allSatisfy { alpha(image, x: 250, y: $0) == 0 })
    }

    private func render(_ image: CIImage, size: CGSize) throws -> CGImage {
        try #require(CIContext().createCGImage(image, from: CGRect(origin: .zero, size: size)))
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) -> Int {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Int(data[3])
    }

    /// The feed over a mid-gray background, to look at.
    private func save(_ image: CGImage, to path: String) throws {
        let ctx = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.35, green: 0.45, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let dest = try #require(CGImageDestinationCreateWithURL(URL(filePath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
