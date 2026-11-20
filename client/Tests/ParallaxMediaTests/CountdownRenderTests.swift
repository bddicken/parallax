import CoreImage
import Foundation
import ImageIO
import ParallaxCore
import Testing
import UniformTypeIdentifiers
@testable import ParallaxMedia

@Suite struct CountdownRenderTests {
    /// Set PARALLAX_COUNTDOWN_PREVIEW to a folder to save each theme as a PNG.
    @Test(arguments: CountdownTheme.allCases)
    func drawsEachThemeAtTheCanvasSize(theme: CountdownTheme) throws {
        let size = CGSize(width: 1920, height: 1080)
        let settings = CountdownSettings(theme: theme)
        let image = try render(CountdownRenderer.image(settings, clock: "4:59", size: size), size: size)
        #expect(image.width == 1920 && image.height == 1080)
        if let folder = ProcessInfo.processInfo.environment["PARALLAX_COUNTDOWN_PREVIEW"] {
            try save(image, to: "\(folder)/countdown-\(theme.rawValue).png")
        }
        // Glass leaves the frame's edges clear to show what's behind it;
        // the others fill the frame.
        let corner = pixel(image, x: 10, y: 10)
        #expect(theme == .glass ? corner[3] == 0 : corner[3] == 255)
        // The middle has text and a card or background, so it's not blank.
        #expect(pixel(image, x: 960, y: 540)[3] > 0)
    }

    @Test func eachSecondLooksDifferent() throws {
        let size = CGSize(width: 1280, height: 720)
        let settings = CountdownSettings()
        let a = try render(CountdownRenderer.image(settings, clock: "4:59", size: size), size: size)
        let b = try render(CountdownRenderer.image(settings, clock: "4:58", size: size), size: size)
        #expect(pixels(a) != pixels(b))
    }

    @Test func fitsALongTitleOnAPortraitCanvas() throws {
        let size = CGSize(width: 1080, height: 1920)
        var settings = CountdownSettings(title: String(repeating: "Starting really very soon ", count: 4))
        settings.theme = .daylight
        let image = try render(CountdownRenderer.image(settings, clock: "1:02:03", size: size), size: size)
        #expect(image.width == 1080 && image.height == 1920)
    }

    @Test func nodeTicksOnTheSecond() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        nonisolated(unsafe) var now = start
        let settings = CountdownSettings(minutes: 5, endsAt: start + 300)
        let node = CountdownNode(settings: settings, size: CGSize(width: 640, height: 360), now: { now })
        let first = try #require(node.image(at: 0))
        // Drawn ahead, so the next second is ready the moment it comes.
        now = start + 1.01
        let second = try #require(node.image(at: 0))
        #expect(first !== second)
        let size = CGSize(width: 640, height: 360)
        #expect(try pixels(render(second, size: size)) == pixels(render(CountdownRenderer.image(settings, clock: "4:59", size: size), size: size)))
    }

    private func render(_ image: CIImage, size: CGSize) throws -> CGImage {
        try #require(CIContext().createCGImage(image, from: CGRect(origin: .zero, size: size)))
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let all = pixels(image)
        let i = (y * image.width + x) * 4
        return Array(all[i..<i + 4])
    }

    private func save(_ image: CGImage, to path: String) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(URL(filePath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
