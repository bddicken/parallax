import AppKit
import CoreImage
import ParallaxCore

public struct ChatOverlayLine: Hashable, Sendable {
    public var author: String
    public var text: String
    public var accent: RGBAColor

    public init(author: String, text: String, accent: RGBAColor) {
        self.author = author
        self.text = text
        self.accent = accent
    }
}

/// Draws chat into images the compositor places like any other source.
@MainActor
enum ChatOverlayRenderer {
    static let feedSize = CGSize(width: 640, height: 900)
    static let bannerSize = CGSize(width: 1600, height: 240)

    /// Newest message at the bottom, older ones stacked above until full.
    static func feed(_ lines: [ChatOverlayLine]) -> CIImage {
        draw(size: feedSize) { size in
            let pad: CGFloat = 18, gap: CGFloat = 10
            var y: CGFloat = 0
            for line in lines.reversed() {
                let text = attributed(line, authorSize: 22, textSize: 24)
                let bounds = text.boundingRect(with: CGSize(width: size.width - pad * 2, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading])
                let card = CGRect(x: 0, y: y, width: size.width, height: ceil(bounds.height) + pad * 2)
                guard card.maxY <= size.height else { break }
                NSColor(white: 0, alpha: 0.65).setFill()
                NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
                text.draw(with: card.insetBy(dx: pad, dy: pad), options: [.usesLineFragmentOrigin, .usesFontLeading])
                y = card.maxY + gap
            }
        }
    }

    static func banner(_ line: ChatOverlayLine) -> CIImage {
        draw(size: bannerSize) { size in
            let rect = CGRect(origin: .zero, size: size)
            NSColor(white: 0.08, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 20, yRadius: 20).fill()
            color(line.accent).setFill()
            NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 16, height: size.height), xRadius: 8, yRadius: 8).fill()
            let text = attributed(line, authorSize: 34, textSize: 44)
            text.draw(with: rect.insetBy(dx: 48, dy: 32), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        }
    }

    private static func attributed(_ line: ChatOverlayLine, authorSize: CGFloat, textSize: CGFloat) -> NSAttributedString {
        let s = NSMutableAttributedString(string: line.author + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: authorSize, weight: .bold),
            .foregroundColor: color(line.accent),
        ])
        s.append(NSAttributedString(string: line.text, attributes: [
            .font: NSFont.systemFont(ofSize: textSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ]))
        return s
    }

    private static func color(_ c: RGBAColor) -> NSColor {
        NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    private static func draw(size: CGSize, _ body: (CGSize) -> Void) -> CIImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body(size)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
    }
}
