import XCTest
@testable import MirageCore

/// The lock guard fails closed: any one signal saying "locked" is locked (M3.1 field run: IOConsoleLocked
/// false, CGSSessionScreenIsLocked 1, loginwindow shields on screen).
final class ScreenLockTests: XCTestCase {
    func testSessionFlagBridgesFromEveryType() {
        XCTAssertEqual(ScreenLock.sessionLocked(["CGSSessionScreenIsLocked": true]), true)
        XCTAssertEqual(ScreenLock.sessionLocked(["CGSSessionScreenIsLocked": NSNumber(value: 1)]), true)
        XCTAssertEqual(ScreenLock.sessionLocked(["CGSSessionScreenIsLocked": 1]), true)
        XCTAssertEqual(ScreenLock.sessionLocked(["CGSSessionScreenIsLocked": "1"]), true)
        XCTAssertEqual(ScreenLock.sessionLocked(["CGSSessionScreenIsLocked": kCFBooleanTrue as Any]), true)
        XCTAssertEqual(ScreenLock.sessionLocked(["CGSSessionScreenIsLocked": 0]), false)
        XCTAssertNil(ScreenLock.sessionLocked(["kCGSSessionOnConsoleKey": 1]), "absent key is unknown, not unlocked")
        XCTAssertNil(ScreenLock.sessionLocked(nil))
    }

    func testAnySignalLocks() {
        XCTAssertTrue(ScreenLock.Signals(sessionScreenIsLocked: true, ioConsoleLocked: false, shieldWindow: false).locked, "the field case")
        XCTAssertTrue(ScreenLock.Signals(sessionScreenIsLocked: nil, ioConsoleLocked: true, shieldWindow: false).locked)
        XCTAssertTrue(ScreenLock.Signals(sessionScreenIsLocked: false, ioConsoleLocked: false, shieldWindow: true).locked)
        XCTAssertFalse(ScreenLock.Signals(sessionScreenIsLocked: false, ioConsoleLocked: false, shieldWindow: false).locked)
        XCTAssertFalse(ScreenLock.Signals(sessionScreenIsLocked: nil, ioConsoleLocked: nil, shieldWindow: false).locked)
    }

    func testShieldWindowFromTheWindowList() {
        let display = PixelRect(x: 0, y: 0, width: 3024, height: 1700)
        // As mac-daddy's host logged them while locked.
        let shield = ControlMessage.WindowInfo(id: 12177, pid: 1, title: "", frame: PixelRect(x: 0, y: 0, width: 3024, height: 1701), z: 0, level: 2004, app: "loginwindow")
        let huge = ControlMessage.WindowInfo(id: 12176, pid: 1, title: "", frame: PixelRect(x: -26838, y: -27500, width: 56700, height: 56700), z: 1, level: 2001, app: "loginwindow")
        let bench = ControlMessage.WindowInfo(id: 9, pid: 2, title: "Mirage Test Bench", frame: PixelRect(x: 100, y: 100, width: 800, height: 500), z: 2, level: 0, app: "Mirage Test Bench")
        XCTAssertTrue(ScreenLock.shieldPresent([shield, huge, bench], display: display))
        XCTAssertTrue(ScreenLock.shieldPresent([huge, bench], display: display))
        XCTAssertFalse(ScreenLock.shieldPresent([bench], display: display))
        // A small loginwindow window (a password sheet over an unlocked session) is not the lock screen.
        let sheet = ControlMessage.WindowInfo(id: 3, pid: 1, title: "", frame: PixelRect(x: 1000, y: 600, width: 400, height: 300), z: 0, level: 2004, app: "loginwindow")
        XCTAssertFalse(ScreenLock.shieldPresent([sheet, bench], display: display))
        // Cut-out policy never draws the shields over layers.
        XCTAssertEqual(LayerScenePlan.plan([shield, bench], hasCanvas: { _ in false }, display: display).entries[0].kind, .displayOnly)
    }
}
