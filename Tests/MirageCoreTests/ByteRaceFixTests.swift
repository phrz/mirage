import XCTest
@testable import MirageCore

/// experiments/byterace: the copy-rect gate, terminal scrolls the profile test rejects, and soft tiles moved by a copy-rect.
final class ByteRaceFixTests: XCTestCase {
    func testCopyRectGateKeepsAScrollOffTheVideoPath() {
        var t = TileTracker(width: 1280, height: 768)
        let many = Array(0..<60)   // a scroll's unexplained frame: well above the motion threshold
        XCTAssertFalse(t.classify(dirty: many, now: 1_000_000_000).video.isEmpty, "without the gate it is motion")
        var g = TileTracker(width: 1280, height: 768)
        let plan = g.classify(dirty: many, now: 1_000_000_000, copyGate: true)
        XCTAssertTrue(plan.video.isEmpty, "a copy-rect explained this region's change: stays lossless")
        XCTAssertFalse(plan.lossless.isEmpty)
    }

    func testOneLineMonospaceScrollIsFoundByVerification() {
        // A dark terminal: 30-px lines of short "glyph" runs at varying columns; scrolled up by one line, a new line at the bottom.
        let w = 640, h = 480, lineH = 30
        func line(_ n: Int, _ x: Int) -> Bool { let len = 5 + (n * 7) % 23; let start = (n * 37) % 11; let col = x / 9; return col >= start && col < start + len && (x % 9) < 6 }
        func make(_ offset: Int) -> [UInt8] {
            var p = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let n = (y / lineH) + offset, yy = y % lineH
                let on = yy >= 8 && yy < 22 && line(n, x)
                let o = (y * w + x) * 4; let v: UInt8 = on ? 210 : 22
                p[o] = v; p[o + 1] = v; p[o + 2] = v; p[o + 3] = 255
            } }
            return p
        }
        let a = make(0), b = make(1)
        a.withUnsafeBytes { pa in b.withUnsafeBytes { pb in
            let fa = ShiftDetector.Frame(base: pa.baseAddress!, stride: w * 4, width: w, height: h)
            let fb = ShiftDetector.Frame(base: pb.baseAddress!, stride: w * 4, width: w, height: h)
            var d = ShiftDetector(); d.maxShift = 200
            // Real monospace output makes the profile ratio test fail (the true shift's SAD above zero's, 749 vs 507, from
            // glyph re-rendering); force that here so the verification fallback is what finds the shift.
            d.maxRatioToZero = 0
            var log: [String] = []
            d.debug = { log.append($0) }
            let r = d.detect(old: fa, new: fb, rect: PixelRect(x: 0, y: 0, width: w, height: h))
            XCTAssertEqual(r?.dy, -lineH, "one line up")
            XCTAssertGreaterThanOrEqual(r?.confidence ?? 0, 0.8)
            XCTAssertTrue(log.contains { $0.hasPrefix("shift fallback verify (0,-30)") }, "found by the fallback: \(log)")
            // Mostly flat content with one changed spot: a tiny shift verifies on the flat tiles but explains nothing changed.
            var flatA = [UInt8](repeating: 30, count: w * h * 4), flatB = flatA
            for y in 200..<230 { for x in 300..<400 { let o = (y * w + x) * 4; flatB[o] = 220; flatB[o + 1] = 220; flatB[o + 2] = 220 } }
            flatA.withUnsafeBytes { p1 in flatB.withUnsafeBytes { p2 in
                let f1 = ShiftDetector.Frame(base: p1.baseAddress!, stride: w * 4, width: w, height: h)
                let f2 = ShiftDetector.Frame(base: p2.baseAddress!, stride: w * 4, width: w, height: h)
                XCTAssertNil(d.detect(old: f1, new: f2, rect: PixelRect(x: 0, y: 0, width: w, height: h)), "no copy-rect for a change in place")
            } }
            // The fallback never accepts a shift that does not verify: an unrelated frame yields nothing.
            var noise = [UInt8](repeating: 0, count: w * h * 4); var s: UInt32 = 7
            for i in 0..<noise.count { s = s &* 1664525 &+ 1013904223; noise[i] = UInt8(s >> 24) }
            noise.withUnsafeBytes { pn in
                let fn = ShiftDetector.Frame(base: pn.baseAddress!, stride: w * 4, width: w, height: h)
                XCTAssertNil(d.detect(old: fa, new: fn, rect: PixelRect(x: 0, y: 0, width: w, height: h)))
            }
        } }
    }

    func testCopiedSoftTilesStayPendingAndCrispOnesStayCrisp() {
        var t = TileTracker(width: 640, height: 640)
        let cols = 10
        // Rows 4–5 went through video (soft); row 0 is crisp.
        let soft = Array((4 * cols)..<(6 * cols))
        _ = t.classify(dirty: Array(0..<60), now: 1_000_000_000)   // 60 dirty → video for tiles 0..59
        t.sent(lossless: Array(0..<(4 * cols)), now: 1_100_000_000) // rows 0–3 refined, rows 4–5 still soft
        XCTAssertFalse(t.isCrisp(soft[0]))
        // A scroll moves everything up by two rows (dy = -128): rows 2–3 now hold the soft rows' pixels, rows 0–1 crisp ones.
        let dest = Array(0..<(4 * cols))
        t.markCopied(dest, dx: 0, dy: -128, now: 1_200_000_000)
        XCTAssertTrue(t.isCrisp(0), "copied from a crisp tile")
        XCTAssertFalse(t.isCrisp(2 * cols), "copied from a soft tile: still owes its refinement")
        XCTAssertTrue(t.due(now: 3_000_000_000, limit: 100).contains(2 * cols), "and it is refined once due")
    }
}
