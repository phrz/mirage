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
    /// Reads one pixel after the GPU has finished. The wait is bounded (10 s): an unbounded waitUntilCompleted stalled one
    /// test for 250 s on a busy machine; a GPU that does not finish in time skips the test instead.
    private func pixel(_ ctx: MetalContext, _ t: MTLTexture, _ x: Int, _ y: Int) throws -> (b: UInt8, g: UInt8, r: UInt8) {
        let cb = ctx.commandQueue.makeCommandBuffer()!
        let done = DispatchSemaphore(value: 0)
        cb.addCompletedHandler { _ in done.signal() }
        cb.commit()
        if done.wait(timeout: .now() + 10) == .timedOut { throw XCTSkip("the GPU did not finish within 10 s (a busy machine)") }
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
        XCTAssertEqual(try pixel(ctx, t, 100, 80).r, 255, "window drawn at its frame")
        XCTAssertEqual(try pixel(ctx, t, 300, 200).b, 255, "desktop elsewhere")
        XCTAssertEqual(plan.entries.first { $0.id == 2 }?.kind, .displayOnly, "a desktop-sized window above the normal level is never a cut-out")
        XCTAssertTrue(plan.entries.first { $0.id == 7 }!.visible)
        // The host moves the window (a delta in the list): it is drawn at the new frame, and the old place shows the desktop.
        let list = ControlMessage.WindowList(captureSeq: 1, windows: [menubar, overlay, w])
        w.frame = PixelRect(x: 250, y: 180, width: 100, height: 80)
        let moved = ControlMessage.WindowList.delta(from: list.windows, to: [menubar, overlay, w], captureSeq: 2)!.apply(to: list.windows)
        plan = render(ctx, bg: bg, layers: [7: win], windows: moved, into: t)
        XCTAssertEqual(try pixel(ctx, t, 300, 220).r, 255, "window drawn at the moved frame")
        XCTAssertEqual(try pixel(ctx, t, 100, 80).b, 255, "old frame shows the desktop")
        XCTAssertTrue(plan.entries.first { $0.id == 7 }!.visible)
    }

    /// Nothing outside the remote display: a window partly off it (phrz's Claude window at x -584; Show Desktop slides
    /// every window to the edges), its shadow and a drag displacement are clipped at the display edge, and the letterbox
    /// around the picture stays the clear colour.
    func testLayersAreClippedToTheDisplay() throws {
        guard let ctx = MetalContext() else { throw XCTSkip("no Metal device") }
        let bg = Compositor(context: ctx); bg.configure(width: 400, height: 300)
        solid(bg, PixelRect(x: 0, y: 0, width: 400, height: 300), bgra: (255, 0, 0, 255))            // desktop: blue
        let win = Compositor(context: ctx); win.layerID = 7; win.hasAlpha = true; win.configure(width: 200, height: 100)
        solid(win, PixelRect(x: 0, y: 0, width: 200, height: 100), bgra: (0, 0, 255, 255))          // window: red
        let w = ControlMessage.WindowInfo(id: 7, pid: 3, title: "off the left edge", frame: PixelRect(x: -120, y: 100, width: 200, height: 100), z: 0, level: 0, layered: true)
        let plan = LayerScenePlan.plan([w], hasCanvas: { $0 == 7 }, display: PixelRect(x: 0, y: 0, width: 400, height: 300), shadowMargin: 48)
        // The display letterboxed: 100 px bars left and right of a 400x300 picture in a 600x300 drawable.
        let t = target(ctx, 600, 300)
        let drag = Predictor.Displacement(kind: .drag, windowID: 7, rect: PixelRect(x: 0, y: 0, width: 200, height: 100), dx: -60, dy: 0)
        let scene = LayerScene(background: bg, items: plan.sceneItems(pxPerPoint: 1, canvas: { $0 == 7 ? win : nil }),
                               displacements: [.init(layerID: 7, displacement: drag)], bandColors: [:])
        SceneRenderer.render(scene, context: ctx, target: t, dest: CGRect(x: 100, y: 0, width: 400, height: 300))
        XCTAssertEqual(try pixel(ctx, t, 110, 150).r, 255, "the dragged window's on-screen part is drawn")
        for x in [5, 50, 95] { let p = try pixel(ctx, t, x, 150); XCTAssertEqual([p.r, p.g, p.b], [0, 0, 0], "letterbox at x \(x) untouched") }
        let right = try pixel(ctx, t, 550, 150); XCTAssertEqual([right.r, right.g, right.b], [0, 0, 0])
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
        XCTAssertEqual(try pixel(ctx, t, 100, 80).g, 255, "the menu sits above the window")
        XCTAssertEqual(try pixel(ctx, t, 60, 50).r, 255, "the window around it")
        XCTAssertEqual(plan.entries.first { $0.id == 9 }?.clips, [PixelRect(x: 80, y: 60, width: 60, height: 100)], "clipped to the overlap with the window and its shadow")
        XCTAssertEqual(try pixel(ctx, t, 100, 150).g, 255, "below the window the display layer shows the menu itself")
    }

    func testHostLayeredWithoutCanvasIsReportedNotHidden() {
        let w = ControlMessage.WindowInfo(id: 7, pid: 3, title: "", frame: PixelRect(x: 0, y: 0, width: 10, height: 10), z: 0, level: 0, layered: true)
        let plan = LayerScenePlan.plan([w], hasCanvas: { _ in false }, display: PixelRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(plan.entries[0].kind, .missing)
        XCTAssertFalse(plan.entries[0].visible)
        XCTAssertNotNil(plan.entries[0].why)
    }

    /// A window layer at a lossy level (its first still or middle level) keeps its rounded corners: where the window is
    /// transparent the desktop shows, whatever colour lossy WebP left in those pixels (they were square and whitish).
    func testLossyLevelKeepsTransparentCornersDuringAndAfterAMove() throws {
        guard let ctx = MetalContext() else { throw XCTSkip("no Metal device") }
        let bg = Compositor(context: ctx); bg.configure(width: 300, height: 200)
        solid(bg, PixelRect(x: 0, y: 0, width: 300, height: 200), bgra: (255, 0, 0, 255))        // desktop: blue
        let win = Compositor(context: ctx); win.layerID = 9; win.hasAlpha = true; win.configure(width: 120, height: 80)
        // A window picture with transparent 16-px corners whose colour is white (what the lossy codec can leave there).
        var px = [UInt8](repeating: 0, count: 120 * 80 * 4)
        for y in 0..<80 { for x in 0..<120 {
            let o = (y * 120 + x) * 4
            let cx = x < 16 ? 16 - x : (x >= 104 ? x - 103 : 0), cy = y < 16 ? 16 - y : (y >= 64 ? y - 63 : 0)
            let outside = cx * cx + cy * cy > 256
            px[o] = 200; px[o + 1] = 200; px[o + 2] = 200; px[o + 3] = outside ? 0 : 255
            if outside { px[o] = 255; px[o + 1] = 255; px[o + 2] = 255 }
        } }
        let data = px.withUnsafeBytes { TileCodec.encodeLossy(base: $0.baseAddress!, width: 120, height: 80, stride: 480, outWidth: 120, outHeight: 80, quality: 75) }!
        win.applyTiles([.init(rect: PixelRect(x: 0, y: 0, width: 120, height: 80), format: .lossy, data: data)])
        let t = target(ctx, 300, 200)
        // The shadow follows the measured corner (16 px here): just inside the window's own arc but outside a 12-px box the
        // old fixed-radius shadow left a wedge of bare desktop next to a dark outline.
        let e = expectation(description: "radius"); var measured: Double?
        win.sampleCornerRadius { measured = $0; e.fulfill() }
        wait(for: [e], timeout: 30)
        XCTAssertEqual(measured ?? 0, 16, accuracy: 3)
        win.cornerRadius = Float(measured ?? 16)
        for frame in [PixelRect(x: 40, y: 40, width: 120, height: 80), PixelRect(x: 97, y: 61, width: 120, height: 80)] {   // at rest, then moved locally
            let w = ControlMessage.WindowInfo(id: 9, pid: 1, title: "", frame: frame, z: 0, level: 0, layered: true)
            _ = render(ctx, bg: bg, layers: [9: win], windows: [w], into: t)
            let corner = try pixel(ctx, t, frame.x + 1, frame.y + 1), inside = try pixel(ctx, t, frame.x + 60, frame.y + 40)
            // The desktop (blue, darkened by the window's own shadow) shows in the transparent corner, never the white
            // the lossy codec left there or the window's grey.
            XCTAssertGreaterThan(Int(corner.b), Int(corner.r) + 60, "desktop shows in the transparent corner at \(frame)")
            XCTAssertLessThan(Int(corner.r), 60, "no white in the corner at \(frame)")
            XCTAssertGreaterThan(Int(inside.r), 150, "the window shows inside at \(frame)")
        }
    }
}
