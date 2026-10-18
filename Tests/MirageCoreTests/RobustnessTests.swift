import XCTest
@testable import MirageCore

/// The M3.1 viewer crashes were arithmetic traps: a UInt64 clock difference taken against a stamp from another
/// queue (later than `now`). Clock differences saturate, and windows that hang off the display in every
/// direction go through every layered-desktop path without trapping.
final class RobustnessTests: XCTestCase {
    func testClockDifferencesSaturate() {
        XCTAssertEqual(Clock.elapsed(since: 100, now: 250), 150)
        XCTAssertEqual(Clock.elapsed(since: 250, now: 100), 0, "a stamp taken after `now` is not negative time")
        XCTAssertEqual(Clock.elapsed(since: .max, now: 0), 0)
        XCTAssertEqual(Clock.elapsed(since: 0, now: .max), .max)
        // Out-of-order times through the stateful users.
        var g = DisplayGuard(historyNanos: 1_000_000_000, margin: 64)
        g.update(layered: [1: PixelRect(x: 0, y: 0, width: 100, height: 100)], now: 5_000_000_000)
        g.update(layered: [1: PixelRect(x: 50, y: 0, width: 100, height: 100)], now: 4_000_000_000)   // earlier than the last update
        _ = g.guardedRects(now: 3_000_000_000)
        XCTAssertFalse(g.allows(PixelRect(x: 60, y: 10, width: 4, height: 4), now: 3_000_000_000))
        var p = Predictor()
        p.beginDrag(windowID: 1, frame: PixelRect(x: 0, y: 0, width: 100, height: 100), pointer: (10, 10), inputSeq: 1, now: 9_000)
        p.dragPointer(windowID: 1, pointer: (20, 10), inputSeq: 2, now: 8_000)
        p.expire(now: 1_000)
        var a = FrameAssembler()
        let f = VideoFragment(frameSeq: 1, fragIndex: 0, fragCount: 2, flags: [], captureNanos: 1, frameBytes: 10, payload: Data(count: 5))
        _ = a.ingest(f, now: 9_000_000_000)
        _ = a.tick(now: 1_000)   // a tick with an earlier clock than the last arrival
        var rc = RateController(initialKbps: 800, maxKbps: 800, nativePixels: 1000)
        rc.tick(now: 10_000_000_000)
        rc.probeSample(sentNanos: 5, receivedNanos: 9_000_000_000, now: 1_000)
        rc.tick(now: 500)
    }

    func testWindowsHangingOffEveryEdge() {
        let display = PixelRect(x: 0, y: 0, width: 640, height: 384)
        let tracker = TileTracker(width: display.width, height: display.height)
        let left = PixelRect(x: -300, y: -50, width: 400, height: 200)      // negative origin
        let right = PixelRect(x: 600, y: 300, width: 400, height: 400)      // beyond the right and bottom edges
        let huge = PixelRect(x: -26838, y: -27500, width: 56700, height: 56700)
        for r in [left, right, huge] {
            for t in tracker.tiles(covering: [r]) { XCTAssertTrue(t >= 0 && t < tracker.tileCount) }
            _ = r.subtracting(display); _ = display.subtracting(r)
        }
        XCTAssertEqual(Set(tracker.tiles(covering: [left])), Set(tracker.tiles(covering: [PixelRect(x: 0, y: 0, width: 100, height: 150)])))
        var g = DisplayGuard(historyNanos: 1_000_000_000, margin: 128)
        g.update(layered: [1: left, 2: right], verified: [1], now: 0)
        g.update(layered: [1: left.offset(-500, -500), 2: right.offset(700, 700)], verified: [1], now: 10)
        for t in g.guardedTiles(tracker, now: 20) { XCTAssertTrue(t >= 0 && t < tracker.tileCount) }
        var taint = DisplayTaint()
        taint.sent(Array(0..<tracker.tileCount), tracker: tracker, windowAreas: [left, right, huge])
        XCTAssertEqual(taint.due(hidden: [], tracker: tracker, windowAreas: [left, right, huge]), [])
        let windows = [
            ControlMessage.WindowInfo(id: 1, pid: 1, title: "", frame: left, z: 0, level: 0, layered: true, excludedFrom: 3),
            ControlMessage.WindowInfo(id: 2, pid: 2, title: "", frame: right, z: 1, level: 0, layered: true, opaque: false),
            ControlMessage.WindowInfo(id: 3, pid: 3, title: "", frame: huge, z: 2, level: 2001, app: "loginwindow", cutout: true),
            ControlMessage.WindowInfo(id: 4, pid: 4, title: "", frame: PixelRect(x: -20, y: 370, width: 40, height: 40), z: 3, level: 101, cutout: true),
        ]
        let plan = LayerScenePlan.plan(windows, hasCanvas: { _ in true }, display: display, shadowMargin: 64)
        XCTAssertEqual(plan.entries.count, 4)
        XCTAssertEqual(plan.entries[2].kind, .displayOnly, "a desktop-sized shield is never a cut-out")
        for w in windows { _ = WindowTrackerOcclusion.occlusion(of: w, in: windows, display: display) }
        XCTAssertFalse(windows[1].hidesBehind)
        XCTAssertTrue(windows[0].hidesBehind)
    }
}
