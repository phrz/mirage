import XCTest
@testable import MirageCore

final class TouchInputTests: XCTestCase {
    func testTypedCharactersMapToUSKeys() {
        XCTAssertEqual(MacKeys.key(for: "a")?.keyCode, 0)
        XCTAssertEqual(MacKeys.key(for: "a")?.shift, false)
        XCTAssertEqual(MacKeys.key(for: "A")?.keyCode, 0)
        XCTAssertEqual(MacKeys.key(for: "A")?.shift, true)
        XCTAssertEqual(MacKeys.key(for: "!")?.keyCode, 18)
        XCTAssertEqual(MacKeys.key(for: "!")?.shift, true)
        XCTAssertEqual(MacKeys.key(for: "\n")?.keyCode, MacKeys.returnKey)
        XCTAssertEqual(MacKeys.key(for: " ")?.keyCode, MacKeys.space)
        XCTAssertEqual(MacKeys.key(for: "?")?.keyCode, 44)
        XCTAssertNil(MacKeys.key(for: "é"))
        XCTAssertNil(MacKeys.key(for: "😀"))
    }

    func testHIDUsagesMapToMacKeyCodes() {
        XCTAssertEqual(MacKeys.keyCode(hidUsage: 4), 0)       // a
        XCTAssertEqual(MacKeys.keyCode(hidUsage: 29), 6)      // z
        XCTAssertEqual(MacKeys.keyCode(hidUsage: 30), 18)     // 1
        XCTAssertEqual(MacKeys.keyCode(hidUsage: 39), 29)     // 0
        XCTAssertEqual(MacKeys.keyCode(hidUsage: 42), MacKeys.delete)
        XCTAssertEqual(MacKeys.keyCode(hidUsage: 58), 122)    // F1
        XCTAssertEqual(MacKeys.keyCode(hidUsage: 82), MacKeys.up)
        XCTAssertEqual(MacKeys.keyCode(hidUsage: 227), MacKeys.command)
        XCTAssertTrue(MacKeys.isModifier(MacKeys.keyCode(hidUsage: 225)!))
        XCTAssertFalse(MacKeys.isModifier(0))
        XCTAssertNil(MacKeys.keyCode(hidUsage: 1000))
        XCTAssertEqual(MacKeys.characters(forSpecialKey: MacKeys.up), "\u{F700}")
        XCTAssertEqual(MacKeys.characters(forSpecialKey: 122), "\u{F704}")   // F1
        XCTAssertEqual(MacKeys.characters(forSpecialKey: MacKeys.delete), "\u{7F}")
        XCTAssertNil(MacKeys.characters(forSpecialKey: 0))
    }

    func testPointerMovesRelativelyAndClamps() {
        var p = TrackpadPointer()
        p.move(dx: 10, dy: 0, pictureWidth: 1000, pictureHeight: 500, dt: 1)   // 10 pt/s: almost no acceleration
        XCTAssertEqual(p.x, 0.51, accuracy: 0.001)
        XCTAssertEqual(p.y, 0.5)
        let slow = p.x
        var q = TrackpadPointer()
        q.move(dx: 10, dy: 0, pictureWidth: 1000, pictureHeight: 500, dt: 0.005)   // a flick: accelerated
        XCTAssertGreaterThan(q.x - 0.5, (slow - 0.5) * 2)
        q.move(dx: -100_000, dy: 100_000, pictureWidth: 1000, pictureHeight: 500, dt: 0.01)
        XCTAssertEqual(q.x, 0); XCTAssertEqual(q.y, 1)
    }

    func testMomentumCoastsAndStops() {
        var m = ScrollMomentum()
        m.start(vx: 0, vy: 1000)
        var total = 0.0, steps = 0
        while m.active, steps < 1000 { total += m.step(dt: 1.0 / 60).dy; steps += 1 }
        // The integral of v·decay^t to the stop speed is close to v / -ln(decay).
        XCTAssertEqual(total, 1000 / -log(0.135), accuracy: 15)
        XCTAssertLessThan(steps, 200)
        XCTAssertEqual(m.step(dt: 1.0 / 60).dy, 0)
    }
}
