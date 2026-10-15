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
    static let feedSize = CGSize(width: 500, height: 990)
    static let bannerSize = CGSize(width: 1600, height: 240)

    /// Newest message at the bottom, older ones stacked above until full,
    /// all in one shared semi-transparent box that grows to fit them (none
    /// when there's no chat). Drawn at the pixel size of its box on the
    /// canvas so text keeps its size and reflows as the box is resized;
    /// `scale` is canvas height / 1080 times the text size.
    static func feed(_ lines: [ChatOverlayLine], size: CGSize = feedSize, scale: CGFloat = 1) -> CIImage {
        draw(size: size) { size in
            // Left, top, and bottom are a bit tighter than the right edge.
            let pad = 12 * scale, padRight = 16 * scale, gap = 9 * scale, radius = 12 * scale
            let width = size.width - pad - padRight
            var fitted: [(text: NSAttributedString, height: CGFloat)] = []
            var height = pad * 2
            for line in lines.reversed() {
                let text = attributed(line, authorSize: 18 * scale, textSize: 21 * scale)
                let bounds = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading])
                let next = height + ceil(bounds.height) + (fitted.isEmpty ? 0 : gap)
                guard next <= size.height else { break }
                fitted.append((text, ceil(bounds.height)))
                height = next
            }
            guard !fitted.isEmpty else { return }
            NSColor(white: 0, alpha: 0.6).setFill()
            NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: height), xRadius: radius, yRadius: radius).fill()
            var y = pad
            for (text, textHeight) in fitted {
                text.draw(with: CGRect(x: pad, y: y, width: width, height: textHeight),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
                y += textHeight + gap
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
        let ctx = CGContext(data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body(size)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
    }
}
