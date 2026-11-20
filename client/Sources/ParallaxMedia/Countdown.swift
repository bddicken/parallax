import AppKit
import CoreImage
import CoreText
import ParallaxCore

/// Draws the countdown screen: the title, a short accent bar, and the timer,
/// centered, in the chosen theme.
enum CountdownRenderer {
    struct Palette {
        /// Top and bottom of the background, or nil for none.
        var background: (CGColor, CGColor)?
        /// For `glass`: a rounded card behind the text.
        var card: CGColor?
        var text: CGColor
        var titleAlpha: CGFloat
        var accent: CGColor
        var clockWeight: NSFont.Weight
    }

    static func palette(_ theme: CountdownTheme) -> Palette {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
        return switch theme {
        case .midnight:
            Palette(background: (rgb(0.08, 0.10, 0.18), rgb(0.02, 0.03, 0.07)), text: rgb(1, 1, 1), titleAlpha: 0.8,
                    accent: rgb(0.38, 0.62, 1), clockWeight: .light)
        case .daylight:
            Palette(background: (rgb(0.98, 0.97, 0.95), rgb(0.92, 0.90, 0.87)), text: rgb(0.08, 0.08, 0.10), titleAlpha: 0.7,
                    accent: rgb(0.93, 0.36, 0.24), clockWeight: .light)
        case .sunset:
            Palette(background: (rgb(1, 0.50, 0.40), rgb(0.40, 0.22, 0.60)), text: rgb(1, 1, 1), titleAlpha: 0.9,
                    accent: rgb(1, 1, 1, 0.85), clockWeight: .semibold)
        case .glass:
            Palette(background: nil, card: rgb(0.05, 0.06, 0.09, 0.62), text: rgb(1, 1, 1), titleAlpha: 0.85,
                    accent: rgb(1, 0.27, 0.27), clockWeight: .medium)
        }
    }

    /// The screen at `size` (the canvas), showing `clock` under the title.
    static func image(_ settings: CountdownSettings, clock: String, size: CGSize) -> CIImage {
        let w = max(1, size.width.rounded()), h = max(1, size.height.rounded())
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty() }
        let palette = palette(settings.theme)
        // Sized off the shorter side, so a portrait canvas fits too.
        let unit = min(w, h * 16 / 9) / 16 * 9

        if let (top, bottom) = palette.background {
            let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
            // Diagonal for sunset, straight down otherwise.
            let start = settings.theme == .sunset ? CGPoint(x: 0, y: h) : CGPoint(x: w / 2, y: h)
            let end = settings.theme == .sunset ? CGPoint(x: w, y: 0) : CGPoint(x: w / 2, y: 0)
            context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        let maxWidth = w * 0.84
        let title = line(settings.title, size: unit * 0.056, weight: .semibold, tracking: 0.04,
                         color: palette.text.copy(alpha: palette.titleAlpha)!, maxWidth: maxWidth)
        let finished = clock == CountdownSettings.finishedText
        let timer = line(clock, size: unit * (finished ? 0.11 : 0.2), weight: palette.clockWeight, monospacedDigits: true,
                         color: palette.text, maxWidth: maxWidth)
        let gap = unit * 0.045, barHeight = max(2, unit * 0.006), barWidth = unit * 0.07
        let blockHeight = title.height + gap + barHeight + gap + timer.height
        // The block's bottom, centered a touch above the middle.
        let bottom = (h - blockHeight) / 2 + unit * 0.01

        if let card = palette.card {
            let padX = unit * 0.08, padY = unit * 0.07
            let cardWidth = max(title.width, timer.width) + padX * 2
            let rect = CGRect(x: (w - cardWidth) / 2, y: bottom - padY, width: cardWidth, height: blockHeight + padY * 2)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: unit * 0.04, cornerHeight: unit * 0.04, transform: nil))
            context.setFillColor(card)
            context.fillPath()
        }

        timer.draw(in: context, centerX: w / 2, bottom: bottom)
        context.setFillColor(palette.accent)
        context.fill(CGRect(x: (w - barWidth) / 2, y: bottom + timer.height + gap, width: barWidth, height: barHeight))
        title.draw(in: context, centerX: w / 2, bottom: bottom + timer.height + gap + barHeight + gap)

        return context.makeImage().map { CIImage(cgImage: $0) } ?? .empty()
    }

    struct Line {
        var ctLine: CTLine
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var height: CGFloat { ascent + descent }

        func draw(in context: CGContext, centerX: CGFloat, bottom: CGFloat) {
            context.textPosition = CGPoint(x: centerX - width / 2, y: bottom + descent)
            CTLineDraw(ctLine, context)
        }
    }

    /// One line of text, shrunk to fit `maxWidth`.
    static func line(_ text: String, size: CGFloat, weight: NSFont.Weight, tracking: CGFloat = 0,
                             monospacedDigits: Bool = false, color: CGColor, maxWidth: CGFloat) -> Line {
        func make(_ size: CGFloat) -> Line {
            let font = monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTKernAttributeName as String): size * tracking,
            ]
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil)
            // Size by the font's cap height, so the block looks evenly spaced.
            return Line(ctLine: ctLine, width: width, ascent: font.capHeight, descent: 0)
        }
        let first = make(size)
        guard first.width > maxWidth, first.width > 0 else { return first }
        return make(size * maxWidth / first.width)
    }
}

/// The countdown as a source. Each second's screen is drawn ahead of time
/// off the compositor's thread, so the timer ticks right on the second.
final class CountdownNode: VideoSourceNode, @unchecked Sendable {
    private let settings: CountdownSettings
    private let size: CGSize
    private let lock = NSLock()
    private var frames: [String: CIImage] = [:]
    private var shown: CIImage?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.bddicken.parallax.countdown", qos: .userInitiated)
    /// Wall-clock time; tests pass their own.
    private let now: @Sendable () -> Date

    init(settings: CountdownSettings, size: CGSize, now: @escaping @Sendable () -> Date = { Date() }) {
        self.settings = settings
        self.size = size
        self.now = now
        prepare()
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.prepare() }
        timer.resume()
        lock.withLock { self.timer = timer }
    }

    func stop() {
        lock.withLock { timer }?.cancel()
    }

    func image(at time: Double) -> CIImage? {
        let clock = settings.clock(at: now())
        return lock.withLock {
            if let frame = frames[clock] { shown = frame }
            return shown
        }
    }

    /// Draws this second's screen and the next, dropping older ones.
    func prepare() {
        let date = now()
        let wanted = [settings.clock(at: date), settings.clock(at: date + 1)]
        let missing = lock.withLock { wanted.filter { frames[$0] == nil } }
        var drawn: [String: CIImage] = [:]
        for clock in Set(missing) { drawn[clock] = CountdownRenderer.image(settings, clock: clock, size: size) }
        lock.withLock {
            frames = frames.filter { wanted.contains($0.key) }.merging(drawn) { $1 }
        }
    }
}
