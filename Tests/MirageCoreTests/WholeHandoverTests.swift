import XCTest
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
}
