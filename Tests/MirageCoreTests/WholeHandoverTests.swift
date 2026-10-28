import XCTest
import CoreVideo
@testable import MirageHost

/// TRUTH for fresh pictures (phrz, 522: "windows pop in", "juddery"): the whole display shows until every visible window
/// layer is ready and the screen has settled; only then do the layers take over, in one step.
final class WholeHandoverTests: XCTestCase {
    typealias L = WholeHandover.LayerState
    let s = UInt64(1_000_000_000), settle = UInt64(300_000_000)

    func testWaitsForEveryVisibleLayerAndASettledScreen() {
        let since = 10 * s
        // A new window: a frame since the start, but no still yet; then with it.
        XCTAssertEqual(WholeHandover.waiting([L(id: 7, visible: 1, lastCaptured: 11 * s, existedAtStart: false, hasStill: false)], since: since, displayChangedAt: 0, now: 12 * s, settle: settle), [7])
        XCTAssertEqual(WholeHandover.waiting([L(id: 7, visible: 1, lastCaptured: 11 * s, existedAtStart: false, hasStill: true)], since: since, displayChangedAt: 0, now: 12 * s, settle: settle), [])
        // A window paused while locked: its picture from before does not count; a frame captured since does.
        XCTAssertEqual(WholeHandover.waiting([L(id: 8, visible: 0.5, lastCaptured: 9 * s, existedAtStart: true, hasStill: true)], since: since, displayChangedAt: 0, now: 12 * s, settle: settle), [8])
        XCTAssertEqual(WholeHandover.waiting([L(id: 8, visible: 0.5, lastCaptured: 10 * s + 1, existedAtStart: true, hasStill: false)], since: since, displayChangedAt: 0, now: 12 * s, settle: settle), [])
        // A window nobody can see does not hold it.
        XCTAssertEqual(WholeHandover.waiting([L(id: 9, visible: 0, lastCaptured: 0, existedAtStart: false, hasStill: false)], since: since, displayChangedAt: 0, now: 12 * s, settle: settle), [])
        // The unlock's fade still running: wait (the display, 0), whatever the layers.
        XCTAssertEqual(WholeHandover.waiting([], since: since, displayChangedAt: 12 * s - 100_000_000, now: 12 * s, settle: settle), [0])
        XCTAssertEqual(WholeHandover.waiting([], since: since, displayChangedAt: 12 * s - 400_000_000, now: 12 * s, settle: settle), [])
    }

    /// phrz on 537: the 8 s cap listed the windows while Claude's layer had no frame ("the second window clipped itself").
    /// The streamer no longer hands over at the cap; a layer whose capture is gone is the only one not waited for.
    func testALayerWithoutACaptureIsNotWaitedFor() {
        let since = 10 * s
        let gone = L(id: 9, visible: 0.4, lastCaptured: 0, existedAtStart: true, hasStill: false, capturing: false)
        let starting = L(id: 8, visible: 0.4, lastCaptured: 0, existedAtStart: true, hasStill: false)
        XCTAssertEqual(WholeHandover.waiting([gone, starting], since: since, displayChangedAt: 0, now: 30 * s, settle: settle), [8])
    }

    /// A window's first still at full resolution once the link is known to be fast (537: 210x338 for a 328x528 window on a
    /// LAN); unknown or slow, sized to the budget.
    func testWindowStillsAreFullSizeOnAFastLink() {
        XCTAssertTrue(MacDesktopStreamer.fullWindowStill(measuredKbps: 24_000))
        XCTAssertFalse(MacDesktopStreamer.fullWindowStill(measuredKbps: 0))
        XCTAssertFalse(MacDesktopStreamer.fullWindowStill(measuredKbps: 1_200))
    }

    /// 539: static windows deliver no frame after their capture restarts; the window-alone snapshot of the restart counts
    /// (the streamer passes the later of the two), and the display's settling is waited for only during the fade.
    func testASnapshotCountsAndLateActivityDoesNotHold() {
        let since = 10 * s
        let snapped = L(id: 7, visible: 0.5, lastCaptured: since + s / 5, existedAtStart: true, hasStill: false)
        XCTAssertEqual(WholeHandover.waiting([snapped], since: since, displayChangedAt: 0, now: since + 2 * s, settle: settle), [])
        XCTAssertEqual(WholeHandover.waiting([snapped], since: since, displayChangedAt: since + 2 * s, now: since + 2 * s, settle: settle), [0], "the fade")
        XCTAssertEqual(WholeHandover.waiting([snapped], since: since, displayChangedAt: since + 5 * s, now: since + 5 * s, settle: settle), [], "typing, a caret")
    }

    /// 546: the window-alone shot is a pixel larger than the layer (1457x1501 for 1456x1500), and was dropped.
    func testASnapshotIsFittedToItsLayer() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1457, 1501, kCVPixelFormatType_32BGRA, nil, &pb)
        let f = try XCTUnwrap(MacDesktopStreamer.fitted(try XCTUnwrap(pb), width: 1456, height: 1500))
        XCTAssertEqual(CVPixelBufferGetWidth(f), 1456); XCTAssertEqual(CVPixelBufferGetHeight(f), 1500)
        XCTAssertNil(MacDesktopStreamer.fitted(pb!, width: 800, height: 600), "another window, not rounding")
    }
    /// The lock screen's video quality on a LAN: a QP ceiling when the budget pays for it, none on a slow link.
    func testTheEncodersQualityFollowsTheBudget() {
        XCTAssertEqual(HEVCEncoder.maxQP(bitrateKbps: 45_000, width: 3200, height: 1800, fps: 30), 30)
        XCTAssertEqual(HEVCEncoder.maxQP(bitrateKbps: 10_000, width: 2914, height: 1640, fps: 30), 36)
        XCTAssertEqual(HEVCEncoder.maxQP(bitrateKbps: 1_000, width: 3200, height: 1800, fps: 30), 51)
    }
}

/// ScreenCaptureKit operations in turn, first come first served, and a hung one never holds the rest.
final class SCKGateTests: XCTestCase {
    final class Order: @unchecked Sendable { let lock = NSLock(); var events: [String] = []
        func add(_ e: String) { lock.lock(); events.append(e); lock.unlock() } }

    func testOneAtATimeInOrder() async throws {
        let gate = SCKGate(), order = Order()
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<3 {
                g.addTask { _ = try? await gate.run { order.add("start \(i)"); try await Task.sleep(for: .milliseconds(30)); order.add("end \(i)") } }
                try? await Task.sleep(for: .milliseconds(5))   // (queued in this order)
            }
        }
        XCTAssertEqual(order.events, ["start 0", "end 0", "start 1", "end 1", "start 2", "end 2"])
    }
    func testAHungOperationReleasesTheGate() async throws {
        let gate = SCKGate(), order = Order()
        let hung = Task { _ = try? await gate.run(holdAtMost: 0.1) { try await Task.sleep(for: .seconds(5)); order.add("hung done") } }
        try await Task.sleep(for: .milliseconds(20))
        let t0 = Date()
        _ = try await gate.run { order.add("next") }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1, "the next one ran once the hold ran out")
        XCTAssertEqual(order.events, ["next"])
        hung.cancel()
    }

    func testUrgentGoesFirst() async throws {
        let gate = SCKGate(), order = Order()
        let first = Task { _ = try? await gate.run { try await Task.sleep(for: .milliseconds(60)); order.add("running") } }
        try await Task.sleep(for: .milliseconds(10))
        let start = Task { _ = try? await gate.run { order.add("window start") } }
        try await Task.sleep(for: .milliseconds(10))
        let filter = Task { _ = try? await gate.run(urgent: true) { order.add("filter update") } }
        _ = await (first.value, start.value, filter.value)
        XCTAssertEqual(order.events, ["running", "filter update", "window start"])
    }
}
