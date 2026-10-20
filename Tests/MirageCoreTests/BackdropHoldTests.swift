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
}
