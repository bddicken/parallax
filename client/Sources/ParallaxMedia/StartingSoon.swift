import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import ParallaxCore

/// Draws the "Starting soon" screen: the words over a slow animation, on clear, so the blurred scene shows through.
enum StartingSoonRenderer {
    /// How the scene beneath is blurred or fogged.
    static func backdrop(_ settings: StartingSoonSettings) -> BackdropEffect {
        let s = min(1, max(0, settings.strength))
        return switch settings.backdrop {
        case .blur: BackdropEffect(blur: 12 + 48 * s, saturation: 0.9, brightness: 1 - 0.55 * s)
        case .fog: BackdropEffect(blur: 10 + 40 * s, saturation: 0.6 - 0.35 * s, brightness: 0.92,
                                  haze: RGBAColor(red: 0.80, green: 0.84, blue: 0.90, alpha: 0.12 + 0.36 * s))
        }
    }

    /// "Starting soon", centered, with a soft shadow so it reads over a
    /// busy scene.
    static func text(size: CGSize) -> CIImage {
        guard let (context, w, h) = makeContext(size) else { return .empty() }
        let unit = unit(w, h)
        let title = CountdownRenderer.line(StartingSoonSettings.text, size: unit * 0.075, weight: .medium, tracking: -0.01,
                                           color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), maxWidth: w * 0.84)
        title.draw(in: context, centerX: w / 2, bottom: (h - title.height) / 2)
        guard let cgImage = context.makeImage() else { return .empty() }
        let text = CIImage(cgImage: cgImage)
        return text.composited(over: shadow(of: text, radius: unit * 0.02, opacity: 0.5))
    }

    /// A soft dark halo around `image`'s shapes.
    private static func shadow(of image: CIImage, radius: CGFloat, opacity: CGFloat) -> CIImage {
        let tint = CIFilter.colorMatrix()
        tint.inputImage = image
        tint.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: opacity)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = tint.outputImage
        blur.radius = Float(radius)
        return blur.outputImage?.cropped(to: image.extent) ?? .empty()
    }

    /// The animation `time` seconds in, on clear.
    static func animation(_ animation: StartingSoonAnimation, time t: Double, size: CGSize) -> CIImage {
        if animation == .aurora { return aurora(time: t, size: size) }
        guard let (context, w, h) = makeContext(size) else { return .empty() }
        let unit = unit(w, h)
        context.setLineCap(.round)
        switch animation {
        case .constellation: constellation(context, w: w, h: h, unit: unit, t: t)
        case .drift: drift(context, w: w, h: h, unit: unit, t: t)
        case .ripples: ripples(context, w: w, h: h, unit: unit, t: t)
        case .aurora: break
        }
        return context.makeImage().map { CIImage(cgImage: $0) } ?? .empty()
    }

    // MARK: Animations

    /// Points drifting slowly in every direction, linked by faint lines
    /// that fade in as two come near and out as they part.
    private static func constellation(_ context: CGContext, w: CGFloat, h: CGFloat, unit: CGFloat, t: Double) {
        // They roam a margin past the edges, so wrapping around happens off screen.
        let pad = unit * 0.15
        let points = (0..<56).map { i -> CGPoint in
            let angle = random(i, 0) * 2 * .pi
            let speed = unit * (0.006 + 0.014 * random(i, 1))
            let x = CGFloat(random(i, 2)) * (w + pad * 2) + CGFloat(cos(angle) * t) * speed
            let y = CGFloat(random(i, 3)) * (h + pad * 2) + CGFloat(sin(angle) * t) * speed
            return CGPoint(x: wrap(x, w + pad * 2) - pad, y: wrap(y, h + pad * 2) - pad)
        }
        let reach = unit * 0.24
        context.setLineWidth(max(1, unit / 1080 * 1.1))
        for i in points.indices {
            for j in points.indices where j > i {
                let d = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
                guard d < reach else { continue }
                let alpha = 0.32 * pow(1 - d / reach, 1.5)
                context.setStrokeColor(CGColor(srgbRed: 0.72, green: 0.84, blue: 1, alpha: alpha))
                context.strokeLineSegments(between: [points[i], points[j]])
            }
        }
        for (i, p) in points.enumerated() {
            let radius = unit * (0.002 + 0.0025 * random(i, 4))
            let alpha = 0.55 + 0.35 * (0.5 + 0.5 * sin(t * (0.4 + 0.8 * random(i, 5)) + Double(i)))
            context.setFillColor(CGColor(srgbRed: 0.72, green: 0.84, blue: 1, alpha: alpha * 0.15))
            context.fillEllipse(in: CGRect(x: p.x - radius * 3, y: p.y - radius * 3, width: radius * 6, height: radius * 6))
            context.setFillColor(CGColor(srgbRed: 0.9, green: 0.95, blue: 1, alpha: alpha))
            context.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
        }
    }

    /// Specks of warm light rising, swaying, and twinkling.
    private static func drift(_ context: CGContext, w: CGFloat, h: CGFloat, unit: CGFloat, t: Double) {
        for i in 0..<90 {
            let speed = 0.012 + 0.025 * random(i, 1)
            let y = CGFloat(fract(random(i, 2) + t * speed)) * h * 1.1 - h * 0.05
            let x = CGFloat(random(i, 0)) * w + CGFloat(sin(t * (0.2 + 0.3 * random(i, 3)) + Double(i))) * unit * 0.02
            let radius = unit * (0.0015 + 0.0035 * random(i, 4))
            let twinkle = 0.25 + 0.55 * (0.5 + 0.5 * sin(t * (0.6 + 1.2 * random(i, 5)) + Double(i) * 3))
            let edge = min(1, max(0, min(y, h - y) / (h * 0.15)))
            let alpha = twinkle * Double(edge)
            guard alpha > 0.01 else { continue }
            context.setFillColor(CGColor(srgbRed: 1, green: 0.9, blue: 0.78, alpha: alpha * 0.12))
            context.fillEllipse(in: CGRect(x: x - radius * 3, y: y - radius * 3, width: radius * 6, height: radius * 6))
            context.setFillColor(CGColor(srgbRed: 1, green: 0.94, blue: 0.86, alpha: alpha))
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
    }

    /// Rings widening out from behind the words and fading.
    private static func ripples(_ context: CGContext, w: CGFloat, h: CGFloat, unit: CGFloat, t: Double) {
        let rings = 5, period = 9.0
        context.setLineWidth(max(1, unit / 1080 * 1.6))
        for k in 0..<rings {
            let p = fract(t / period + Double(k) / Double(rings))
            let radius = unit * (0.14 + 0.8 * p)
            let alpha = 0.4 * pow(1 - p, 1.5) * smootherstep(p / 0.1)
            context.setStrokeColor(CGColor(srgbRed: 0.82, green: 0.9, blue: 1, alpha: alpha))
            context.strokeEllipse(in: CGRect(x: w / 2 - radius, y: h / 2 - radius, width: radius * 2, height: radius * 2))
        }
    }

    /// Big soft glows of color drifting slowly. Built from Core Image
    /// gradients, so the GPU draws it.
    private static func aurora(time t: Double, size: CGSize) -> CIImage {
        let w = size.width, h = size.height, unit = unit(w, h)
        let colors: [(Double, Double, Double)] = [(0.30, 0.55, 1.0), (0.62, 0.36, 0.95), (0.20, 0.80, 0.75), (0.95, 0.45, 0.65)]
        var image = CIImage.empty()
        for (i, c) in colors.enumerated() {
            let d = Double(i)
            let center = CGPoint(x: w * (0.5 + 0.38 * sin(t * 0.09 * (1 + d * 0.37) + d * 1.9)),
                                 y: h * (0.5 + 0.32 * cos(t * 0.077 * (1 + d * 0.29) + d * 2.7)))
            let gradient = CIFilter.radialGradient()
            gradient.center = center
            gradient.radius0 = 0
            gradient.radius1 = Float(unit * (0.6 + 0.12 * sin(t * 0.1 + d)))
            let a = 0.5
            gradient.color0 = CIColor(red: c.0 * a, green: c.1 * a, blue: c.2 * a, alpha: a)
            gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let glow = gradient.outputImage else { continue }
            let add = CIFilter.additionCompositing()
            add.inputImage = glow
            add.backgroundImage = image
            image = add.outputImage ?? image
        }
        return image.cropped(to: CGRect(origin: .zero, size: size))
    }

    // MARK: Helpers

    private static func makeContext(_ size: CGSize) -> (CGContext, CGFloat, CGFloat)? {
        let w = max(1, size.width.rounded()), h = max(1, size.height.rounded())
        guard let context = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return (context, w, h)
    }

    /// Sized off the shorter side, so a portrait canvas fits too.
    private static func unit(_ w: CGFloat, _ h: CGFloat) -> CGFloat { min(w, h * 16 / 9) / 16 * 9 }

    private static func smootherstep(_ x: CGFloat) -> CGFloat {
        let x = min(1, max(0, x))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    private static func smootherstep(_ x: Double) -> Double { Double(smootherstep(CGFloat(x))) }

    private static func fract(_ x: Double) -> Double { x - x.rounded(.down) }

    /// `x` wrapped into 0..<`length`.
    private static func wrap(_ x: CGFloat, _ length: CGFloat) -> CGFloat {
        let r = x.truncatingRemainder(dividingBy: length)
        return r < 0 ? r + length : r
    }

    /// A fixed pseudo-random number in 0..<1 for `index` and `salt`, so each
    /// line or speck keeps its own pace from frame to frame.
    private static func random(_ index: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: index &* 73_856_093 ^ salt &* 19_349_663) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(1 << 53)
    }
}

/// The starting-soon screen as a source. The words are drawn once; the
/// animation is drawn ahead off the compositor's thread at `fps`.
final class StartingSoonNode: VideoSourceNode, BackdropNode, @unchecked Sendable {
    let backdrop: BackdropEffect?
    private let settings: StartingSoonSettings
    private let size: CGSize
    private let text: CIImage
    private let fps: Int
    private let lock = NSLock()
    private var frame: CIImage?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.bddicken.parallax.starting-soon", qos: .userInitiated)
    /// Seconds on a steady clock; tests pass their own.
    private let clock: @Sendable () -> Double

    init(settings: StartingSoonSettings, size: CGSize, fps: Int = 30,
         clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.settings = settings
        self.size = size
        self.fps = fps
        self.clock = clock
        backdrop = StartingSoonRenderer.backdrop(settings)
        text = StartingSoonRenderer.text(size: size)
        prepare()
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / max(1, fps)), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.prepare() }
        timer.resume()
        lock.withLock { self.timer = timer }
    }

    func stop() {
        lock.withLock { timer }?.cancel()
    }

    func image(at time: Double) -> CIImage? {
        lock.withLock { frame }
    }

    /// Draws the animation as of now under the words.
    func prepare() {
        let animation = StartingSoonRenderer.animation(settings.animation, time: clock(), size: size)
        let image = text.composited(over: animation)
        lock.withLock { frame = image }
    }
}
