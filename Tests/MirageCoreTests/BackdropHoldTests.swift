import XCTest
@testable import MirageCore

/// A moved window's backdrop change (Liquid Glass): held for one lossy level, refined lossless only when idle.
final class BackdropHoldTests: XCTestCase {
    func testHeldTilesAreNotDueNotOwedAndNotABacklogUntilReleased() {
        var t = TileTracker(width: 640, height: 640)   // 100 tiles
        let tiles = Array(0..<60)
        t.holdUntilIdle(tiles, now: 1_000_000_000)
        XCTAssertEqual(t.heldCount, 60)
        XCTAssertFalse(t.isCrisp(3), "shown lossy: not crisp")
        XCTAssertEqual(t.due(now: 900_000_000_000, limit: 200), [], "never due while held")
        XCTAssertEqual(t.refinementOutstanding(excluding: [], stableBefore: .max), 0, "no presentation level waits for them")
        XCTAssertEqual(t.pendingUnheld, 0, "not a refinement backlog")
        XCTAssertEqual(t.dueDirect(now: 900_000_000_000, limit: 200), [])
        XCTAssertEqual(t.expedite(in: PixelRect(x: 0, y: 0, width: 640, height: 640), now: 2_000_000_000), 0, "a fovea move does not pull them in")
        // A real change of one of them: it is an ordinary tile again.
        let p = t.classify(dirty: [3], now: 3_000_000_000)
        XCTAssertEqual(p.lossless, [3]); XCTAssertFalse(t.isHeld(3))
        // Idle: the rest become due refinement (staged, not direct).
        XCTAssertEqual(t.releaseHeld(now: 9_000_000_000), 59)
        XCTAssertEqual(t.heldCount, 0)
        XCTAssertEqual(t.due(now: 9_000_000_000, limit: 200).count, 59)
        XCTAssertEqual(t.refinementOutstanding(excluding: [], stableBefore: .max), 59)
        XCTAssertFalse(t.isDirectPending(10))
    }

    func testOldestDueDirectIsWhenTheLongestWaitingTileBecameDue() {
        var t = TileTracker(width: 640, height: 640)
        XCTAssertNil(t.oldestDueDirect(now: 5_000_000_000))
        _ = t.classify(dirty: [5], now: 1_000_000_000)
        _ = t.classify(dirty: [5], now: 1_010_000_000)          // held back: due at 1.080 s
        XCTAssertNil(t.oldestDueDirect(now: 1_050_000_000), "not due yet")
        XCTAssertEqual(t.oldestDueDirect(now: 2_000_000_000), 1_080_000_000)
        t.sent(lossless: [5], now: 2_000_000_000)
        XCTAssertNil(t.oldestDueDirect(now: 3_000_000_000))
    }

    /// A copy-rect destination tile with wrong pixels is a direct change due now, even if it was queued as video refinement.
    func testMarkDirectTurnsVideoRefinementIntoADueDirectChange() {
        var t = TileTracker(width: 640, height: 640)
        t.markVideo([7, 8], now: 1_000_000_000)
        XCTAssertEqual(t.dueDirect(now: 1_000_000_000, limit: 10), [])
        t.markDirect([7], now: 1_000_000_000)
        XCTAssertEqual(t.dueDirect(now: 1_000_000_000, limit: 10), [7])
        XCTAssertTrue(t.isDirectPending(7)); XCTAssertFalse(t.isDirectPending(8))
    }
}

final class CopyFromWrongTests: XCTestCase {
    /// A copy-rect whose source tile the viewer holds wrong (a pending direct change) leaves its destination wrong: direct, due now.
    func testCopyFromAPendingDirectTileIsADirectChange() {
        var t = TileTracker(width: 640, height: 640)      // 10 × 10 tiles
        t.markDirect([25], now: 1_000_000_000)             // row 2, col 5: wrong on the viewer
        t.markCopied([15], dx: 0, dy: -64, now: 1_100_000_000)   // tile 15 filled from tile 25 (a scroll up by one tile)
        XCTAssertTrue(t.isDirectPending(15))
        XCTAssertEqual(t.dueDirect(now: 1_100_000_000, limit: 10).sorted(), [15, 25])
        // From a crisp source: crisp.
        t.markCopied([5], dx: 0, dy: -64, now: 1_200_000_000)    // from tile 15's old content? no: 15 is pending now
        XCTAssertTrue(t.isDirectPending(5), "copied from tile 15, which is wrong now")
        t.markCopied([40], dx: 0, dy: -64, now: 1_300_000_000)   // from tile 50, crisp
        XCTAssertTrue(t.isCrisp(40))
    }
    /// A copy from a backdrop-held tile stays held (lossy level, refined when idle), never due-never.
    func testCopyFromAHeldTileStaysHeld() {
        var t = TileTracker(width: 640, height: 640)
        t.holdUntilIdle([25], now: 1_000_000_000)
        t.markCopied([15], dx: 0, dy: -64, now: 1_100_000_000)
        XCTAssertTrue(t.isHeld(15))
        XCTAssertEqual(t.releaseHeld(now: 9_000_000_000), 2)
    }
}

final class CopyTrimTests: XCTestCase {
    /// A scroll under a translucent toolbar: the toolbar's tile row does not match; the copy-rect leaves it out.
    func testMismatchedLeadingRowsAreTrimmed() {
        let r = ShiftDetector.Result(dx: 0, dy: -30, rect: PixelRect(x: 0, y: 30, width: 640, height: 610),
                                     mismatchedTiles: (0..<10).map { PixelRect(x: $0 * 64, y: 0, width: 64, height: 64) } + [PixelRect(x: 128, y: 320, width: 64, height: 64)],
                                     confidence: 0.8)
        let t = ShiftDetector.trimmed(r)!
        XCTAssertEqual(t.rect.offset(t.dx, t.dy), PixelRect(x: 0, y: 64, width: 640, height: 546), "destination starts below the toolbar row")
        XCTAssertEqual(t.mismatchedTiles, [PixelRect(x: 128, y: 320, width: 64, height: 64)], "an inner mismatch stays (sent as a correction)")
        XCTAssertNil(ShiftDetector.trimmed(.init(dx: 0, dy: 10, rect: PixelRect(x: 0, y: 0, width: 64, height: 128), mismatchedTiles: [PixelRect(x: 0, y: 10, width: 64, height: 54), PixelRect(x: 0, y: 64, width: 64, height: 64)], confidence: 0)))
    }
}

final class TexturedEvidenceTests: XCTestCase {
    /// A whole-window copy over a flat sidebar background must not verify on the flat tiles: they match at any shift.
    func testFlatTilesAreNotEvidence() {
        let w = 640, h = 640
        var a = [UInt8](repeating: 40, count: w * h * 4)
        for i in stride(from: 3, to: a.count, by: 4) { a[i] = 255 }
        // One textured block that does not match any shift (different content in the new frame).
        var b = a
        for y in 300..<330 { for x in 300..<400 { a[(y * w + x) * 4] = UInt8((x * 7 + y) & 0xff); b[(y * w + x) * 4] = UInt8((x * 3 + y * 5) & 0xff) } }
        let r = a.withUnsafeBytes { pa in b.withUnsafeBytes { pb in
            ShiftDetector().verify(old: .init(base: pa.baseAddress!, stride: w * 4, width: w, height: h),
                                   new: .init(base: pb.baseAddress!, stride: w * 4, width: w, height: h),
                                   rect: PixelRect(x: 0, y: 0, width: w, height: h), dx: 0, dy: -64)
        } }
        XCTAssertNil(r, "98 % flat tiles match, the only evidence does not")
    }
}

final class RubberBandTests: XCTestCase {
    func testScrollLeadResistsAndNeverExceedsTheLimit() {
        XCTAssertEqual(Predictor.rubberBand(0, limit: 200), 0)
        XCTAssertEqual(Predictor.rubberBand(20, limit: 200), 19, "about 1:1 for a small lead")
        let a = Predictor.rubberBand(200, limit: 200), b = Predictor.rubberBand(2000, limit: 200)
        XCTAssertEqual(a, 126)
        XCTAssertGreaterThan(b, a); XCTAssertLessThanOrEqual(b, 200, "at most a third of the view")
        XCTAssertEqual(Predictor.rubberBand(-200, limit: 200), -a)
    }
    func testDisplacementOfALongScrollIsBounded() {
        var p = Predictor()
        let rect = PixelRect(x: 0, y: 0, width: 1500, height: 720)
        for k in 0..<12 { p.predict(kind: .scroll, windowID: 7, rect: rect, dx: 0, dy: -60, inputSeq: UInt64(k + 1), now: UInt64(k) * 33_000_000) }
        let d = p.displacements().first!
        XCTAssertLessThanOrEqual(abs(d.dy), 240, "12 × 60 px ahead shows at most a third of the 720-px view")
        XCTAssertGreaterThan(abs(d.dy), 200)
    }
}
