import CoreImage
import Foundation
import ImageIO
import ParallaxCore
import Testing
import UniformTypeIdentifiers
@testable import ParallaxMedia

@Suite struct StartingSoonRenderTests {
    private let size = CGSize(width: 1280, height: 720)

    /// Set PARALLAX_STARTING_SOON_PREVIEW to a folder to save each look as a
    /// PNG. PARALLAX_STARTING_SOON_SCENE can name an image to put beneath it.
    @Test(arguments: StartingSoonAnimation.allCases, StartingSoonBackdrop.allCases)
    func drawsEachLookOverAScene(animation: StartingSoonAnimation, backdrop: StartingSoonBackdrop) throws {
        let settings = StartingSoonSettings(animation: animation, backdrop: backdrop)
        let node = StartingSoonNode(settings: settings, size: size, clock: { 12.5 })
        let overlay = try #require(node.image(at: 0))
        let canvas = CGRect(origin: .zero, size: size)
        let scene = sceneImage()
        let beneath = try #require(node.backdrop).apply(to: scene, in: canvas, canvasHeight: size.height)
        let image = try render(overlay.composited(over: beneath.composited(over: scene)))
        #expect(image.width == 1280 && image.height == 720)
        if let folder = ProcessInfo.processInfo.environment["PARALLAX_STARTING_SOON_PREVIEW"] {
            try save(image, to: "\(folder)/starting-soon-\(animation.rawValue)-\(backdrop.rawValue).png")
        }
        // The overlay itself is clear away from the title, so the scene shows.
        let corner = try render(overlay)
        #expect(pixel(corner, x: 2, y: 2)[3] < 255)
        // The words are drawn.
        let text = pixels(try render(StartingSoonRenderer.text(size: size)))
        #expect(stride(from: 3, to: text.count, by: 4).contains { text[$0] > 200 })
    }

    @Test func blurSoftensTheSceneAndFogLightensIt() throws {
        let canvas = CGRect(origin: .zero, size: size)
        let scene = sceneImage()
        let sharp = try render(scene)
        let blurred = try render(StartingSoonRenderer.backdrop(StartingSoonSettings(backdrop: .blur))
            .apply(to: scene, in: canvas, canvasHeight: size.height))
        let fogged = try render(StartingSoonRenderer.backdrop(StartingSoonSettings(backdrop: .fog))
            .apply(to: scene, in: canvas, canvasHeight: size.height))
        #expect(contrast(blurred) < contrast(sharp) / 2)
        #expect(brightness(blurred) < brightness(sharp))
        #expect(brightness(fogged) > brightness(blurred))
    }

    @Test func blursOnlyWithinTheItemsFrame() throws {
        let rect = CGRect(x: 320, y: 180, width: 640, height: 360)
        let effect = StartingSoonRenderer.backdrop(StartingSoonSettings())
        #expect(effect.apply(to: sceneImage(), in: rect, canvasHeight: size.height).extent == rect)
    }

    @Test func animates() throws {
        for animation in StartingSoonAnimation.allCases {
            let a = try render(StartingSoonRenderer.animation(animation, time: 3, size: size))
            let b = try render(StartingSoonRenderer.animation(animation, time: 4, size: size))
            #expect(pixels(a) != pixels(b), "\(animation) should move")
        }
    }

    @Test func drawsAFrameFastEnough() {
        let full = CGSize(width: 1920, height: 1080)
        for animation in StartingSoonAnimation.allCases {
            // The quickest of several, so other tests running alongside don't make it flaky.
            let perFrame = (0..<8).map { i in
                let start = Date()
                _ = StartingSoonRenderer.animation(animation, time: Double(i) / 30, size: full)
                return Date().timeIntervalSince(start)
            }.min()!
            // Drawn at 30 fps off the compositor's thread, so it must fit in a frame.
            #expect(perFrame < 1.0 / 30, "\(animation) took \(Int(perFrame * 1000)) ms")
        }
    }

    @Test func roundTripsInAProfile() throws {
        let settings = StartingSoonSettings(animation: .ripples, backdrop: .fog, strength: 0.3)
        let source = VideoSource(name: "Starting Soon", kind: .startingSoon(settings))
        #expect(try JSONDecoder().decode(VideoSource.self, from: JSONEncoder().encode(source)) == source)
    }

    // MARK: Helpers

    /// A busy, colorful scene with hard edges, or the image named by
    /// PARALLAX_STARTING_SOON_SCENE.
    private func sceneImage() -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        if let path = ProcessInfo.processInfo.environment["PARALLAX_STARTING_SOON_SCENE"],
           let image = CIImage(contentsOf: URL(filePath: path)) {
            let e = image.extent
            let scale = max(size.width / e.width, size.height / e.height)
            return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: canvas)
        }
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputColor0": CIColor(red: 0.9, green: 0.7, blue: 0.3), "inputColor1": CIColor(red: 0.1, green: 0.3, blue: 0.6),
            "inputWidth": 80, "inputCenter": CIVector(x: 0, y: 0),
        ])!.outputImage!
        return checker.cropped(to: canvas)
    }

    private func render(_ image: CIImage) throws -> CGImage {
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

    private func brightness(_ image: CGImage) -> Double {
        let p = pixels(image)
        return stride(from: 0, to: p.count, by: 4).reduce(0.0) { $0 + Double(p[$1]) + Double(p[$1 + 1]) + Double(p[$1 + 2]) }
            / Double(p.count / 4 * 3)
    }

    /// Mean difference between horizontal neighbours: high for hard edges.
    private func contrast(_ image: CGImage) -> Double {
        let p = pixels(image)
        var total = 0.0
        for i in stride(from: 0, to: p.count - 4, by: 4) { total += abs(Double(p[i]) - Double(p[i + 4])) }
        return total / Double(p.count / 4)
    }

    private func save(_ image: CGImage, to path: String) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(URL(filePath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
