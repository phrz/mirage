import XCTest
import Metal
@testable import MirageCore

/// Client-side window drags stay where macOS lets a window go (the title bar below the menu bar, 40 pt of it reachable),
/// and a window layer's shadow stays attached to it, at rest and moved.
final class WindowDragTests: XCTestCase {
    // A 2× host display, 3000×2000 px, its menu bar 24 pt (48 px) tall.
    let display = PixelRect(x: 0, y: 0, width: 3000, height: 2000)
    var limits: WindowDragLimits { WindowDragLimits(display: display, menuBarBottom: 48, titleBar: 56, reach: 80) }

    func testClampKeepsTheTitleBarBelowTheMenuBarAndReachable() {
        let w = PixelRect(x: 400, y: 300, width: 1200, height: 800)
        XCTAssertEqual(limits.clamp(w), w, "inside: unchanged")
        XCTAssertEqual(limits.clamp(w.offset(0, -1000)).y, 48, "never above the menu bar's bottom")
        XCTAssertEqual(limits.clamp(w.offset(0, 5000)).y, 2000 - 56, "the title bar stays on the display at the bottom")
        XCTAssertEqual(limits.clamp(w.offset(-5000, 0)).maxX, 80, "40 pt of it stays at the left")
        XCTAssertEqual(limits.clamp(w.offset(5000, 0)).x, 3000 - 80, "and at the right")
        XCTAssertEqual(limits.clamp(w.offset(-300, -2000)), PixelRect(x: 100, y: 48, width: 1200, height: 800), "each axis on its own")
        // A window already partly above the limit (placed there by its app) is not snapped at mouse-down.
        let high = PixelRect(x: 400, y: 10, width: 1200, height: 800)
        XCTAssertEqual(limits.clamp(high, from: high), high)
        XCTAssertEqual(limits.clamp(high.offset(0, -50), from: high).y, 10, "but never pushed further out")
        XCTAssertEqual(limits.clamp(high.offset(0, 100), from: high).y, 110)
    }

    func testHostLimitsReadTheMenuBarFromTheWindowList() {
        let bar = ControlMessage.WindowInfo(id: 1, pid: 1, title: "Menubar", frame: PixelRect(x: 0, y: 0, width: 3000, height: 74), z: 0, level: 24, app: "Window Server")
        let status = ControlMessage.WindowInfo(id: 2, pid: 2, title: "", frame: PixelRect(x: 2800, y: 0, width: 60, height: 74), z: 1, level: 25)
        let menu = ControlMessage.WindowInfo(id: 3, pid: 3, title: "", frame: PixelRect(x: 100, y: 74, width: 400, height: 600), z: 2, level: 101)
        let win = ControlMessage.WindowInfo(id: 4, pid: 4, title: "Finder", frame: PixelRect(x: 0, y: 0, width: 800, height: 600), z: 3, level: 0)
        let l = WindowDragLimits.host(display: display, windows: [bar, status, menu, win], pxPerPoint: 2)
        XCTAssertEqual(l.menuBarBottom, 74, "a notched display's taller menu bar, from the list")
        XCTAssertEqual(l.titleBar, 56); XCTAssertEqual(l.reach, 80)
        XCTAssertEqual(WindowDragLimits.host(display: display, windows: [win], pxPerPoint: 2).menuBarBottom, 48, "none listed: a standard 24 pt bar")
    }

    /// The display layer's window-drag prediction: the window follows the pointer up to the menu bar and no further, and
    /// the host's window, which stops there too, confirms it.
    func testPredictedDragStopsAtTheMenuBar() {
        var p = Predictor()
        let frame = PixelRect(x: 400, y: 300, width: 1200, height: 800)
        p.beginDrag(windowID: 7, frame: frame, pointer: (1000, 320), inputSeq: 1, now: 0, limits: limits)
        p.dragPointer(windowID: 7, pointer: (1000, 120), inputSeq: 2, now: 16_000_000)
        XCTAssertEqual(p.displacements().first?.dy, -200, "inside the limits it follows the pointer")
        p.dragPointer(windowID: 7, pointer: (1100, -400), inputSeq: 3, now: 32_000_000)
        let d = p.displacements().first
        XCTAssertEqual(d?.dy, 48 - 300, "held at the menu bar however far the pointer goes")
        XCTAssertEqual(d?.dx, 100, "the other axis still follows")
        // The host's window is held at the menu bar as well (a copy-rect of exactly that move): confirmed, nothing left.
        p.hostCopyRect(windowID: 7, rect: frame, dx: 100, dy: -252, inputSeq: 3, now: 100_000_000)
        XCTAssertTrue(p.displacements().isEmpty)
        XCTAssertEqual(p.stats.mismatched, 0)
        // A host picture that reflects the input (not a copy-rect) puts the confirmed frame at the clamped place too.
        p.dragPointer(windowID: 7, pointer: (1100, -600), inputSeq: 4, now: 120_000_000)
        p.hostUpdate(inputSeq: 4, rect: PixelRect(x: 0, y: 0, width: 3000, height: 2000), now: 150_000_000)
        XCTAssertTrue(p.displacements().isEmpty)
        p.endDrag(windowID: 7)
        p.expire(now: 160_000_000)
        XCTAssertFalse(p.hasPending)
        XCTAssertEqual(p.stats.expired, 0)
    }

    /// The shadow is drawn from the window's own rect: the box is lowered by the offset, the mask is the window itself.
    func testShadowGeometryMasksTheWindowNotTheLoweredBox() {
        let s = LayerScene.Shadow.key(pxPerPoint: 2)
        let g = s.geometry(window: SIMD4(100, 100, 500, 400), scale: 0.5)
        XCTAssertEqual(g.mask, SIMD4(100, 100, 500, 400), "the window itself, unshifted")
        XCTAssertEqual(g.box, SIMD4(100, 110, 500, 410), "10 pt down: 20 px × 0.5")
        XCTAssertEqual(g.blur, 36)
        XCTAssertEqual(g.radius, 12)
        XCTAssertLessThanOrEqual(g.quad.y, g.box.y - g.blur); XCTAssertGreaterThanOrEqual(g.quad.w, g.box.w + g.blur)
    }

    /// The field bug: a strip as tall as the shadow's offset under the window's bottom edge was left bare (the shader
    /// masked the lowered box), a gap between the window and its shadow.
    func testShadowTouchesTheWindowsBottomEdge() throws {
        guard let ctx = MetalContext() else { throw XCTSkip("no Metal device") }
        let bg = Compositor(context: ctx); bg.configure(width: 400, height: 300)
        bg.applyTiles([.init(rect: PixelRect(x: 0, y: 0, width: 400, height: 300), format: .solid, data: Data([255, 255, 255, 255]))])   // white desktop
        let win = Compositor(context: ctx); win.layerID = 7; win.configure(width: 200, height: 100)
        win.applyTiles([.init(rect: PixelRect(x: 0, y: 0, width: 200, height: 100), format: .solid, data: Data([0, 0, 255, 255]))])
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 400, height: 300, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let t = ctx.device.makeTexture(descriptor: d)!
        func luma(_ x: Int, _ y: Int) -> Int {
            let cb = ctx.commandQueue.makeCommandBuffer()!; cb.commit(); cb.waitUntilCompleted()
            var p = [UInt8](repeating: 0, count: 4)
            t.getBytes(&p, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return Int(p[1])
        }
        for frame in [PixelRect(x: 100, y: 80, width: 200, height: 100), PixelRect(x: 137, y: 101, width: 200, height: 100)] {   // at rest, then moved
            let w = ControlMessage.WindowInfo(id: 7, pid: 1, title: "", frame: frame, z: 0, level: 0, layered: true)
            let plan = LayerScenePlan.plan([w], hasCanvas: { _ in true }, display: PixelRect(x: 0, y: 0, width: 400, height: 300), shadowMargin: 48)
            let scene = LayerScene(background: bg, items: plan.sceneItems(pxPerPoint: 1, canvas: { _ in win }), displacements: [], bandColors: [:])
            SceneRenderer.render(scene, context: ctx, target: t, dest: CGRect(x: 0, y: 0, width: 400, height: 300))
            let below = (1...9).map { luma(frame.x + 100, frame.maxY + $0) }   // the key shadow's offset is 10 px here
            XCTAssertTrue(below.allSatisfy { $0 < 200 }, "shadow right under the bottom edge at \(frame): \(below)")
            XCTAssertTrue(zip(below, below.dropFirst()).allSatisfy { $0 <= $1 + 1 }, "darkest at the edge, fading away: \(below)")
            XCTAssertEqual(luma(frame.x + 100, frame.maxY - 2), 0, "the window itself is not darkened (green 0)")
            XCTAssertGreaterThan(luma(frame.x + 100, frame.maxY + 60), 240, "the desktop far below is untouched")
        }
    }
}
