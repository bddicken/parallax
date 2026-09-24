import CoreGraphics
import Foundation

/// Starting layouts for a new scene.
public enum SceneTemplate: String, CaseIterable, Identifiable, Sendable {
    case blank
    case cameraOnly
    case screenOnly
    case screenCameraTopRight
    case screenCameraTopLeft
    case screenCameraBottomRight
    case screenCameraBottomLeft
    case sideBySide

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .blank: "Blank"
        case .cameraOnly: "Camera"
        case .screenOnly: "Screen"
        case .screenCameraTopRight: "Screen + Camera Top Right"
        case .screenCameraTopLeft: "Screen + Camera Top Left"
        case .screenCameraBottomRight: "Screen + Camera Bottom Right"
        case .screenCameraBottomLeft: "Screen + Camera Bottom Left"
        case .sideBySide: "Side by Side"
        }
    }

    public var needsCamera: Bool { self != .blank && self != .screenOnly }
    public var needsScreen: Bool { self != .blank && self != .cameraOnly }

    /// Items for the template, bottom to top. Missing sources are skipped.
    public func items(camera: UUID?, screen: UUID?) -> [SceneItem] {
        func cam(_ preset: LayoutPreset, radius: Double = 0.08) -> SceneItem? {
            camera.map { SceneItem(sourceID: $0, frame: preset.rect, contentMode: .fill, cornerRadius: radius) }
        }
        let fullScreen = screen.map { SceneItem(sourceID: $0) }
        switch self {
        case .blank: return []
        case .cameraOnly: return [cam(.fullscreen, radius: 0)].compactMap { $0 }
        case .screenOnly: return [fullScreen].compactMap { $0 }
        case .screenCameraTopRight: return [fullScreen, cam(.pipTopRight)].compactMap { $0 }
        case .screenCameraTopLeft: return [fullScreen, cam(.pipTopLeft)].compactMap { $0 }
        case .screenCameraBottomRight: return [fullScreen, cam(.pipBottomRight)].compactMap { $0 }
        case .screenCameraBottomLeft: return [fullScreen, cam(.pipBottomLeft)].compactMap { $0 }
        case .sideBySide:
            return [
                screen.map { SceneItem(sourceID: $0, frame: LayoutPreset.leftHalf.rect) },
                camera.map { SceneItem(sourceID: $0, frame: LayoutPreset.rightHalf.rect, contentMode: .fill) },
            ].compactMap { $0 }
        }
    }
}

public enum Corner: CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    var movesLeftEdge: Bool { self == .topLeft || self == .bottomLeft }
    var movesTopEdge: Bool { self == .topLeft || self == .topRight }
}

extension NormalizedRect {
    /// Resizes by dragging `corner` by (dx, dy) while the opposite corner
    /// stays put. With `keepAspect`, width drives and height follows.
    public func resized(dragging corner: Corner, dx: Double, dy: Double, keepAspect: Bool, minSize: Double = 0.02) -> NormalizedRect {
        let right = x + width, bottom = y + height
        var w = max(minSize, width + (corner.movesLeftEdge ? -dx : dx))
        var h = max(minSize, height + (corner.movesTopEdge ? -dy : dy))
        if keepAspect, width > 0 {
            h = w * height / width
            if h < minSize {
                h = minSize
                w = h * width / height
            }
        }
        // Don't grow past the canvas edge on the side being dragged.
        let maxW = corner.movesLeftEdge ? right : 1 - x
        let maxH = corner.movesTopEdge ? bottom : 1 - y
        if w > maxW || h > maxH {
            let scale = min(maxW / w, maxH / h)
            if keepAspect {
                w *= scale
                h *= scale
            } else {
                w = min(w, maxW)
                h = min(h, maxH)
            }
        }
        return NormalizedRect(
            x: corner.movesLeftEdge ? right - w : x,
            y: corner.movesTopEdge ? bottom - h : y,
            width: w, height: h)
    }

    /// Scales about the nearest canvas corner (or center), so a PiP in the top
    /// right stays in the top right as it grows or shrinks.
    public func scaled(by factor: Double) -> NormalizedRect {
        let w = min(1, max(0.02, width * factor)), h = min(1, max(0.02, height * factor))
        let cx = x + width / 2, cy = y + height / 2
        func anchor(_ origin: Double, _ size: Double, _ center: Double, _ newSize: Double) -> Double {
            if abs(center - 0.5) < 0.05 { return center - newSize / 2 }
            // Keep the gap to the near edge constant.
            return center < 0.5 ? origin : (origin + size) - newSize
        }
        return NormalizedRect(x: anchor(x, width, cx, w), y: anchor(y, height, cy, h), width: w, height: h).clamped()
    }
}

/// Snaps a moving rect's edges and center to the canvas and to other items.
public struct Snapper: Sendable {
    public enum Guide: Hashable, Sendable {
        case vertical(Double)
        case horizontal(Double)
    }

    public static let margin = 0.025
    public var threshold: Double
    private var xTargets: [Double]
    private var yTargets: [Double]

    public init(others: [NormalizedRect], threshold: Double = 0.012) {
        self.threshold = threshold
        let canvas = [0, Self.margin, 0.5, 1 - Self.margin, 1]
        xTargets = canvas + others.flatMap { [$0.x, $0.x + $0.width / 2, $0.x + $0.width] }
        yTargets = canvas + others.flatMap { [$0.y, $0.y + $0.height / 2, $0.y + $0.height] }
    }

    public func snap(_ rect: NormalizedRect) -> (rect: NormalizedRect, guides: [Guide]) {
        var r = rect
        var guides: [Guide] = []
        if let (offset, line) = best([rect.x, rect.x + rect.width / 2, rect.x + rect.width], xTargets) {
            r.x += offset
            guides.append(.vertical(line))
        }
        if let (offset, line) = best([rect.y, rect.y + rect.height / 2, rect.y + rect.height], yTargets) {
            r.y += offset
            guides.append(.horizontal(line))
        }
        return (r, guides)
    }

    private func best(_ edges: [Double], _ targets: [Double]) -> (Double, Double)? {
        var result: (Double, Double)?
        var distance = threshold
        for edge in edges {
            for target in targets where abs(target - edge) < distance {
                distance = abs(target - edge)
                result = (target - edge, target)
            }
        }
        return result
    }
}

/// One click-drag in the preview: picks what to move or resize from where the
/// pointer went down, then maps pointer travel to a new frame. Canvas
/// coordinates are points, top-left origin.
public struct LayoutDrag: Sendable {
    public enum Mode: Equatable, Sendable {
        case move
        case resize(Corner)
    }

    public let itemID: UUID
    public let mode: Mode
    public let startFrame: NormalizedRect
    private let snapper: Snapper

    /// Starts a drag: a corner handle of the selected item wins, then the
    /// topmost visible item under the point. Nil means empty canvas.
    public init?(at point: CGPoint, canvas: CGSize, items: [SceneItem], selectedID: UUID?, handleRadius: CGFloat = 9) {
        let visible = items.filter(\.isVisible)
        if let selected = visible.first(where: { $0.id == selectedID }),
           let corner = Self.corner(at: point, of: selected.frame, canvas: canvas, radius: handleRadius) {
            itemID = selected.id
            mode = .resize(corner)
            startFrame = selected.frame
        } else if let hit = Self.item(at: point, canvas: canvas, items: visible) {
            itemID = hit.id
            mode = .move
            startFrame = hit.frame
        } else {
            return nil
        }
        let id = itemID
        snapper = Snapper(others: visible.filter { $0.id != id }.map(\.frame))
    }

    /// The frame after the pointer has moved `translation` points.
    public func frame(translation: CGSize, canvas: CGSize, keepAspect: Bool = true, snapping: Bool = true) -> (frame: NormalizedRect, guides: [Snapper.Guide]) {
        let dx = translation.width / canvas.width, dy = translation.height / canvas.height
        switch mode {
        case .move:
            var f = startFrame
            f.x += dx
            f.y += dy
            f = f.clamped()
            guard snapping else { return (f, []) }
            let (snapped, guides) = snapper.snap(f)
            return (snapped.clamped(), guides)
        case .resize(let corner):
            return (startFrame.resized(dragging: corner, dx: dx, dy: dy, keepAspect: keepAspect), [])
        }
    }

    public static func item(at point: CGPoint, canvas: CGSize, items: [SceneItem]) -> SceneItem? {
        items.last { $0.isVisible && $0.frame.denormalized(in: canvas).contains(point) }
    }

    public static func corner(at point: CGPoint, of frame: NormalizedRect, canvas: CGSize, radius: CGFloat) -> Corner? {
        let rect = frame.denormalized(in: canvas)
        return Corner.allCases.first { hypot(rect.point(of: $0).x - point.x, rect.point(of: $0).y - point.y) <= radius }
    }
}

extension CGRect {
    public func point(of corner: Corner) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: minX, y: minY)
        case .topRight: CGPoint(x: maxX, y: minY)
        case .bottomLeft: CGPoint(x: minX, y: maxY)
        case .bottomRight: CGPoint(x: maxX, y: maxY)
        }
    }
}
