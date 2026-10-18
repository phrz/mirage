import XCTest
@testable import MirageCore

/// A desktop tile the viewer may hold window pixels for is re-sent once it is visible and clear of windows.
final class DisplayTaintTests: XCTestCase {
    func testWindowPixelsInTheDesktopLayerAreResentWhenUncovered() {
        let tracker = TileTracker(width: 640, height: 384)   // 10 × 6 tiles
        var taint = DisplayTaint()
        let bench = PixelRect(x: 64, y: 64, width: 192, height: 128)   // tiles (1..3, 1..2)
        // The first picture of the desktop is sent while the bench is still part of it (not yet a layer).
        taint.sent(Array(0..<tracker.tileCount), tracker: tracker, windowAreas: [bench])
        XCTAssertEqual(taint.tainted.count, 6)
        // The bench becomes a layer: its area is hidden under it on the viewer; nothing is due.
        let hidden = Set(tracker.tiles(covering: [bench]))
        XCTAssertEqual(taint.due(hidden: hidden, tracker: tracker, windowAreas: [bench]), [])
        // The bench moves right by 3 tiles: its old area is visible and clear of it → those tiles are due.
        let moved = bench.offset(192, 0)
        let due = taint.due(hidden: Set(tracker.tiles(covering: [moved])), tracker: tracker, windowAreas: [moved])
        XCTAssertEqual(Set(due), Set(tracker.tiles(covering: [PixelRect(x: 64, y: 64, width: 192, height: 128)])))
        // Re-sent from a capture where they are clear of every window: clean, never due again.
        taint.sent(due, tracker: tracker, windowAreas: [moved])
        XCTAssertTrue(taint.due(hidden: [], tracker: tracker, windowAreas: [moved]).isEmpty)
        XCTAssertTrue(taint.tainted.isEmpty, "the old area is clean now; the new area was never sent with the window in it")
    }

    func testWhileTheWindowStillOverlapsNothingIsDue() {
        let tracker = TileTracker(width: 640, height: 384)
        var taint = DisplayTaint()
        let w = PixelRect(x: 0, y: 0, width: 128, height: 128)
        taint.sent([0, 1, 10, 11], tracker: tracker, windowAreas: [w])
        // Visible (no layer over it yet) but the window is still there in the capture: re-sending would send the window again.
        XCTAssertEqual(taint.due(hidden: [], tracker: tracker, windowAreas: [w]), [])
        // Clean tiles stay clean.
        taint.sent([5], tracker: tracker, windowAreas: [w])
        XCTAssertFalse(taint.tainted.contains(5))
    }
}
