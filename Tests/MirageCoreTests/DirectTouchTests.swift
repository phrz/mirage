import XCTest
import CoreGraphics
@testable import MirageCore

/// Direct touch (the iOS default): every gesture acts where the fingers are, and tap, swipe and hold are told apart by
/// travel and time alone.
final class DirectTouchTests: XCTestCase {
    private func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    func testTapClicksWhereItLands() {
        var d = DirectTouch()
        XCTAssertEqual(d.began(1, at: pt(100, 200), time: 0), [])
        XCTAssertEqual(d.moved(1, to: pt(103, 202), time: 0.05), [], "within the slop: still a tap")
        XCTAssertEqual(d.tick(time: 0.1), [])
        XCTAssertEqual(d.ended(1, at: pt(103, 202), time: 0.12), [.click(at: pt(103, 202), count: 1)])
        XCTAssertEqual(d.phase, .idle)
    }

    func testRepeatedTapsDoubleClickAtTheFirstPoint() {
        var d = DirectTouch()
        _ = d.began(1, at: pt(100, 100), time: 0)
        XCTAssertEqual(d.ended(1, at: pt(100, 100), time: 0.08), [.click(at: pt(100, 100), count: 1)])
        _ = d.began(2, at: pt(108, 104), time: 0.25)
        XCTAssertEqual(d.ended(2, at: pt(108, 104), time: 0.3), [.click(at: pt(100, 100), count: 2)], "within slop and interval: a double click where the first was")
        _ = d.began(3, at: pt(104, 98), time: 0.5)
        XCTAssertEqual(d.ended(3, at: pt(104, 98), time: 0.55), [.click(at: pt(100, 100), count: 3)])
        // Too far away, then too late: single clicks again.
        _ = d.began(4, at: pt(200, 100), time: 0.7)
        XCTAssertEqual(d.ended(4, at: pt(200, 100), time: 0.75), [.click(at: pt(200, 100), count: 1)])
        _ = d.began(5, at: pt(200, 100), time: 1.5)
        XCTAssertEqual(d.ended(5, at: pt(200, 100), time: 1.55), [.click(at: pt(200, 100), count: 1)])
    }

    func testHoldPressesDragsAndReleasesThere() {
        var d = DirectTouch()
        _ = d.began(1, at: pt(50, 60), time: 0)
        XCTAssertEqual(d.tick(time: 0.2), [], "not yet")
        _ = d.moved(1, to: pt(54, 62), time: 0.3)   // a resting finger wobbles a little
        XCTAssertEqual(d.tick(time: 0.36), [.holdBegan(at: pt(54, 62))])
        XCTAssertTrue(d.holding)
        XCTAssertEqual(d.moved(1, to: pt(120, 80), time: 0.5), [.holdMoved(to: pt(120, 80))], "after the hold, moving drags (no pan)")
        XCTAssertEqual(d.began(2, at: pt(300, 300), time: 0.6), [], "a second finger does not disturb a drag")
        XCTAssertEqual(d.moved(2, to: pt(320, 300), time: 0.65), [])
        XCTAssertEqual(d.ended(2, at: pt(320, 300), time: 0.7), [])
        XCTAssertEqual(d.ended(1, at: pt(130, 90), time: 0.8), [.holdEnded(at: pt(130, 90))])
        XCTAssertFalse(d.holding)
        XCTAssertEqual(d.tick(time: 2), [])
    }

    func testHoldWithoutMovingIsALongClick() {
        var d = DirectTouch()
        _ = d.began(1, at: pt(10, 10), time: 0)
        XCTAssertEqual(d.tick(time: 0.4), [.holdBegan(at: pt(10, 10))])
        XCTAssertEqual(d.ended(1, at: pt(10, 10), time: 1.2), [.holdEnded(at: pt(10, 10))])
    }

    /// One finger that moves past the slop before the hold fires pans the view; it never clicks or holds.
    func testSwipePansTheViewAndCoasts() {
        var d = DirectTouch()
        _ = d.began(1, at: pt(100, 100), time: 0)
        XCTAssertEqual(d.moved(1, to: pt(106, 100), time: 0.02), [])
        XCTAssertEqual(d.moved(1, to: pt(115, 100), time: 0.04), [.pan(dx: 15, dy: 0)], "past the slop: the whole travel pans")
        XCTAssertEqual(d.moved(1, to: pt(125, 104), time: 0.06), [.pan(dx: 10, dy: 4)])
        XCTAssertEqual(d.tick(time: 0.5), [], "a swipe never turns into a hold")
        let end = d.ended(1, at: pt(135, 108), time: 0.08)
        guard case .panEnded(let vx, let vy)? = end.first, end.count == 1 else { return XCTFail("\(end)") }
        XCTAssertGreaterThan(vx, 300); XCTAssertGreaterThan(vy, 50)
    }

    func testSwipeThatRestsBeforeLiftingDoesNotCoast() {
        var d = DirectTouch()
        _ = d.began(1, at: pt(0, 0), time: 0)
        _ = d.moved(1, to: pt(40, 0), time: 0.05)
        XCTAssertEqual(d.ended(1, at: pt(40, 0), time: 0.6), [.panEnded(vx: 0, vy: 0)])
    }

    /// Two fingers travelling together scroll where they came down: the pointer goes there first.
    func testTwoFingerSwipeScrollsAtTheSwipe() {
        var d = DirectTouch()
        _ = d.began(1, at: pt(200, 300), time: 0)
        XCTAssertEqual(d.began(2, at: pt(240, 300), time: 0.01), [])
        XCTAssertEqual(d.moved(1, to: pt(200, 292), time: 0.03), [], "undecided yet (the centre moved 4 pt)")
        let a = d.moved(2, to: pt(240, 282), time: 0.04)   // the centre: 300 → 287, past the 12-pt slop
        XCTAssertEqual(a, [.scrollBegan(at: pt(220, 300)), .scroll(dx: 0, dy: -13)])
        XCTAssertEqual(d.moved(1, to: pt(200, 276), time: 0.05), [.scroll(dx: 0, dy: -8)])
        XCTAssertEqual(d.tick(time: 0.6), [], "no hold, no right click")
        let end = d.ended(1, at: pt(200, 276), time: 0.06)
        guard case .scrollEnded(_, let vy)? = end.first else { return XCTFail("\(end)") }
        XCTAssertLessThan(vy, -100)
        XCTAssertEqual(d.moved(2, to: pt(240, 200), time: 0.07), [], "the gesture is over until every finger lifts")
        XCTAssertEqual(d.ended(2, at: pt(240, 200), time: 0.08), [])
        XCTAssertEqual(d.phase, .idle)
    }

    func testSpreadingFingersZoomInsteadOfScrolling() {
        var d = DirectTouch()
        _ = d.began(1, at: pt(100, 100), time: 0)
        _ = d.began(2, at: pt(200, 100), time: 0)
        let a = d.moved(2, to: pt(210, 100), time: 0.02)   // spread 100 → 110: ln 1.1 > 0.05, centre moved 5 pt
        XCTAssertEqual(a.first, .pinchBegan(at: pt(150, 100)))
        guard case .pinch(let s, let c)? = a.last else { return XCTFail("\(a)") }
        XCTAssertEqual(s, 1.1, accuracy: 1e-9); XCTAssertEqual(c, pt(155, 100))
        XCTAssertEqual(d.moved(1, to: pt(90, 100), time: 0.04), [.pinch(scale: 1.2, at: pt(150, 100))])
        XCTAssertEqual(d.ended(1, at: pt(90, 100), time: 0.1), [.pinchEnded])
        _ = d.ended(2, at: pt(210, 100), time: 0.12)
        XCTAssertEqual(d.tick(time: 1), [], "a pinch is no two-finger tap")
    }

    func testTwoFingerTapRightClicksAtItsCentreAfterTheDoubleTapWait() {
        var d = DirectTouch()
        _ = d.began(1, at: pt(100, 100), time: 0)
        _ = d.began(2, at: pt(140, 120), time: 0.01)
        XCTAssertEqual(d.ended(1, at: pt(100, 100), time: 0.1), [])
        XCTAssertEqual(d.ended(2, at: pt(140, 120), time: 0.11), [])
        XCTAssertEqual(d.tick(time: 0.3), [], "waiting: it may be a double tap")
        XCTAssertEqual(d.tick(time: 0.42), [.rightClick(at: pt(120, 110))])
        XCTAssertEqual(d.tick(time: 1), [])
    }

    func testTwoFingerDoubleTapTogglesZoomWithoutARightClick() {
        var d = DirectTouch()
        for (t0, _) in [(0.0, 0), (0.25, 1)] {
            _ = d.began(1, at: pt(100, 100), time: t0); _ = d.began(2, at: pt(140, 100), time: t0)
            let a = d.ended(1, at: pt(100, 100), time: t0 + 0.08) + d.ended(2, at: pt(140, 100), time: t0 + 0.09)
            if t0 > 0 { XCTAssertEqual(a, [.zoomToggle(at: pt(120, 100))]) } else { XCTAssertEqual(a, []) }
            XCTAssertEqual(d.tick(time: t0 + 0.2), [])
        }
        XCTAssertEqual(d.tick(time: 2), [], "no right click left over")
    }

    func testAWaitingRightClickGoesOutBeforeTheNextTap() {
        var d = DirectTouch()
        _ = d.began(1, at: pt(100, 100), time: 0); _ = d.began(2, at: pt(140, 100), time: 0)
        _ = d.ended(1, at: pt(100, 100), time: 0.05); _ = d.ended(2, at: pt(140, 100), time: 0.05)
        _ = d.began(3, at: pt(300, 300), time: 0.1)
        XCTAssertEqual(d.ended(3, at: pt(300, 300), time: 0.15), [.rightClick(at: pt(120, 100)), .click(at: pt(300, 300), count: 1)])
    }

    func testThreeFingersPanTheView() {
        var d = DirectTouch()
        _ = d.began(1, at: pt(100, 100), time: 0); _ = d.began(2, at: pt(150, 100), time: 0)
        XCTAssertEqual(d.began(3, at: pt(200, 100), time: 0.01), [])
        XCTAssertEqual(d.moved(1, to: pt(130, 100), time: 0.03), [.pan(dx: 10, dy: 0)], "the three fingers' centre")
        let end = d.ended(1, at: pt(130, 100), time: 0.05)
        guard case .panEnded? = end.first else { return XCTFail("\(end)") }
    }

    func testCancelEndsAHoldWithoutAClick() {
        var d = DirectTouch()
        _ = d.began(1, at: pt(5, 5), time: 0)
        _ = d.tick(time: 0.4)
        XCTAssertEqual(d.cancel(), [.holdEnded(at: pt(5, 5))])
        XCTAssertEqual(d.phase, .idle)
        _ = d.began(2, at: pt(5, 5), time: 1)
        XCTAssertEqual(d.cancel(), [], "a pending touch just goes")
        XCTAssertEqual(d.tick(time: 2), [])
    }

    /// The mode is kept in UserDefaults; direct touch unless set otherwise (or set to something unknown).
    func testTouchModeDefaultsToDirectAndPersists() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "DirectTouchTests"))
        d.removePersistentDomain(forName: "DirectTouchTests")
        defer { d.removePersistentDomain(forName: "DirectTouchTests") }
        XCTAssertEqual(TouchMode.stored(d), .direct)
        TouchMode.trackpad.store(d)
        XCTAssertEqual(TouchMode.stored(d), .trackpad)
        XCTAssertEqual(d.string(forKey: TouchMode.defaultsKey), "trackpad")
        TouchMode.direct.store(d)
        XCTAssertEqual(TouchMode.stored(d), .direct)
        d.set("joystick", forKey: TouchMode.defaultsKey)
        XCTAssertEqual(TouchMode.stored(d), .direct)
    }

    /// A one-finger swipe at fit: nothing to pan, so the picture gives a little (rubber band) and settles back.
    func testSwipeAtFitOnlyRubberBands() {
        var v = ZoomViewport()
        v.setLayout(container: CGRect(x: 0, y: 0, width: 400, height: 800), keyboardTop: nil, content: CGSize(width: 1600, height: 1000))
        let o = v.origin
        for _ in 0..<20 { v.pan(by: CGPoint(x: 10, y: 0), rubberBand: true) }
        XCTAssertEqual(v.origin, o, "nothing moves at fit")
        XCTAssertGreaterThan(v.overscroll.x, 10)
        XCTAssertLessThanOrEqual(v.overscroll.x, ZoomViewport.rubberLimit)
        XCTAssertEqual(v.pictureRect.minX, o.x + v.overscroll.x, accuracy: 1e-9, "the picture is drawn stretched")
        v.pan(by: CGPoint(x: -50, y: 0), rubberBand: true)
        XCTAssertEqual(v.pull.x, 150, accuracy: 1e-9, "travel back undoes the stretch first")
        for _ in 0..<120 { v.relax(dt: 1.0 / 60) }
        XCTAssertEqual(v.overscroll, .zero, "springs back")
    }

    /// Zoomed, the swipe pans until the edge, then stretches.
    func testSwipeZoomedPansThenStretchesAtTheEdge() {
        var v = ZoomViewport()
        v.setLayout(container: CGRect(x: 0, y: 0, width: 400, height: 800), keyboardTop: nil, content: CGSize(width: 1600, height: 1000))
        v.setZoom(3, about: CGPoint(x: 200, y: 400))
        let o = v.origin
        v.pan(by: CGPoint(x: 30, y: 0), rubberBand: true)
        XCTAssertEqual(v.origin.x, o.x + 30, accuracy: 1e-9)
        XCTAssertEqual(v.pull, .zero)
        v.pan(by: CGPoint(x: 10_000, y: 0), rubberBand: true)
        XCTAssertEqual(v.origin.x, 0, accuracy: 1e-9, "the left edge meets the container's")
        XCTAssertGreaterThan(v.overscroll.x, 0)
    }
}
