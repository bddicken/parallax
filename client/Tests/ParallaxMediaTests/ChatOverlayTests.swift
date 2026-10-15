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

    /// All messages share one box that fills the feed's frame: down its
    /// right edge (clear of text) the background is unbroken from bottom to
    /// top, and the messages sit at the bottom.
    @Test func messagesShareOneBoxTheSizeOfTheFeed() throws {
        let size = CGSize(width: 500, height: 990)
        let image = try render(ChatOverlayRenderer.feed(lines, size: size), size: size)
        if let path = ProcessInfo.processInfo.environment["PARALLAX_CHAT_PREVIEW"] { try save(image, to: path) }

        let x = Int(size.width) - 4
        // Skip the rounded corners at the top and bottom.
        #expect((16..<(Int(size.height) - 16)).allSatisfy { (140...170).contains(alpha(image, x: x, y: $0)) },
                "one semi-transparent box, no gaps")
        // Text (opaque) near the bottom, none near the top.
        let opaque = { (y: Int) in (0..<Int(size.width)).contains { alpha(image, x: $0, y: y) == 255 } }
        #expect((Int(size.height) - 200..<Int(size.height)).contains { opaque($0) })
        #expect(!(0..<200).contains { opaque($0) })
    }

    @Test func showsTheBoxBeforeAnyChat() throws {
        let size = CGSize(width: 500, height: 990)
        let image = try render(ChatOverlayRenderer.feed([], size: size), size: size)
        #expect(stride(from: 20, to: Int(size.height) - 20, by: 10).allSatisfy { (140...170).contains(alpha(image, x: 250, y: $0)) })
    }

    /// A new message slides in: the first frame is the feed as it was
    /// before it arrived, the last is the feed with it, and halfway the
    /// others are partway up.
    @Test func newMessageSlidesIn() throws {
        let size = CGSize(width: 500, height: 300)
        let many = (0..<6).map { ChatOverlayLine(author: "user\($0)", text: "message \($0)", accent: RGBAColor(red: 1, green: 1, blue: 1)) }
        let layers = ChatOverlayRenderer.feedLayers(many, arriving: 1, size: size)
        #expect(layers.shift > 30)

        let before = try render(ChatOverlayRenderer.feed(Array(many.dropLast()), size: size), size: size)
        let after = try render(ChatOverlayRenderer.feed(many, size: size), size: size)
        #expect(differing(try render(layers.frame(progress: 0), size: size), before) < 0.002)
        #expect(differing(try render(layers.frame(progress: 1), size: size), after) < 0.002)
        let middle = try render(layers.frame(progress: 0.5), size: size)
        #expect(differing(middle, before) > 0.01 && differing(middle, after) > 0.01)
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

    /// The share of pixels that differ noticeably between two images.
    private func differing(_ a: CGImage, _ b: CGImage) -> Double {
        let (pa, pb) = (pixels(a), pixels(b))
        var count = 0
        for i in stride(from: 0, to: pa.count, by: 4) where (0..<4).contains(where: { abs(Int(pa[i + $0]) - Int(pb[i + $0])) > 24 }) {
            count += 1
        }
        return Double(count) / Double(pa.count / 4)
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
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
