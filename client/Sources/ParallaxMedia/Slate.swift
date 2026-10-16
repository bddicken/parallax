import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The "We'll be right back" screen the server plays while this Mac isn't
/// sending video (say, while Parallax restarts mid-broadcast). Drawn here,
/// at the stream's size, since the server's ffmpeg may not draw text.
public enum Slate {
    public static let defaultText = "We’ll be right back"

    public struct Failure: LocalizedError {
        public let errorDescription: String?
    }

    public static func pngData(width: Int, height: Int, text: String = defaultText) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw Failure(errorDescription: "Couldn't draw the slate at \(width) × \(height).")
        }
        let w = CGFloat(width), h = CGFloat(height)
        // A dark vertical gradient, lighter at the top.
        let colors = [CGColor(srgbRed: 0.11, green: 0.12, blue: 0.16, alpha: 1),
                      CGColor(srgbRed: 0.04, green: 0.05, blue: 0.07, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: .zero, options: [])

        // Sized to the height, but never wider than 80% of the frame.
        var fontSize = h * 0.085
        var line = makeLine(text, size: fontSize)
        let maxWidth = w * 0.8
        let measured = CTLineGetTypographicBounds(line, nil, nil, nil)
        if measured > maxWidth {
            fontSize *= maxWidth / measured
            line = makeLine(text, size: fontSize)
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.textPosition = CGPoint(x: (w - lineWidth) / 2, y: (h - ascent + descent) / 2)
        CTLineDraw(line, context)

        // A short accent bar under the text.
        let bar = CGRect(x: (w - h * 0.08) / 2, y: (h - ascent) / 2 - h * 0.06, width: h * 0.08, height: max(2, h * 0.006))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.27, blue: 0.27, alpha: 1))
        context.fill(bar)

        guard let image = context.makeImage() else { throw Failure(errorDescription: "Couldn't draw the slate.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(errorDescription: "Couldn't encode the slate.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(errorDescription: "Couldn't encode the slate.") }
        return data as Data
    }

    private static func makeLine(_ text: String, size: CGFloat) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil)!
        let bold = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .boldTrait, .boldTrait) ?? font
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): bold,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
}
