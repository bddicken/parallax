import CoreGraphics

/// A rectangle expressed as fractions of the output canvas, top-left origin.
public struct NormalizedRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public func denormalized(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }

    /// Keeps the rect at least `minSize` and fully on the canvas.
    public func clamped(minSize: Double = 0.02) -> NormalizedRect {
        let w = min(max(width, minSize), 1)
        let h = min(max(height, minSize), 1)
        return NormalizedRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
    }
}

/// Fractions of the source trimmed from each edge.
public struct CropInsets: Codable, Hashable, Sendable {
    public var top: Double = 0
    public var left: Double = 0
    public var bottom: Double = 0
    public var right: Double = 0

    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let none = CropInsets()
}

public enum ContentMode: String, Codable, CaseIterable, Sendable {
    case fit, fill, stretch
}

public enum LayoutPreset: String, CaseIterable, Identifiable, Sendable {
    case fullscreen, leftHalf, rightHalf, pipTopLeft, pipTopRight, pipBottomLeft, pipBottomRight

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fullscreen: "Fullscreen"
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .pipTopLeft: "PiP Top Left"
        case .pipTopRight: "PiP Top Right"
        case .pipBottomLeft: "PiP Bottom Left"
        case .pipBottomRight: "PiP Bottom Right"
        }
    }

    public var rect: NormalizedRect {
        let size = 0.25, margin = 0.025
        // PiP height is in canvas fractions, so a 16:9 box on a 16:9 canvas.
        let far = 1 - size - margin
        switch self {
        case .fullscreen: return .full
        case .leftHalf: return NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: return NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .pipTopLeft: return NormalizedRect(x: margin, y: margin, width: size, height: size)
        case .pipTopRight: return NormalizedRect(x: far, y: margin, width: size, height: size)
        case .pipBottomLeft: return NormalizedRect(x: margin, y: far, width: size, height: size)
        case .pipBottomRight: return NormalizedRect(x: far, y: far, width: size, height: size)
        }
    }
}

/// Where to sample from a source and where to draw it, both top-left origin.
/// Fill shrinks `sourceRect` to the frame's aspect; fit shrinks `destRect` to
/// the source's aspect, so neither needs clipping.
public struct Placement: Equatable, Sendable {
    public var sourceRect: CGRect
    public var destRect: CGRect

    public static func compute(sourceSize: CGSize, crop: CropInsets, frame: CGRect, mode: ContentMode) -> Placement? {
        let cropped = CGRect(
            x: sourceSize.width * crop.left,
            y: sourceSize.height * crop.top,
            width: sourceSize.width * (1 - crop.left - crop.right),
            height: sourceSize.height * (1 - crop.top - crop.bottom)
        )
        guard cropped.width > 0, cropped.height > 0, frame.width > 0, frame.height > 0 else { return nil }

        let srcAspect = cropped.width / cropped.height
        let dstAspect = frame.width / frame.height
        switch mode {
        case .stretch:
            return Placement(sourceRect: cropped, destRect: frame)
        case .fit:
            var dest = frame
            if srcAspect > dstAspect {
                dest.size.height = frame.width / srcAspect
                dest.origin.y = frame.midY - dest.height / 2
            } else {
                dest.size.width = frame.height * srcAspect
                dest.origin.x = frame.midX - dest.width / 2
            }
            return Placement(sourceRect: cropped, destRect: dest)
        case .fill:
            var src = cropped
            if srcAspect > dstAspect {
                src.size.width = cropped.height * dstAspect
                src.origin.x = cropped.midX - src.width / 2
            } else {
                src.size.height = cropped.width / dstAspect
                src.origin.y = cropped.midY - src.height / 2
            }
            return Placement(sourceRect: src, destRect: frame)
        }
    }
}
