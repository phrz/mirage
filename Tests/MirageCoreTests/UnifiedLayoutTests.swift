import XCTest
import Metal
@testable import MirageCore

/// Unified mode (DESIGN §3.2, §3.8): which host windows become native windows, their parents, the traffic-light
/// hit test, the pixel-exact geometry, and the one-canvas renderer each native window draws with.
final class UnifiedLayoutTests: XCTestCase {
    private let display = PixelRect(x: 0, y: 0, width: 3200, height: 1800)
    private func win(_ id: UInt32, pid: Int32, _ f: PixelRect, z: Int, level: Int = 0, layered: Bool = false, cutout: Bool? = nil, controls: PixelRect? = nil) -> ControlMessage.WindowInfo {
        .init(id: id, pid: pid, title: "w\(id)", frame: f, z: z, level: level, layered: layered, app: "app\(pid)", cutout: cutout, controls: controls)
    }

    func testLayersBecomeWindowsMenusBecomeChildrenChromeIsLeftOut() {
        let list = [
            win(1, pid: 9, PixelRect(x: 0, y: 0, width: 3200, height: 48), z: 0, level: 24, cutout: true),          // menu bar
            win(2, pid: 10, PixelRect(x: 600, y: 300, width: 400, height: 500), z: 1, level: 101, cutout: true),     // a menu of app 10
            win(3, pid: 11, PixelRect(x: 100, y: 100, width: 300, height: 200), z: 2, level: 101, cutout: true),     // a menu of app 11 (no remote window)
            win(4, pid: 10, PixelRect(x: 500, y: 200, width: 1600, height: 1000), z: 3, layered: true),              // app 10's window
            win(5, pid: 12, PixelRect(x: 0, y: 0, width: 3200, height: 1800), z: 4, level: 3, cutout: true),         // a full-screen overlay
            win(6, pid: 13, PixelRect(x: 2000, y: 900, width: 800, height: 600), z: 5, cutout: true),                // a normal window not layered
            win(7, pid: 14, PixelRect(x: 900, y: 1700, width: 1400, height: 100), z: 6, level: 20, cutout: true),    // dock
            win(8, pid: 10, PixelRect(x: 0, y: 0, width: 900, height: 700), z: 7, layered: true),                    // app 10's other window, no canvas yet
        ]
        let l = UnifiedLayout.plan(list, hasCanvas: { $0 != 8 }, display: display)
        XCTAssertEqual(l.entries.map(\.id), [2, 4])
        XCTAssertEqual(l.entries[0].role, .transient)
        XCTAssertEqual(l.entries[0].parent, 4)
        XCTAssertEqual(l.entries[0].source, .display(PixelRect(x: 600, y: 300, width: 400, height: 500)))
        XCTAssertEqual(l.entries[1].source, .layer(4))
        XCTAssertNil(l.entries[1].parent)
    }

    func testSheetAttachesToItsWindowAndTransientPrefersTheWindowItTouches() {
        let list = [
            win(1, pid: 5, PixelRect(x: 2600, y: 1000, width: 200, height: 300), z: 0, level: 101, cutout: true),   // popover by window 3
            win(2, pid: 5, PixelRect(x: 700, y: 260, width: 800, height: 400), z: 1, layered: true),                 // sheet in window 4's top band
            win(3, pid: 5, PixelRect(x: 2000, y: 800, width: 1000, height: 800), z: 2, layered: true),
            win(4, pid: 5, PixelRect(x: 500, y: 200, width: 1200, height: 1200), z: 3, layered: true),
        ]
        let l = UnifiedLayout.plan(list, hasCanvas: { _ in true }, display: display)
        XCTAssertEqual(l.entries.first { $0.id == 1 }?.parent, 3)
        XCTAssertEqual(l.entries.first { $0.id == 2 }?.parent, 4)
        XCTAssertNil(l.entries.first { $0.id == 3 }?.parent)
        XCTAssertNil(l.entries.first { $0.id == 4 }?.parent)
    }

    func testTrafficLightsAndDragRegion() {
        let c = PixelRect(x: 14, y: 12, width: 132, height: 40)   // 66×20 pt at 2x
        XCTAssertEqual(UnifiedLayout.control(at: 20, 30, controls: c), .close)
        XCTAssertEqual(UnifiedLayout.control(at: 80, 30, controls: c), .minimize)
        XCTAssertEqual(UnifiedLayout.control(at: 140, 30, controls: c), .zoom)
        XCTAssertNil(UnifiedLayout.control(at: 200, 30, controls: c))
        XCTAssertNil(UnifiedLayout.control(at: 20, 30, controls: nil))
        XCTAssertFalse(UnifiedLayout.isDragRegion(100, 20, controls: c, titleBarPx: 56, trafficLightsPx: 160))
        XCTAssertTrue(UnifiedLayout.isDragRegion(400, 20, controls: c, titleBarPx: 56, trafficLightsPx: 160))
        XCTAssertFalse(UnifiedLayout.isDragRegion(400, 60, controls: c, titleBarPx: 56, trafficLightsPx: 160))
        XCTAssertTrue(UnifiedLayout.isDragRegion(170, 20, controls: nil, titleBarPx: 56, trafficLightsPx: 160))
    }

    func testGeometryIsPixelExactAndRoundTrips() {
        // Host menu bar 33 pt (66 px at 2x), local notched menu bar 37 pt: everything 4 pt lower.
        let g = UnifiedGeometry.make(pixelsPerPoint: 2, screenX: 0, screenY: 0, hostMenuBarPx: 66, localMenuBarPoints: 37)
        XCTAssertEqual(g.originY, 4)
        let r = PixelRect(x: 1001, y: 300, width: 801, height: 600)
        let l = g.local(r)
        XCTAssertEqual(l, .init(x: 500.5, y: 154, width: 400.5, height: 300))
        XCTAssertEqual(g.host(l), r)
        // A taller host menu bar never moves windows up.
        XCTAssertEqual(UnifiedGeometry.make(pixelsPerPoint: 2, screenX: 0, screenY: 0, hostMenuBarPx: 80, localMenuBarPoints: 24).originY, 0)
        // Stream size: keep a stream within 15 %, else ask for host points × backing.
        XCTAssertNil(UnifiedGeometry.wantedStream(current: (3024, 1700), hostPoints: (1600, 900), backingScale: 2))
        XCTAssertEqual(UnifiedGeometry.wantedStream(current: (2560, 1440), hostPoints: (1600, 900), backingScale: 2).map { [$0.0, $0.1] }, [3200, 1800])
    }

    func testCropRendererDrawsOneToOneAndNeverStretches() throws {
        guard let ctx = MetalContext() else { throw XCTSkip("no Metal device") }
        let c = Compositor(context: ctx); c.layerID = 3; c.hasAlpha = true; c.configure(width: 100, height: 80)
        c.applyTiles([.init(rect: PixelRect(x: 0, y: 0, width: 100, height: 80), format: .solid, data: Data([0, 0, 255, 255]))])   // red
        c.applyTiles([.init(rect: PixelRect(x: 50, y: 0, width: 50, height: 80), format: .solid, data: Data([255, 0, 0, 255]))])   // right half blue
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 120, height: 80, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let t = ctx.device.makeTexture(descriptor: d)!
        // A window resized wider than its canvas: canvas at 1:1, the rest the clear colour (transparent).
        SceneRenderer.renderCrop(c, source: PixelRect(x: 0, y: 0, width: 120, height: 80), displacements: [], bandColors: [:], context: ctx, target: t, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        let cb = ctx.commandQueue.makeCommandBuffer()!; cb.commit(); cb.waitUntilCompleted()
        func px(_ x: Int, _ y: Int) -> [UInt8] { var p = [UInt8](repeating: 0, count: 4); t.getBytes(&p, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0); return p }
        XCTAssertEqual(px(10, 10), [0, 0, 255, 255])
        XCTAssertEqual(px(60, 10), [255, 0, 0, 255])
        XCTAssertEqual(px(99, 79), [255, 0, 0, 255])
        XCTAssertEqual(px(110, 10)[3], 0)
        // A display-layer crop (a menu): the source rect's pixels at the drawable's origin.
        let t2 = ctx.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 20, height: 20, mipmapped: false).with { $0.usage = [.renderTarget, .shaderRead]; $0.storageMode = .shared })!
        SceneRenderer.renderCrop(c, source: PixelRect(x: 45, y: 10, width: 20, height: 20), displacements: [], bandColors: [:], context: ctx, target: t2, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        let cb2 = ctx.commandQueue.makeCommandBuffer()!; cb2.commit(); cb2.waitUntilCompleted()
        var a = [UInt8](repeating: 0, count: 4), b = [UInt8](repeating: 0, count: 4)
        t2.getBytes(&a, bytesPerRow: 4, from: MTLRegionMake2D(2, 5, 1, 1), mipmapLevel: 0)
        t2.getBytes(&b, bytesPerRow: 4, from: MTLRegionMake2D(8, 5, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(a, [0, 0, 255, 255]); XCTAssertEqual(b, [255, 0, 0, 255])
    }

    func testResizeKeepsTheOldPictureAndCornerRadiusIsMeasured() throws {
        guard let ctx = MetalContext() else { throw XCTSkip("no Metal device") }
        let c = Compositor(context: ctx); c.hasAlpha = true; c.configure(width: 64, height: 64)
        c.applyTiles([.init(rect: PixelRect(x: 0, y: 0, width: 64, height: 64), format: .solid, data: Data([0, 255, 0, 255]))])
        c.configureKeepingPixels(width: 96, height: 48)
        XCTAssertEqual(c.width, 96); XCTAssertEqual(c.height, 48)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 96, height: 48, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let t = ctx.device.makeTexture(descriptor: d)!
        SceneRenderer.renderCrop(c, source: PixelRect(x: 0, y: 0, width: 96, height: 48), displacements: [], bandColors: [:], context: ctx, target: t, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        let cb = ctx.commandQueue.makeCommandBuffer()!; cb.commit(); cb.waitUntilCompleted()
        var p = [UInt8](repeating: 0, count: 4), q = [UInt8](repeating: 0, count: 4)
        t.getBytes(&p, bytesPerRow: 4, from: MTLRegionMake2D(30, 30, 1, 1), mipmapLevel: 0)
        t.getBytes(&q, bytesPerRow: 4, from: MTLRegionMake2D(80, 30, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(p, [0, 255, 0, 255], "old picture kept at the top-left")
        XCTAssertEqual(q[3], 0, "new area cleared")
        // Corner: a 64×64 opaque layer with a transparent rounded top-left corner of radius ~20 px.
        let r = Compositor(context: ctx); r.hasAlpha = true; r.configure(width: 64, height: 64)
        r.applyTiles([.init(rect: PixelRect(x: 0, y: 0, width: 64, height: 64), format: .solid, data: Data([200, 200, 200, 255]))])
        r.applyTiles([.init(rect: PixelRect(x: 0, y: 0, width: 6, height: 6), format: .solid, data: Data([0, 0, 0, 0]))])   // diagonal crosses at 6 px
        let e = expectation(description: "radius")
        var got: Double?
        r.sampleCornerRadius { got = $0; e.fulfill() }
        wait(for: [e], timeout: 30)
        XCTAssertEqual(got ?? 0, 6 / 0.2929, accuracy: 0.5)
    }
}

private extension MTLTextureDescriptor {
    func with(_ f: (MTLTextureDescriptor) -> Void) -> MTLTextureDescriptor { f(self); return self }
}
