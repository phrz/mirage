import XCTest
import Metal
@testable import MirageCore

/// The composited scene (DESIGN §3.2): a layered window stays visible wherever the host moves it, and no
/// window the display layer carries can paint the display layer over it unless it is a real cut-out in front.
final class SceneTests: XCTestCase {
    private func solid(_ c: Compositor, _ rect: PixelRect, bgra: (UInt8, UInt8, UInt8, UInt8)) {
        let data = Data([bgra.0, bgra.1, bgra.2, bgra.3])
        c.applyTiles([.init(rect: rect, format: .solid, data: data)])
    }
    private func target(_ ctx: MetalContext, _ w: Int, _ h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        return ctx.device.makeTexture(descriptor: d)!
    }
    private func pixel(_ ctx: MetalContext, _ t: MTLTexture, _ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
        let cb = ctx.commandQueue.makeCommandBuffer()!; cb.commit(); cb.waitUntilCompleted()
        var p = [UInt8](repeating: 0, count: 4)
        t.getBytes(&p, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (p[0], p[1], p[2])
    }
    private func render(_ ctx: MetalContext, bg: Compositor, layers: [UInt32: Compositor], windows: [ControlMessage.WindowInfo], into t: MTLTexture) -> LayerScenePlan {
        let plan = LayerScenePlan.plan(windows, hasCanvas: { layers[$0] != nil }, display: PixelRect(x: 0, y: 0, width: bg.width, height: bg.height), shadowMargin: 48)
        let scene = LayerScene(background: bg, items: plan.sceneItems(pxPerPoint: 1, canvas: { layers[$0] }), displacements: [], bandColors: [:])
        SceneRenderer.render(scene, context: ctx, target: t, dest: CGRect(x: 0, y: 0, width: t.width, height: t.height))
        return plan
    }

    func testLayeredWindowStaysVisibleAcrossAHostMoveAndUnderAnOverlay() throws {
        guard let ctx = MetalContext() else { throw XCTSkip("no Metal device") }
        let bg = Compositor(context: ctx); bg.configure(width: 400, height: 300)
        solid(bg, PixelRect(x: 0, y: 0, width: 400, height: 300), bgra: (255, 0, 0, 255))            // desktop: blue
        let win = Compositor(context: ctx); win.layerID = 7; win.hasAlpha = true; win.configure(width: 100, height: 80)
        solid(win, PixelRect(x: 0, y: 0, width: 100, height: 80), bgra: (0, 0, 255, 255))           // window: red
        let t = target(ctx, 400, 300)
        // Front to back: the menu bar (a real cut-out), a full-screen transparent overlay at the floating level
        // (the field regression: even if it were marked cut-out it must not paint over the window), the window.
        let menubar = ControlMessage.WindowInfo(id: 1, pid: 1, title: "", frame: PixelRect(x: 0, y: 0, width: 400, height: 20), z: 0, level: 24, cutout: true)
        let overlay = ControlMessage.WindowInfo(id: 2, pid: 2, title: "", frame: PixelRect(x: 0, y: 0, width: 400, height: 300), z: 1, level: 3, cutout: true)
        var w = ControlMessage.WindowInfo(id: 7, pid: 3, title: "bench", frame: PixelRect(x: 50, y: 40, width: 100, height: 80), z: 2, level: 0, layered: true)
        var plan = render(ctx, bg: bg, layers: [7: win], windows: [menubar, overlay, w], into: t)
        XCTAssertEqual(pixel(ctx, t, 100, 80).r, 255, "window drawn at its frame")
        XCTAssertEqual(pixel(ctx, t, 300, 200).b, 255, "desktop elsewhere")
        XCTAssertEqual(plan.entries.first { $0.id == 2 }?.kind, .displayOnly, "a desktop-sized window above the normal level is never a cut-out")
        XCTAssertTrue(plan.entries.first { $0.id == 7 }!.visible)
        // The host moves the window (a delta in the list): it is drawn at the new frame, and the old place shows the desktop.
        let list = ControlMessage.WindowList(captureSeq: 1, windows: [menubar, overlay, w])
        w.frame = PixelRect(x: 250, y: 180, width: 100, height: 80)
        let moved = ControlMessage.WindowList.delta(from: list.windows, to: [menubar, overlay, w], captureSeq: 2)!.apply(to: list.windows)
        plan = render(ctx, bg: bg, layers: [7: win], windows: moved, into: t)
        XCTAssertEqual(pixel(ctx, t, 300, 220).r, 255, "window drawn at the moved frame")
        XCTAssertEqual(pixel(ctx, t, 100, 80).b, 255, "old frame shows the desktop")
        XCTAssertTrue(plan.entries.first { $0.id == 7 }!.visible)
    }

    func testMenuCutoutDrawsOnlyWhereItOverlapsALayer() throws {
        guard let ctx = MetalContext() else { throw XCTSkip("no Metal device") }
        let bg = Compositor(context: ctx); bg.configure(width: 400, height: 300)
        solid(bg, PixelRect(x: 0, y: 0, width: 400, height: 300), bgra: (255, 0, 0, 255))
        solid(bg, PixelRect(x: 80, y: 60, width: 60, height: 100), bgra: (0, 255, 0, 255))             // the menu, in the display layer: green
        let win = Compositor(context: ctx); win.layerID = 7; win.hasAlpha = true; win.configure(width: 100, height: 80)
        solid(win, PixelRect(x: 0, y: 0, width: 100, height: 80), bgra: (0, 0, 255, 255))
        let t = target(ctx, 400, 300)
        let menu = ControlMessage.WindowInfo(id: 9, pid: 3, title: "", frame: PixelRect(x: 80, y: 60, width: 60, height: 100), z: 0, level: 101, cutout: true)
        let w = ControlMessage.WindowInfo(id: 7, pid: 3, title: "", frame: PixelRect(x: 50, y: 40, width: 100, height: 80), z: 1, level: 0, layered: true)
        let plan = render(ctx, bg: bg, layers: [7: win], windows: [menu, w], into: t)
        XCTAssertEqual(pixel(ctx, t, 100, 80).g, 255, "the menu sits above the window")
        XCTAssertEqual(pixel(ctx, t, 60, 50).r, 255, "the window around it")
        XCTAssertEqual(plan.entries.first { $0.id == 9 }?.clips, [PixelRect(x: 80, y: 60, width: 60, height: 100)], "clipped to the overlap with the window and its shadow")
        XCTAssertEqual(pixel(ctx, t, 100, 150).g, 255, "below the window the display layer shows the menu itself")
    }

    func testHostLayeredWithoutCanvasIsReportedNotHidden() {
        let w = ControlMessage.WindowInfo(id: 7, pid: 3, title: "", frame: PixelRect(x: 0, y: 0, width: 10, height: 10), z: 0, level: 0, layered: true)
        let plan = LayerScenePlan.plan([w], hasCanvas: { _ in false }, display: PixelRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(plan.entries[0].kind, .missing)
        XCTAssertFalse(plan.entries[0].visible)
        XCTAssertNotNil(plan.entries[0].why)
    }
}
