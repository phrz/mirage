import XCTest
@testable import MirageCore

final class StreamScaleTests: XCTestCase {
    func testSnapsOnlyNearNative() {
        XCTAssertTrue(StreamScale.snapsToNative(requestedWidth: 3022, nativeWidth: 3200))   // mac-daddy from a full-screen MacBook
        XCTAssertTrue(StreamScale.snapsToNative(requestedWidth: 3200, nativeWidth: 3200))
        XCTAssertFalse(StreamScale.snapsToNative(requestedWidth: 2560, nativeWidth: 3200), "20 % off: no snap, and never to another fraction")
        XCTAssertFalse(StreamScale.snapsToNative(requestedWidth: 1600, nativeWidth: 3200))
    }
}
