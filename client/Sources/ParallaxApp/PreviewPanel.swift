import AppKit
import AVFoundation
import ParallaxCore
import SwiftUI

/// The program output with direct manipulation:
/// - click a source to select it, or drag any source to move it
/// - drag a corner handle to resize (aspect kept; hold Shift for free resize)
/// - edges snap to the canvas, safe margins, and other sources (hold ⌘ to disable)
/// - arrow keys nudge (Shift for bigger steps), Delete removes
struct PreviewPanel: View {
    @Environment(AppModel.self) private var model
    @State private var drag: LayoutDrag?
    @State private var guides: [Snapper.Guide] = []
    @FocusState private var focused: Bool

    private static let handleSize: CGFloat = 10
    private static let handleHitRadius: CGFloat = 9

    var body: some View {
        GeometryReader { geo in
            let canvas = fittedCanvas(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                ZStack(alignment: .topLeading) {
                    PreviewLayerView(layer: model.engine.preview.layer)
                    overlay(size: canvas.size)
                        .allowsHitTesting(false)
                }
                .frame(width: canvas.width, height: canvas.height)
                .contentShape(Rectangle())
                .gesture(canvasGesture(size: canvas.size))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): updateCursor(at: p, size: canvas.size)
                    case .ended: NSCursor.arrow.set()
                    }
                }
                .contextMenu { contextMenu }
                .offset(x: canvas.minX, y: canvas.minY)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard model.selectedItemID != nil else { return .ignored }
            let step = press.modifiers.contains(.shift) ? 0.05 : 0.005
            switch press.key {
            case .leftArrow: model.nudgeSelected(dx: -step, dy: 0)
            case .rightArrow: model.nudgeSelected(dx: step, dy: 0)
            case .upArrow: model.nudgeSelected(dx: 0, dy: -step)
            default: model.nudgeSelected(dx: 0, dy: step)
            }
            return .handled
        }
        .onDeleteCommand {
            if let id = model.selectedItemID { model.removeItem(id) }
        }
        .onExitCommand { model.selectedItemID = nil }
    }

    // MARK: Drawing

    @ViewBuilder
    private func overlay(size: CGSize) -> some View {
        ForEach(guides, id: \.self) { guide in
            switch guide {
            case .vertical(let x):
                Rectangle().fill(Color.pink).frame(width: 1, height: size.height).offset(x: x * size.width)
            case .horizontal(let y):
                Rectangle().fill(Color.pink).frame(width: size.width, height: 1).offset(y: y * size.height)
            }
        }
        if let item = model.selectedItem, item.isVisible {
            let rect = item.frame.denormalized(in: size)
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            ForEach(Corner.allCases, id: \.self) { corner in
                let p = rect.point(of: corner)
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: Self.handleSize, height: Self.handleSize)
                    .offset(x: p.x - Self.handleSize / 2, y: p.y - Self.handleSize / 2)
            }
            if let name = model.profile.videoSource(item.sourceID)?.name {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .offset(x: rect.minX + Self.handleSize, y: rect.minY >= 22 ? rect.minY - 22 : rect.maxY + 6)
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let item = model.selectedItem {
            Menu("Layout") {
                ForEach(LayoutPreset.allCases) { preset in
                    Button(preset.title) { model.updateItem(item.id, undo: "Apply Layout") { $0.frame = preset.rect } }
                }
            }
            Button(item.isVisible ? "Hide" : "Show") { model.updateItem(item.id, undo: "Toggle Visibility") { $0.isVisible.toggle() } }
            Divider()
            Button("Bring Forward") { model.moveItem(item.id, by: 1) }
            Button("Send Backward") { model.moveItem(item.id, by: -1) }
            Divider()
            Button("Remove from Scene", role: .destructive) { model.removeItem(item.id) }
        } else {
            Text("Select a source to edit it")
        }
    }

    // MARK: Interaction

    private func canvasGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                focused = true
                if drag == nil {
                    drag = LayoutDrag(at: value.startLocation, canvas: size, items: model.programScene?.items ?? [],
                                      selectedID: model.selectedItemID, handleRadius: Self.handleHitRadius)
                    model.selectedItemID = drag?.itemID
                }
                guard let drag, value.translation != .zero else { return }
                let flags = NSEvent.modifierFlags
                let (frame, lines) = drag.frame(translation: value.translation, canvas: size,
                                                keepAspect: !flags.contains(.shift), snapping: !flags.contains(.command))
                guides = lines
                let undoName = drag.mode == .move ? "Move Source" : "Resize Source"
                model.updateItem(drag.itemID, undo: undoName) { $0.frame = frame }
            }
            .onEnded { _ in
                drag = nil
                guides = []
            }
    }

    private func updateCursor(at location: CGPoint, size: CGSize) {
        guard drag == nil else { return }
        let items = model.programScene?.items ?? []
        if let item = model.selectedItem, item.isVisible,
           let corner = LayoutDrag.corner(at: location, of: item.frame, canvas: size, radius: Self.handleHitRadius) {
            let position: NSCursor.FrameResizePosition = switch corner {
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            NSCursor.frameResize(position: position, directions: .all).set()
        } else if LayoutDrag.item(at: location, canvas: size, items: items) != nil {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func fittedCanvas(in size: CGSize) -> CGRect {
        let inset: CGFloat = 16
        let avail = CGSize(width: max(1, size.width - inset * 2), height: max(1, size.height - inset * 2))
        let aspect = Double(model.profile.output.width) / Double(model.profile.output.height)
        var w = avail.width, h = avail.width / aspect
        if h > avail.height {
            h = avail.height
            w = h * aspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
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
