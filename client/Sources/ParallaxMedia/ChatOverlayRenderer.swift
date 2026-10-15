import AppKit
import CoreImage
import ParallaxCore

public struct ChatOverlayLine: Hashable, Sendable {
    /// The chat message's ID, to tell which messages are new.
    public var id: String
    public var author: String
    public var text: String
    public var accent: RGBAColor

    public init(id: String = UUID().uuidString, author: String, text: String, accent: RGBAColor) {
        self.id = id
        self.author = author
        self.text = text
        self.accent = accent
    }
}

/// The chat feed as layers, so new messages can slide in from the bottom
/// while the others move up to make room (see `ChatFeedNode`).
struct ChatFeedLayers: @unchecked Sendable {
    /// The shared box, the size of the feed's frame.
    var background: CIImage
    /// Messages already showing, where they rest once the new ones are in.
    var resting: CIImage
    /// The new messages, where they rest.
    var arriving: CIImage
    /// Messages the new ones push out the top, where they'd be if they fit.
    var leaving: CIImage
    /// How far the new messages push the others up.
    var shift: CGFloat
    /// Where messages show: inside the box, short of its edges.
    var clip: CGRect

    /// `progress` 0 is just before the new messages come in; 1 and above is
    /// at rest.
    func frame(progress: Double) -> CIImage {
        let t = min(1, max(0, progress))
        guard t < 1, shift > 0 else {
            return arriving.composited(over: resting).cropped(to: clip).composited(over: background)
        }
        let eased = 1 - pow(1 - t, 3)
        let down = CGAffineTransform(translationX: 0, y: -shift * (1 - eased))
        let messages = Self.faded(leaving, 1 - eased)
            .composited(over: Self.faded(arriving, eased))
            .composited(over: resting)
            .transformed(by: down)
        return messages.cropped(to: clip).composited(over: background)
    }

    private static func faded(_ image: CIImage, _ alpha: Double) -> CIImage {
        let a = CGFloat(alpha)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
        ])
    }
}

/// Draws chat into images the compositor places like any other source.
@MainActor
enum ChatOverlayRenderer {
    static let feedSize = CGSize(width: 500, height: 990)
    static let bannerSize = CGSize(width: 1600, height: 240)

    /// The feed at rest: newest message at the bottom, older ones stacked
    /// above until full, all in one shared semi-transparent box that fills
    /// the feed's frame.
    static func feed(_ lines: [ChatOverlayLine], size: CGSize = feedSize, scale: CGFloat = 1) -> CIImage {
        feedLayers(lines, arriving: 0, size: size, scale: scale).frame(progress: 1)
    }

    /// The feed as layers, with the newest `arriving` messages ready to slide
    /// in. Drawn at the pixel size of its box on the canvas so text keeps
    /// its size and reflows as the box is resized; `scale` is canvas height
    /// / 1080 times the text size.
    static func feedLayers(_ lines: [ChatOverlayLine], arriving: Int, size: CGSize = feedSize,
                           scale: CGFloat = 1) -> ChatFeedLayers {
        // Left, top, and bottom are a bit tighter than the right edge.
        let pad = 12 * scale, padRight = 16 * scale, gap = 9 * scale, radius = 12 * scale
        let width = size.width - pad - padRight
        enum Role { case resting, arriving, leaving }
        var placed: [(text: NSAttributedString, rect: CGRect, role: Role)] = []
        var y = pad, shift: CGFloat = 0
        for (i, line) in lines.enumerated().reversed() {
            let text = attributed(line, authorSize: 18 * scale, textSize: 21 * scale)
            let height = ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
            let isNew = i >= lines.count - arriving
            let rect = CGRect(x: pad, y: y, width: width, height: height)
            if rect.maxY + pad <= size.height {
                placed.append((text, rect, isNew ? .arriving : .resting))
            } else if !isNew, rect.maxY + pad - shift <= size.height {
                // Showing until the new messages push it out.
                placed.append((text, rect, .leaving))
            } else {
                break
            }
            y = rect.maxY + gap
            if isNew { shift = y - pad }
        }
        func layer(_ role: Role, height: CGFloat) -> CIImage {
            draw(size: CGSize(width: size.width, height: height)) { _ in
                for p in placed where p.role == role {
                    p.text.draw(with: p.rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
                }
            }
        }
        let background = draw(size: size) { size in
            NSColor(white: 0, alpha: 0.6).setFill()
            NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: radius, yRadius: radius).fill()
        }
        return ChatFeedLayers(
            background: background,
            resting: layer(.resting, height: size.height),
            arriving: layer(.arriving, height: size.height),
            // Taller, since these sit above the box until they've moved down.
            leaving: layer(.leaving, height: size.height + shift),
            shift: shift,
            clip: CGRect(x: 0, y: pad / 2, width: size.width, height: size.height - pad))
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
