import CoreImage
import CoreImage.CIFilterBuiltins
import ParallaxCore

/// A source that changes the scene beneath it rather than only covering it,
/// like frosted glass. The compositor applies `backdrop` to everything drawn
/// before the source, within the source's frame, then draws the source.
protocol BackdropNode {
    var backdrop: BackdropEffect? { get }
}

/// Blurs, recolors, and hazes the scene beneath a source.
struct BackdropEffect: Hashable, Sendable {
    /// Blur radius on a 1080-high canvas; scaled to the canvas.
    var blur: Double
    /// 1 leaves color alone; 0 is grayscale.
    var saturation: Double = 1
    /// Multiplies the color: below 1 darkens.
    var brightness: Double = 1
    /// Laid over the top, for fog.
    var haze: RGBAColor?

    /// `scene` changed as set, cropped to `rect`.
    func apply(to scene: CIImage, in rect: CGRect, canvasHeight: CGFloat) -> CIImage {
        // Clamped so the blur doesn't pull in transparent black at the edges.
        var image = scene.clampedToExtent()
        let radius = blur * canvasHeight / 1080
        if radius > 0.5 {
            let gaussian = CIFilter.gaussianBlur()
            gaussian.inputImage = image
            gaussian.radius = Float(radius)
            image = gaussian.outputImage ?? image
        }
        if saturation != 1 || brightness != 1 {
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.saturation = Float(saturation)
            image = controls.outputImage ?? image
            let scale = CIFilter.colorMatrix()
            scale.inputImage = image
            scale.rVector = CIVector(x: brightness, y: 0, z: 0, w: 0)
            scale.gVector = CIVector(x: 0, y: brightness, z: 0, w: 0)
            scale.bVector = CIVector(x: 0, y: 0, z: brightness, w: 0)
            image = scale.outputImage ?? image
        }
        if let haze, haze.alpha > 0 {
            let color = CIColor(red: haze.red, green: haze.green, blue: haze.blue, alpha: haze.alpha)
            image = CIImage(color: color).composited(over: image)
        }
        return image.cropped(to: rect)
    }
}
