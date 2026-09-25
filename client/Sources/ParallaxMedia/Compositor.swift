import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import Foundation
import Metal
import ParallaxCore

/// Renders the program scene at the output frame rate and hands each frame to
/// the sinks (preview, recorder, uplink). Scenes recorded on their own are
/// rendered in the same tick, with the same timestamp.
final class Compositor: @unchecked Sendable {
    private struct Transition {
        var from: UUID?
        var to: UUID
        var start: Double
        var duration: Double
    }

    private let registry: SourceRegistry
    private let sinks: SinkHub
    private let queue = DispatchQueue(label: "parallax.compositor", qos: .userInteractive)
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private let lock = NSLock()
    private var scenes: [UUID: StudioScene] = [:]
    private var program: UUID?
    private var transition: Transition?
    private var output = OutputSettings()

    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var poolSize: (Int, Int)?
    private var timerFPS = 0

    init(registry: SourceRegistry, sinks: SinkHub) {
        self.registry = registry
        self.sinks = sinks
        // Blend in sRGB (gamma) space like design tools and OBS do, so a 50%
        // shadow or a mid-fade looks 50% rather than washed out.
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    var outputSettings: OutputSettings { lock.withLock { output } }

    func update(scenes: [StudioScene], output: OutputSettings) {
        lock.withLock {
            self.scenes = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
            self.output = output
        }
        queue.async { [self] in
            if timer != nil, timerFPS != output.fps { startTimer() }
        }
    }

    func setProgram(_ id: UUID?, transition settings: TransitionSettings) {
        lock.withLock {
            let duration = Double(settings.durationMs) / 1000
            if settings.kind == .fade, duration > 0, program != nil, program != id, let id {
                transition = Transition(from: program, to: id, start: hostNow(), duration: duration)
            } else {
                transition = nil
            }
            program = id
        }
    }

    func start() {
        queue.async { [self] in startTimer() }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func startTimer() {
        timer?.cancel()
        let fps = outputSettings.fps
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.renderFrame() }
        t.resume()
        timer = t
        timerFPS = fps
    }

    private func renderFrame() {
        let now = hostNow()
        let (scenes, program, transition, output) = lock.withLock { () -> ([UUID: StudioScene], UUID?, Transition?, OutputSettings) in
            if let t = self.transition, now - t.start >= t.duration { self.transition = nil }
            return (self.scenes, self.program, self.transition, self.output)
        }
        let canvas = CGRect(x: 0, y: 0, width: output.width, height: output.height)

        var image = render(scenes[program ?? UUID()], time: now, canvas: canvas)
        if let t = transition {
            let from = render(t.from.flatMap { scenes[$0] }, time: now, canvas: canvas)
            let dissolve = CIFilter.dissolveTransition()
            dissolve.inputImage = from
            dissolve.targetImage = image
            dissolve.time = Float(min(1, max(0, (now - t.start) / t.duration)))
            image = dissolve.outputImage ?? image
        }

        guard let buffer = makeBuffer(width: output.width, height: output.height) else { return }
        context.render(image, to: buffer, bounds: canvas, colorSpace: colorSpace)
        // Every output gets the same timestamp, so files recorded together
        // line up frame for frame.
        let pts = CMTime(hostSeconds: now)
        for (sceneID, outputs) in sinks.byScene {
            var frame = buffer
            if let sceneID, sceneID != program || transition != nil {
                guard let b = makeBuffer(width: output.width, height: output.height) else { continue }
                context.render(render(scenes[sceneID], time: now, canvas: canvas), to: b, bounds: canvas, colorSpace: colorSpace)
                frame = b
            }
            for sink in outputs { sink.appendVideo(frame, pts: pts) }
        }
    }

    /// Returns once any frame being rendered has been handed to the sinks.
    func flush() async {
        await withCheckedContinuation { cont in queue.async { cont.resume() } }
    }

    private func render(_ scene: StudioScene?, time: Double, canvas: CGRect) -> CIImage {
        var result = CIImage(color: .black).cropped(to: canvas)
        guard let scene else { return result }
        for item in scene.items where item.isVisible {
            guard let source = registry[item.sourceID]?.image(at: time) else { continue }
            let extent = source.extent
            let frame = item.frame.denormalized(in: canvas.size)
            guard let p = Placement.compute(sourceSize: extent.size, crop: item.crop, frame: frame, mode: item.contentMode) else { continue }

            // Placement is top-left origin; Core Image is bottom-left.
            let src = CGRect(x: extent.minX + p.sourceRect.minX, y: extent.minY + extent.height - p.sourceRect.maxY,
                             width: p.sourceRect.width, height: p.sourceRect.height)
            let dst = CGRect(x: p.destRect.minX, y: canvas.height - p.destRect.maxY,
                             width: p.destRect.width, height: p.destRect.height)
            let transform = CGAffineTransform(translationX: -src.minX, y: -src.minY)
                .concatenating(CGAffineTransform(scaleX: dst.width / src.width, y: dst.height / src.height))
                .concatenating(CGAffineTransform(translationX: dst.minX, y: dst.minY))
            var placed = source
                .cropped(to: src)
                .clampedToExtent()
                .transformed(by: transform, highQualityDownsample: true)
                .cropped(to: dst)
            placed = styled(placed, in: dst, item: item, canvasHeight: canvas.height)
            if let shadow = shadow(of: placed, item.shadow, canvasHeight: canvas.height) {
                result = shadow.composited(over: result)
            }
            result = placed.composited(over: result)
        }
        return result
    }

    private func styled(_ image: CIImage, in rect: CGRect, item: SceneItem, canvasHeight: CGFloat) -> CIImage {
        let radius = Float(min(rect.width, rect.height) * min(0.5, max(0, item.cornerRadius)))
        var out = image
        if radius > 0 {
            let mask = CIFilter.roundedRectangleGenerator()
            mask.extent = rect
            mask.radius = radius
            mask.color = .white
            let blend = CIFilter.blendWithMask()
            blend.inputImage = image
            blend.backgroundImage = CIImage.empty()
            blend.maskImage = mask.outputImage
            out = blend.outputImage ?? image
        }
        if item.border.isEnabled, item.border.width > 0 {
            let width = Float(item.border.width * canvasHeight / 1080)
            // The generator strokes inward from the extent, so it hugs the image edge.
            let stroke = CIFilter.roundedRectangleStrokeGenerator()
            stroke.extent = rect
            stroke.radius = radius
            stroke.width = width
            let c = item.border.color
            stroke.color = CIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
            if let border = stroke.outputImage { out = border.composited(over: out) }
        }
        return out
    }

    /// A blurred, tinted copy of the item's alpha, so the shadow follows
    /// rounded corners and transparent overlays rather than the box.
    private func shadow(of image: CIImage, _ settings: ItemShadow, canvasHeight: CGFloat) -> CIImage? {
        guard settings.isEnabled, settings.opacity > 0 else { return nil }
        let c = settings.color
        let tint = CIFilter.colorMatrix()
        tint.inputImage = image
        tint.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(settings.opacity * c.alpha))
        tint.biasVector = CIVector(x: c.red, y: c.green, z: c.blue, w: 0)
        guard var shadow = tint.outputImage else { return nil }
        let blur = settings.blur * canvasHeight / 1080
        if blur > 0.5 {
            let gaussian = CIFilter.gaussianBlur()
            gaussian.inputImage = shadow
            gaussian.radius = Float(blur)
            shadow = gaussian.outputImage ?? shadow
        }
        // Offset is top-left origin; Core Image's y axis points up.
        let offset = settings.offset(canvasHeight: canvasHeight)
        return shadow.transformed(by: CGAffineTransform(translationX: offset.width, y: -offset.height))
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if poolSize.map({ $0 != (width, height) }) ?? true {
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 8] as CFDictionary, attrs as CFDictionary, &pool)
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        if let buffer {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        return buffer
    }
}
