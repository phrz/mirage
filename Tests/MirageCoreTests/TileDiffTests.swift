import XCTest
@testable import MirageCore

/// A transient's pixels going away must be found by the diff, whatever ScreenCaptureKit reported (phrz's ghost Dock
/// tooltips: tile-aligned labels that stayed until another tooltip painted over them).
final class TileDiffTests: XCTestCase {
    private func frame(_ w: Int, _ h: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let c = fill(x, y); let o = (y * w + x) * 4; p[o] = c.0; p[o + 1] = c.1; p[o + 2] = c.2; p[o + 3] = c.3 } }
        return p
    }

    func testVanishedTooltipIsDirtyEvenWhenNotReported() {
        let w = 256, h = 192
        let tooltip = PixelRect(x: 70, y: 100, width: 120, height: 30)
        // Dark wallpaper with a dark-grey tooltip (the screenshot's colours), then the wallpaper alone.
        let before = frame(w, h) { x, y in tooltip.contains(x, y) ? (58, 58, 58, 255) : (24, 34, 28, 255) }
        let after = frame(w, h) { _, _ in (24, 34, 28, 255) }
        let t = TileTracker(width: w, height: h)
        before.withUnsafeBytes { a in after.withUnsafeBytes { b in
            let fa = ShiftDetector.Frame(base: a.baseAddress!, stride: w * 4, width: w, height: h)
            let fb = ShiftDetector.Frame(base: b.baseAddress!, stride: w * 4, width: w, height: h)
            // ScreenCaptureKit reported nothing for this capture.
            let r = TileDiff.changedTiles(fa, fb, tracker: t, tolerance: 4, reported: [])
            XCTAssertEqual(Set(r.tiles), Set(t.tiles(covering: [tooltip])), "every tile the tooltip covered is dirty")
            XCTAssertEqual(r.unreported, r.tiles.count)
            // Nothing changed: nothing dirty.
            XCTAssertTrue(TileDiff.changedTiles(fb, fb, tracker: t, tolerance: 4).tiles.isEmpty)
        } }
    }

    func testOpaqueToTransparentCountsInAWindowLayer() {
        let w = 128, h = 64
        let label = PixelRect(x: 10, y: 10, width: 40, height: 20)
        let before = frame(w, h) { x, y in label.contains(x, y) ? (200, 200, 200, 255) : (0, 0, 0, 0) }
        let after = frame(w, h) { _, _ in (0, 0, 0, 0) }
        before.withUnsafeBytes { a in after.withUnsafeBytes { b in
            let fa = ShiftDetector.Frame(base: a.baseAddress!, stride: w * 4, width: w, height: h)
            let fb = ShiftDetector.Frame(base: b.baseAddress!, stride: w * 4, width: w, height: h)
            XCTAssertEqual(TileDiff.changedBox(fa, fb, PixelRect(x: 0, y: 0, width: 64, height: 64), tolerance: 4, alphaLayer: true), label)
        } }
    }
}

final class TileAuditTests: XCTestCase {
    func testStaleTooltipDiffersNoiseDoesNot() {
        let w = 64, h = 64
        func make(_ f: (Int, Int) -> UInt8) -> [UInt8] { var p = [UInt8](repeating: 255, count: w * h * 4); for y in 0..<h { for x in 0..<w { let v = f(x, y); let o = (y * w + x) * 4; p[o] = v; p[o + 1] = v; p[o + 2] = v } }; return p }
        let wallpaper = make { x, y in UInt8(20 + (x * 3 + y * 5) % 17) }
        let ghost = make { x, y in (10..<54).contains(x) && (20..<44).contains(y) ? 70 : UInt8(20 + (x * 3 + y * 5) % 17) }   // a dark-grey label fragment
        var noisy = wallpaper; var s: UInt32 = 3
        for i in stride(from: 0, to: noisy.count, by: 4) { s = s &* 1664525 &+ 1013904223; let d = Int(s >> 29) - 4; for c in 0..<3 { noisy[i + c] = UInt8(max(0, min(255, Int(noisy[i + c]) + d))) } }
        func fp(_ p: [UInt8]) -> [UInt8] { p.withUnsafeBytes { TileAudit.fingerprint(ShiftDetector.Frame(base: $0.baseAddress!, stride: w * 4, width: w, height: h), PixelRect(x: 0, y: 0, width: w, height: h)) } }
        XCTAssertTrue(TileAudit.differs(fp(ghost)[...], fp(wallpaper)[...]), "a stale label is caught")
        XCTAssertFalse(TileAudit.differs(fp(noisy)[...], fp(wallpaper)[...]), "capture noise (±4) and lossy coding are not")
    }
}
