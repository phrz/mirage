import XCTest
@testable import MirageCore

/// Desktop pixels are never sent or committed where a layered window is or recently was.
final class DisplayGuardTests: XCTestCase {
    func testCurrentFrameAndRecentSweepAreGuardedUntilTheHistoryPasses() {
        var g = DisplayGuard(historyNanos: 1_000_000_000, margin: 64)
        let a = PixelRect(x: 100, y: 100, width: 200, height: 100), b = a.offset(300, 0)
        g.update(layered: [7: a], now: 0)
        XCTAssertFalse(g.allows(PixelRect(x: 150, y: 150, width: 10, height: 10), now: 10))
        XCTAssertTrue(g.allows(PixelRect(x: 500, y: 150, width: 10, height: 10), now: 10))
        // The window moves to b: its old place stays guarded for the history (and the swept box with margin).
        g.update(layered: [7: b], now: 500_000_000)
        XCTAssertFalse(g.allows(PixelRect(x: 150, y: 150, width: 10, height: 10), now: 600_000_000), "old place, 0.1 s after the move")
        XCTAssertFalse(g.allows(PixelRect(x: 80, y: 60, width: 10, height: 10), now: 600_000_000), "margin around the swept box")
        XCTAssertFalse(g.allows(PixelRect(x: 450, y: 150, width: 10, height: 10), now: 600_000_000), "current frame")
        // More than the history after the window left a, a is clear again (the window's samples at a expired).
        g.update(layered: [7: b], now: 1_600_000_000)
        XCTAssertTrue(g.allows(PixelRect(x: 150, y: 150, width: 10, height: 10), now: 1_600_000_000))
        XCTAssertFalse(g.allows(PixelRect(x: 450, y: 150, width: 10, height: 10), now: 1_600_000_000))
    }

    func testAWindowThatStopsBeingALayerStaysGuardedForTheHistory() {
        var g = DisplayGuard(historyNanos: 1_000_000_000, margin: 0)
        let a = PixelRect(x: 0, y: 0, width: 64, height: 64)
        g.update(layered: [1: a], now: 0)
        g.update(layered: [:], now: 100)
        XCTAssertFalse(g.allows(PixelRect(x: 10, y: 10, width: 4, height: 4), now: 200))
        g.update(layered: [:], now: 1_200_000_000)
        XCTAssertTrue(g.allows(PixelRect(x: 10, y: 10, width: 4, height: 4), now: 1_200_000_000))
        let t = TileTracker(width: 256, height: 256)
        XCTAssertTrue(g.guardedTiles(t, now: 1_200_000_000).isEmpty)
    }

    func testRectSubtraction() {
        let r = PixelRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(r.subtracting(PixelRect(x: 200, y: 0, width: 10, height: 10)), [r])
        XCTAssertEqual(r.subtracting(r), [])
        let pieces = r.subtracting(PixelRect(x: 25, y: 25, width: 50, height: 50))
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.area }, 10000 - 2500)
        for (i, a) in pieces.enumerated() { for b in pieces[(i + 1)...] { XCTAssertFalse(a.intersects(b)) } }
        XCTAssertEqual(r.subtracting([PixelRect(x: 0, y: 0, width: 50, height: 100), PixelRect(x: 50, y: 0, width: 50, height: 100)]), [])
    }

    func testVerifiedWindowAtRestGuardsNothingButItsRecentSweepStaysGuarded() {
        var g = DisplayGuard(historyNanos: 1_000_000_000, margin: 0)
        let a = PixelRect(x: 0, y: 0, width: 128, height: 128), b = a.offset(256, 0)
        g.update(layered: [5: a], verified: [5], now: 0)
        XCTAssertTrue(g.allows(PixelRect(x: 10, y: 10, width: 4, height: 4), now: 10), "excluded and at rest: the desktop under it is clean")
        g.update(layered: [5: a], verified: [], now: 20)
        XCTAssertFalse(g.allows(PixelRect(x: 10, y: 10, width: 4, height: 4), now: 30), "not verified: guarded")
        g.update(layered: [5: b], verified: [5], now: 100)
        XCTAssertFalse(g.allows(PixelRect(x: 300, y: 10, width: 4, height: 4), now: 200), "just moved: the swept box is guarded")
        XCTAssertFalse(g.allows(PixelRect(x: 10, y: 10, width: 4, height: 4), now: 200))
        g.update(layered: [5: b], verified: [5], now: 1_200_000_000)
        XCTAssertTrue(g.allows(PixelRect(x: 300, y: 10, width: 4, height: 4), now: 1_200_000_000), "at rest for the history: clean again")
    }
}
