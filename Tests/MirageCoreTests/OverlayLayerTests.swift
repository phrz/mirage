import XCTest
import Metal
@testable import MirageCore

/// The compositor model (host tunable compositorModel=1): a desktop-only display layer, every normal window a layer, and one
/// overlay layer on top (the menu bar, the Dock, menus) that covers the whole display but is transparent elsewhere. Every
/// viewer (Mac, iOS) draws, hit-tests and stacks it through this shared code.
final class OverlayLayerTests: XCTestCase {
    private let display = PixelRect(x: 0, y: 0, width: 400, height: 300)

    private func overlay() -> ControlMessage.WindowInfo {
        ControlMessage.WindowInfo(id: ControlMessage.WindowInfo.overlayID, pid: 0, title: "", frame: display, z: -1,
                                  level: ControlMessage.WindowInfo.overlayLevel, layered: true, app: "Mirage overlay", excludedFrom: 1)
    }
    private func window(_ id: UInt32, _ frame: PixelRect, z: Int, layered: Bool = true, level: Int = 0) -> ControlMessage.WindowInfo {
        ControlMessage.WindowInfo(id: id, pid: Int32(id), title: "w\(id)", frame: frame, z: z, level: level, layered: layered, excludedFrom: layered ? 1 : nil)
    }

    func testOverlayHidesNothingBehindIt() {
        XCTAssertFalse(overlay().hidesBehind, "transparent but for the chrome: the desktop and windows show through")
        XCTAssertTrue(window(5, PixelRect(x: 10, y: 10, width: 50, height: 50), z: 0).hidesBehind)
    }

    func testWindowsUnderTheOverlayAreVisible() {
        let a = window(5, PixelRect(x: 20, y: 40, width: 200, height: 150), z: 0)
        let b = window(6, PixelRect(x: 100, y: 80, width: 200, height: 150), z: 1)
        let plan = LayerScenePlan.plan([overlay(), a, b], hasCanvas: { _ in true }, display: display, shadowMargin: 24)
        XCTAssertEqual(plan.entries.map(\.kind), [.layer, .layer, .layer])
        XCTAssertEqual(plan.entries[1].coveredBy, [], "the overlay covers nothing")
        XCTAssertTrue(plan.entries[1].visible)
        XCTAssertEqual(plan.entries[2].coveredBy, [5], "z-order: only the window in front")
        XCTAssertTrue(plan.entries[2].visible)
    }

    func testHitTestSkipsTheOverlayAndKeepsZOrder() {
        let front = window(5, PixelRect(x: 20, y: 40, width: 200, height: 150), z: 0)
        let back = window(6, PixelRect(x: 100, y: 80, width: 200, height: 150), z: 1)
        let list = [overlay(), front, back]
        let area = display.area
        XCTAssertEqual(WindowHitTest.window(at: 150, 100, in: list, displayArea: area)?.id, 5, "the front window, not the overlay above it")
        XCTAssertEqual(WindowHitTest.window(at: 250, 200, in: list, displayArea: area)?.id, 6)
        XCTAssertNil(WindowHitTest.window(at: 5, 5, in: list, displayArea: area), "the menu bar is the overlay's: no window")
        XCTAssertEqual(WindowHitTest.press(at: 5, 5, in: list, displayArea: area, pxPerPoint: 1, plain: true), .none)
    }

    func testPressRules() {
        let ppp = 2.0   // title bar 56 px, traffic lights 160 px
        let layer = window(5, PixelRect(x: 0, y: 40, width: 380, height: 200), z: 0)
        let carried = window(7, PixelRect(x: 0, y: 0, width: 400, height: 300), z: 1, layered: false)
        let list = [overlay(), layer, carried]
        func press(_ x: Int, _ y: Int, plain: Bool = true, first: Bool = true) -> WindowHitTest.Press {
            WindowHitTest.press(at: x, y, in: list, displayArea: display.area, pxPerPoint: ppp, plain: plain, firstClick: first)
        }
        XCTAssertEqual(press(200, 50), .layerTitleBar(id: 5, frame: layer.frame), "a layer's title bar right of the lights holds the press")
        XCTAssertEqual(press(200, 50).raises, 5)
        XCTAssertEqual(press(100, 50), .layer(id: 5, raise: true), "on the traffic lights: a click")
        XCTAssertEqual(press(200, 50, plain: false), .layer(id: 5, raise: false), "⌘-click: neither drag nor raise")
        XCTAssertEqual(press(200, 50, first: false), .layer(id: 5, raise: true), "a double click's second press is no drag")
        XCTAssertEqual(press(200, 150), .layer(id: 5, raise: true))
        XCTAssertEqual(press(390, 20), .displayTitleBar(id: 7, frame: carried.frame), "a window the display layer carries: a predicted drag")
        XCTAssertNil(press(390, 20).raises)
        XCTAssertEqual(press(390, 280), .display(id: 7))
        // A layer above the normal level (a panel) is never raised or dragged locally.
        let panel = window(8, PixelRect(x: 0, y: 40, width: 380, height: 200), z: 0, level: 3)
        XCTAssertEqual(WindowHitTest.press(at: 200, 50, in: [overlay(), panel], displayArea: display.area, pxPerPoint: ppp, plain: true), .layer(id: 8, raise: false))
    }

    /// Rendered: the overlay's chrome is on top, a window layer shows through its transparent part, the desktop elsewhere,
    /// and the overlay's frame (the whole display) casts no shadow over anything.
    func testRenderedThroughTheOverlay() throws {
        guard let ctx = MetalContext() else { throw XCTSkip("no Metal device") }
        func solid(_ c: Compositor, _ rect: PixelRect, _ bgra: (UInt8, UInt8, UInt8, UInt8)) {
            c.applyTiles([.init(rect: rect, format: .solid, data: Data([bgra.0, bgra.1, bgra.2, bgra.3]))])
        }
        let bg = Compositor(context: ctx); bg.configure(width: 400, height: 300)
        solid(bg, display, (255, 0, 0, 255))                                                           // desktop: blue
        let win = Compositor(context: ctx); win.layerID = 5; win.hasAlpha = true; win.configure(width: 200, height: 150)
        solid(win, PixelRect(x: 0, y: 0, width: 200, height: 150), (0, 0, 255, 255))                 // window: red
        let ov = Compositor(context: ctx); ov.layerID = ControlMessage.WindowInfo.overlayID; ov.hasAlpha = true; ov.configure(width: 400, height: 300)
        solid(ov, display, (0, 0, 0, 0))                                                               // transparent…
        solid(ov, PixelRect(x: 0, y: 0, width: 400, height: 20), (0, 255, 0, 255))                    // …but the menu bar: green
        let windows = [overlay(), window(5, PixelRect(x: 100, y: 0, width: 200, height: 150), z: 0)]
        let canvases: [UInt32: Compositor] = [5: win, ControlMessage.WindowInfo.overlayID: ov]
        let plan = LayerScenePlan.plan(windows, hasCanvas: { canvases[$0] != nil }, display: display, shadowMargin: 24)
        let scene = LayerScene(background: bg, items: plan.sceneItems(pxPerPoint: 1, canvas: { canvases[$0] }), displacements: [], bandColors: [:])
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 400, height: 300, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let t = ctx.device.makeTexture(descriptor: d)!
        SceneRenderer.render(scene, context: ctx, target: t, dest: CGRect(x: 0, y: 0, width: 400, height: 300))
        let cb = ctx.commandQueue.makeCommandBuffer()!; cb.commit(); cb.waitUntilCompleted()
        func px(_ x: Int, _ y: Int) -> [UInt8] {
            var p = [UInt8](repeating: 0, count: 4)
            t.getBytes(&p, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return Array(p[0..<3])
        }
        XCTAssertEqual(px(200, 10), [0, 255, 0], "the menu bar over the window")
        XCTAssertEqual(px(200, 80), [0, 0, 255], "the window through the overlay")
        XCTAssertEqual(px(20, 200), [255, 0, 0], "the desktop through the overlay, undarkened")
        XCTAssertEqual(px(390, 290), [255, 0, 0])
    }
}
