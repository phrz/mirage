import XCTest
import Metal
@testable import MirageCore

/// The viewer's window shadows against macOS's own (phrz, 2026-10-27: "shadow emulation is way too dark"): a plain
/// 500x320-pt window shot with its shadow on macOS 27 at 2× (screencapture -l, alpha over clear), its shadow's alpha out
/// from the middle of each edge. Drawn over white, the viewer's darkness at the same spots must match within a few levels.
final class ShadowMatchTests: XCTestCase {
    /// Distance from the window's edge (px at 2×) → alpha (0–255), as measured.
    static let keySide: [Int: Int] = [4: 47, 8: 43, 16: 36, 24: 28, 32: 22, 48: 12, 64: 6, 96: 1]
    static let keyBelow: [Int: Int] = [4: 81, 8: 78, 16: 71, 24: 64, 32: 56, 48: 40, 64: 25, 96: 7, 128: 1]
    static let keyAbove: [Int: Int] = [4: 16, 8: 13, 16: 10, 24: 7, 32: 4, 48: 2, 64: 0]
    static let inactiveSide: [Int: Int] = [4: 23, 8: 18, 16: 9, 24: 4, 32: 2, 40: 0]
    static let inactiveBelow: [Int: Int] = [4: 42, 8: 37, 16: 26, 24: 15, 32: 8, 48: 1]
    static let inactiveAbove: [Int: Int] = [4: 7, 8: 5, 16: 2, 24: 0]

    private func solid(_ c: Compositor, _ rect: PixelRect, bgra: [UInt8]) { c.applyTiles([.init(rect: rect, format: .solid, data: Data(bgra))]) }

    /// The darkness (255 − red) the viewer draws around a 1000x640-px window at (200, 200) on white, key or behind another.
    private func darkness(key: Bool) throws -> (Int, Int) -> Int {
        guard let ctx = MetalContext() else { throw XCTSkip("no Metal device") }
        let bg = Compositor(context: ctx); bg.configure(width: 1400, height: 1100)
        solid(bg, PixelRect(x: 0, y: 0, width: 1400, height: 1100), bgra: [255, 255, 255, 255])
        let win = Compositor(context: ctx); win.layerID = 7; win.hasAlpha = true; win.configure(width: 1000, height: 640)
        solid(win, PixelRect(x: 0, y: 0, width: 1000, height: 640), bgra: [0, 0, 255, 255])
        let front = Compositor(context: ctx); front.layerID = 8; front.hasAlpha = true; front.configure(width: 40, height: 40)
        solid(front, PixelRect(x: 0, y: 0, width: 40, height: 40), bgra: [0, 255, 0, 255])
        var windows = [ControlMessage.WindowInfo(id: 7, pid: 3, title: "measured", frame: PixelRect(x: 200, y: 200, width: 1000, height: 640), z: 1, level: 0, layered: true)]
        // Not key: another window in front, far from the measured spots.
        if !key { windows.insert(ControlMessage.WindowInfo(id: 8, pid: 4, title: "front", frame: PixelRect(x: 1340, y: 1040, width: 40, height: 40), z: 0, level: 0, layered: true), at: 0) }
        let layers: [UInt32: Compositor] = [7: win, 8: front]
        let display = PixelRect(x: 0, y: 0, width: 1400, height: 1100)
        let plan = LayerScenePlan.plan(windows, hasCanvas: { layers[$0] != nil }, display: display, shadowMargin: 117)
        let scene = LayerScene(background: bg, items: plan.sceneItems(pxPerPoint: 2, canvas: { layers[$0] }), displacements: [], bandColors: [:])
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1400, height: 1100, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let t = try XCTUnwrap(ctx.device.makeTexture(descriptor: d))
        SceneRenderer.render(scene, context: ctx, target: t, dest: CGRect(x: 0, y: 0, width: 1400, height: 1100))
        try ctx.commandQueue.makeCommandBuffer()!.commitAndWaitBounded()
        var px = [UInt8](repeating: 0, count: 1400 * 1100 * 4)
        t.getBytes(&px, bytesPerRow: 1400 * 4, from: MTLRegionMake2D(0, 0, 1400, 1100), mipmapLevel: 0)
        return { x, y in 255 - Int(px[(y * 1400 + x) * 4 + 2]) }
    }

    private func check(_ dark: (Int, Int) -> Int, _ measured: [Int: Int], _ name: String, at spot: (Int) -> (Int, Int)) {
        for (d, a) in measured.sorted(by: { $0.key < $1.key }) {
            let (x, y) = spot(d)
            XCTAssertEqual(dark(x, y), a, accuracy: 5, "\(name) \(d) px out: macOS \(a), viewer \(dark(x, y))")
        }
    }

    func testTheKeyWindowsShadowMatchesMacOS() throws {
        let dark = try darkness(key: true)
        check(dark, Self.keySide, "key, left") { (200 - $0, 520) }
        check(dark, Self.keyBelow, "key, below") { (700, 839 + $0) }
        check(dark, Self.keyAbove, "key, above") { (700, 200 - $0) }
    }
    func testAnInactiveWindowsShadowMatchesMacOS() throws {
        let dark = try darkness(key: false)
        check(dark, Self.inactiveSide, "inactive, left") { (200 - $0, 520) }
        check(dark, Self.inactiveBelow, "inactive, below") { (700, 839 + $0) }
        check(dark, Self.inactiveAbove, "inactive, above") { (700, 200 - $0) }
    }
}
