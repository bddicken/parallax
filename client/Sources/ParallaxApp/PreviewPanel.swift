import AppKit
import AVFoundation
import ParallaxCore
import SwiftUI

/// The program output, with direct manipulation of the selected source:
/// click to select, drag to move, drag the corner to resize (hold Shift to
/// ignore aspect ratio).
struct PreviewPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let canvas = fittedCanvas(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                PreviewLayerView(layer: model.engine.preview.layer)
                    .frame(width: canvas.width, height: canvas.height)
                    .offset(x: canvas.minX, y: canvas.minY)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        select(at: value.location, canvas: canvas.size)
                    })
                if let item = model.selectedItem, item.isVisible {
                    SelectionOverlay(item: item, canvas: canvas.size)
                        .offset(x: canvas.minX, y: canvas.minY)
                }
            }
        }
        .frame(minHeight: 300)
    }

    private func fittedCanvas(in size: CGSize) -> CGRect {
        let inset: CGFloat = 12
        let avail = CGSize(width: max(1, size.width - inset * 2), height: max(1, size.height - inset * 2))
        let aspect = Double(model.profile.output.width) / Double(model.profile.output.height)
        var w = avail.width, h = avail.width / aspect
        if h > avail.height {
            h = avail.height
            w = h * aspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func select(at point: CGPoint, canvas: CGSize) {
        let x = point.x / canvas.width, y = point.y / canvas.height
        let hit = model.programScene?.items.last { item in
            item.isVisible && x >= item.frame.x && x <= item.frame.x + item.frame.width
                && y >= item.frame.y && y <= item.frame.y + item.frame.height
        }
        model.selectedItemID = hit?.id
    }
}

private struct SelectionOverlay: View {
    @Environment(AppModel.self) private var model
    let item: SceneItem
    let canvas: CGSize
    @State private var dragStart: NormalizedRect?

    private static let snapDistance = 0.012

    var body: some View {
        let rect = item.frame.denormalized(in: canvas)
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .background(Color.accentColor.opacity(0.06))
                .contentShape(Rectangle())
                .gesture(moveGesture)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: 12, height: 12)
                .offset(x: 6, y: 6)
                .gesture(resizeGesture)
                .onHover { inside in
                    if inside { NSCursor.frameResize(position: .bottomRight, directions: .all).push() } else { NSCursor.pop() }
                }
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? item.frame
                dragStart = start
                var f = start
                f.x = snap(start.x + value.translation.width / canvas.width, size: f.width)
                f.y = snap(start.y + value.translation.height / canvas.height, size: f.height)
                model.updateItem(item.id) { $0.frame = f.clamped() }
            }
            .onEnded { _ in dragStart = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? item.frame
                dragStart = start
                var f = start
                f.width = max(0.02, start.width + value.translation.width / canvas.width)
                if NSEvent.modifierFlags.contains(.shift) {
                    f.height = max(0.02, start.height + value.translation.height / canvas.height)
                } else {
                    f.height = f.width * start.height / start.width
                }
                model.updateItem(item.id) { $0.frame = f.clamped() }
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Snaps an edge or the center to the canvas edges and center line.
    private func snap(_ origin: Double, size: Double) -> Double {
        for target in [0, 0.5 - size / 2, 1 - size] where abs(origin - target) < Self.snapDistance {
            return target
        }
        return origin
    }
}

struct PreviewLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.hosted = layer
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {}

    final class HostView: NSView {
        var hosted: CALayer? {
            didSet {
                wantsLayer = true
                layer?.backgroundColor = .black
                if let hosted { layer?.addSublayer(hosted) }
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}
