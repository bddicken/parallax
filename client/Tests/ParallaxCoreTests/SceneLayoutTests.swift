import Foundation
import Testing
@testable import ParallaxCore

@Suite struct SceneLayoutTests {
    let pip = NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)

    @Test func resizingTopLeftKeepsBottomRightFixed() {
        let r = pip.resized(dragging: .topLeft, dx: -0.1, dy: -0.05, keepAspect: false)
        #expect(abs(r.x + r.width - 0.7) < 1e-9 && abs(r.y + r.height - 0.7) < 1e-9)
        #expect(abs(r.width - 0.3) < 1e-9 && abs(r.height - 0.25) < 1e-9)
    }

    @Test func resizingWithAspectFollowsWidth() {
        let r = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
            .resized(dragging: .bottomRight, dx: 0.2, dy: 0, keepAspect: true)
        #expect(abs(r.width - 0.4) < 1e-9 && abs(r.height - 0.2) < 1e-9)
        #expect(r.x == 0.1 && r.y == 0.1)
    }

    @Test func resizingStopsAtCanvasEdge() {
        let r = pip.resized(dragging: .bottomRight, dx: 0.9, dy: 0.9, keepAspect: true)
        #expect(r.x + r.width <= 1 + 1e-9 && r.y + r.height <= 1 + 1e-9)
        #expect(abs(r.width - r.height) < 1e-9)
    }

    @Test func scalingKeepsCornerAnchor() {
        let topRight = LayoutPreset.pipTopRight.rect
        let bigger = topRight.scaled(by: 1.6)
        #expect(abs((bigger.x + bigger.width) - (topRight.x + topRight.width)) < 1e-9)
        #expect(abs(bigger.y - topRight.y) < 1e-9)
        #expect(abs(bigger.width - 0.4) < 1e-9)
    }

    @Test func snapsToCanvasCenterAndReportsGuide() {
        let snapper = Snapper(others: [])
        let (r, guides) = snapper.snap(NormalizedRect(x: 0.405, y: 0.3, width: 0.2, height: 0.2))
        #expect(abs(r.x - 0.4) < 1e-9)
        #expect(guides.contains(.vertical(0.5)))
    }

    @Test func snapsToOtherItemEdges() {
        let other = NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        let (r, _) = Snapper(others: [other]).snap(NormalizedRect(x: 0.405, y: 0.62, width: 0.1, height: 0.1))
        #expect(abs(r.x - 0.4) < 1e-9) // left edge meets the other's right edge
    }

    @Test func templatesPlaceCameraOverScreen() {
        let cam = UUID(), screen = UUID()
        let items = SceneTemplate.screenCameraTopRight.items(camera: cam, screen: screen)
        #expect(items.map(\.sourceID) == [screen, cam])
        #expect(items[1].frame == LayoutPreset.pipTopRight.rect)
        #expect(SceneTemplate.screenCameraTopLeft.items(camera: nil, screen: screen).count == 1)
    }

    @Test func decodesItemsSavedBeforeCornerRadiusExisted() throws {
        let json = """
        {"id":"\(UUID())","sourceID":"\(UUID())","frame":{"x":0,"y":0,"width":1,"height":1},
         "crop":{"top":0,"left":0,"bottom":0,"right":0},"contentMode":"fit","isVisible":true}
        """
        let item = try JSONDecoder().decode(SceneItem.self, from: Data(json.utf8))
        #expect(item.cornerRadius == 0 && !item.border.isEnabled)
    }
}

@Suite struct LayoutDragTests {
    let canvas = CGSize(width: 1600, height: 900)
    let background = SceneItem(sourceID: UUID(), frame: .full)
    let pip = SceneItem(sourceID: UUID(), frame: LayoutPreset.pipTopRight.rect)
    var items: [SceneItem] { [background, pip] }

    @Test func pressOnPipMovesTopmostItemEvenIfUnselected() throws {
        let drag = try #require(LayoutDrag(at: CGPoint(x: 1400, y: 100), canvas: canvas, items: items, selectedID: nil))
        #expect(drag.itemID == pip.id && drag.mode == .move)
    }

    @Test func pressOnSelectedCornerResizes() throws {
        let corner = pip.frame.denormalized(in: canvas).point(of: .bottomLeft)
        let drag = try #require(LayoutDrag(at: CGPoint(x: corner.x + 3, y: corner.y - 3), canvas: canvas, items: items, selectedID: pip.id))
        #expect(drag.mode == .resize(.bottomLeft))
        let (frame, _) = drag.frame(translation: CGSize(width: -160, height: 0), canvas: canvas)
        #expect(abs(frame.width - 0.35) < 1e-9)
        #expect(abs((frame.x + frame.width) - (pip.frame.x + pip.frame.width)) < 1e-9)
    }

    @Test func hiddenItemsAreNotHit() {
        var hidden = pip
        hidden.isVisible = false
        #expect(LayoutDrag(at: CGPoint(x: 1400, y: 100), canvas: canvas, items: [hidden], selectedID: nil) == nil)
    }

    @Test func movingSnapsToCanvasMarginAndCanBeDisabled() throws {
        let drag = try #require(LayoutDrag(at: CGPoint(x: 1400, y: 100), canvas: canvas, items: items, selectedID: nil))
        // Drag left so the PiP's left edge lands ~5pt off the left safe margin.
        let target = Snapper.margin * canvas.width + 5
        let dx = target - pip.frame.x * canvas.width
        let snapped = drag.frame(translation: CGSize(width: dx, height: 0), canvas: canvas)
        #expect(abs(snapped.frame.x - Snapper.margin) < 1e-9)
        #expect(snapped.guides.contains(.vertical(Snapper.margin)))
        let free = drag.frame(translation: CGSize(width: dx, height: 0), canvas: canvas, snapping: false)
        #expect(abs(free.frame.x - Snapper.margin) > 1e-3)
    }
}
