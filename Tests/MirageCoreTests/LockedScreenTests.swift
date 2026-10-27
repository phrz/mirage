import XCTest
@testable import MirageHost

/// While the host is locked the viewer sees the lock screen whole, never the desktop beneath it (phrz, 2026-10-28: the
/// compositor model's desktop capture showed the wallpaper and Finder's icons behind mac-daddy's lock screen).
final class LockedScreenTests: XCTestCase {
    func testEveryCaptureIsTheWholeDisplayWhileLocked() {
        typealias P = ScreenCapturer.FilterPlan
        for src in [ScreenCapturer.Source.display, .desktop, .overlay] {
            XCTAssertEqual(ScreenCapturer.filterPlan(source: src, locked: true), P.wholeDisplay, "\(src) while locked")
        }
        XCTAssertEqual(ScreenCapturer.filterPlan(source: .desktop, locked: false), P.desktop)
        XCTAssertEqual(ScreenCapturer.filterPlan(source: .display, locked: false), P.displayExcludingLayers)
        XCTAssertEqual(ScreenCapturer.filterPlan(source: .overlay, locked: false), P.displayExcludingLayers)
    }
    func testAPresetLockBeforeStart() {
        let c = ScreenCapturer(queue: DispatchQueue(label: "t")); c.source = .desktop
        XCTAssertFalse(c.locked)
        c.presetLocked(true)
        XCTAssertTrue(c.locked)
        XCTAssertEqual(ScreenCapturer.filterPlan(source: c.source, locked: c.locked), .wholeDisplay, "a stream starting while locked starts on the whole display")
    }
}
