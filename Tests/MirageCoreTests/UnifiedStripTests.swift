import XCTest
@testable import MirageCore

/// Unified mode on a phone or tablet, host side: windows shown only as small stills (StillCadence, TileTracker.holdForStill)
/// and windows fitted to a pane for as long as they are shown (TemporaryFrames).
final class StillCadenceTests: XCTestCase {
    let s: UInt64 = 1_000_000_000

    func testNothingHeldIsNeverDue() {
        let c = StillCadence()
        XCTAssertFalse(c.due(now: 100 * s))
    }

    func testFirstChangeGoesOnceSettled() {
        var c = StillCadence()
        c.changed(now: 10 * s)
        XCTAssertFalse(c.due(now: 10 * s + s / 2), "still changing a moment ago")
        XCTAssertTrue(c.due(now: 11 * s), "quiet for the settle time")
    }

    func testAtMostOneStillPerInterval() {
        var c = StillCadence()
        c.changed(now: 10 * s)
        XCTAssertTrue(c.due(now: 11 * s)); c.released(now: 11 * s)
        c.changed(now: 12 * s)
        XCTAssertFalse(c.due(now: 14 * s), "settled, but the last still went 3 s ago")
        XCTAssertTrue(c.due(now: 15 * s))
    }

    func testAWindowThatNeverSettlesStillGetsAPictureEveryFewSeconds() {
        var c = StillCadence()
        var releases: [UInt64] = []
        var t = 10 * s
        while t < 40 * s {
            c.changed(now: t)                       // a video: every capture (2 fps) changes it
            if c.due(now: t) { c.released(now: t); releases.append(t) }
            t += s / 2
        }
        XCTAssertGreaterThanOrEqual(releases.count, 6)
        for (a, b) in zip(releases, releases.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 3 * s); XCTAssertLessThanOrEqual(b - a, 5 * s)
        }
    }

    func testHeldTilesWaitForTheReleaseAndAReleasedTileStaysDue() {
        var t = TileTracker(width: 640, height: 640)   // 100 tiles
        t.holdForStill(Array(0..<60), now: s)
        XCTAssertFalse(t.isCrisp(3), "the viewer's still is older than the window")
        XCTAssertEqual(t.due(now: 900 * s, limit: 200), [], "never due while held")
        XCTAssertEqual(t.pendingUnheld, 0, "not a refinement backlog (no large blocks for a still)")
        XCTAssertEqual(t.refinementOutstanding(excluding: [], stableBefore: .max), 0, "no presentation level waits for them")
        XCTAssertEqual(t.expedite(in: PixelRect(x: 0, y: 0, width: 640, height: 640), now: 2 * s), 0)
        XCTAssertEqual(t.releaseHeld(Set(0..<100), now: 5 * s), 60)
        XCTAssertEqual(t.due(now: 5 * s, limit: 200).count, 60)
        XCTAssertFalse(t.isDirectPending(3), "a refinement (staged), not a direct change")
        // A released tile that changes again before its turn stays due; an unreleased one is held.
        t.sent(lossless: Array(10..<60), now: 5 * s)
        t.holdForStill([3, 70], now: 6 * s)
        XCTAssertEqual(Set(t.due(now: 6 * s, limit: 200)), Set(0..<10))
        XCTAssertTrue(t.isHeld(70)); XCTAssertFalse(t.isHeld(3))
    }
}

final class TemporaryFramesTests: XCTestCase {
    let screen = CGRect(x: 0, y: 25, width: 1512, height: 870)          // under a 25-pt menu bar, over a 87-pt Dock
    let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

    func testTheFirstFrameIsKeptAcrossResizes() {
        var f = TemporaryFrames()
        f.willResize(7, current: CGRect(x: 100, y: 100, width: 800, height: 600))
        f.willResize(7, current: CGRect(x: 0, y: 25, width: 390, height: 844))
        XCTAssertEqual(f.take(7), CGRect(x: 100, y: 100, width: 800, height: 600))
        XCTAssertNil(f.take(7), "forgotten once put back")
    }

    func testTakeAllAndForget() {
        var f = TemporaryFrames()
        f.willResize(1, current: CGRect(x: 0, y: 0, width: 10, height: 10))
        f.willResize(2, current: CGRect(x: 5, y: 5, width: 10, height: 10))
        f.forget(1)
        XCTAssertEqual(f.takeAll(), [2: CGRect(x: 5, y: 5, width: 10, height: 10)])
        XCTAssertTrue(f.isEmpty)
    }

    func testKeepsTheTopLeftWhenItFits() {
        let r = TemporaryFrames.fit(size: CGSize(width: 400, height: 600), origin: nil, current: CGRect(x: 200, y: 100, width: 900, height: 700), visibleAreas: [screen])
        XCTAssertEqual(r, CGRect(x: 200, y: 100, width: 400, height: 600))
    }

    func testMovesJustEnoughToStayOnItsDisplay() {
        let r = TemporaryFrames.fit(size: CGSize(width: 800, height: 600), origin: nil, current: CGRect(x: 1000, y: 500, width: 300, height: 300), visibleAreas: [screen])
        XCTAssertEqual(r, CGRect(x: 712, y: 295, width: 800, height: 600))
    }

    func testClampsToTheVisibleArea() {
        let r = TemporaryFrames.fit(size: CGSize(width: 2000, height: 1200), origin: nil, current: CGRect(x: 50, y: 0, width: 300, height: 300), visibleAreas: [screen])
        XCTAssertEqual(r, screen, "as large as the visible area, below the menu bar and above the Dock")
    }

    func testTheOriginAskedForAndTheDisplayTheWindowIsOn() {
        // On the second display: its area, not the first one's.
        let r = TemporaryFrames.fit(size: CGSize(width: 1000, height: 800), origin: CGPoint(x: 3000, y: 10), current: CGRect(x: 2000, y: 200, width: 500, height: 500), visibleAreas: [screen, second])
        XCTAssertEqual(r, CGRect(x: 2432, y: 10, width: 1000, height: 800))
    }
}
