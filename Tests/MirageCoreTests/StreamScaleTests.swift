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

final class NativeStreamTests: XCTestCase {
    /// iOS asks for `StreamScale.nativeRequest`: whatever the display, the host resolves it to the display's own pixels,
    /// in either orientation of the phone (the request does not depend on it).
    func testNativeRequestResolvesToNativePixels() {
        for native in [(3024.0, 1964.0), (3200.0, 1800.0), (6016.0, 3384.0), (2560.0, 1600.0), (1440.0, 2560.0), (7680.0, 4320.0)] {
            let r = StreamScale.resolve(requested: StreamScale.nativeRequest, nativePixels: native, snapNative: true)
            XCTAssertEqual(r.width, Int(native.0) & ~1); XCTAssertEqual(r.height, Int(native.1) & ~1)
            let off = StreamScale.resolve(requested: StreamScale.nativeRequest, nativePixels: native, snapNative: false)
            XCTAssertEqual(off.width, Int(native.0) & ~1, "never beyond native, so no snap is needed")
        }
    }

    /// The old fit-sized iOS stream (an iPhone 17 Pro's portrait safe area, 1206×2334 px) was a third of a MacBook's pixels
    /// and changed with the orientation; requests near native still snap to it (the Mac viewer's full-screen window).
    func testFitRequestsAndSnap() {
        let mac = (3024.0, 1964.0)
        let portrait = StreamScale.resolve(requested: (1206, 2334), nativePixels: mac, snapNative: true)
        XCTAssertEqual(portrait.width, 1206); XCTAssertEqual(portrait.height, 782)
        let landscape = StreamScale.resolve(requested: (2622, 1206), nativePixels: mac, snapNative: true)
        XCTAssertNotEqual(landscape.width, portrait.width, "a fit-sized stream re-streams on rotation")
        let window = StreamScale.resolve(requested: (2880, 1800), nativePixels: mac, snapNative: true)
        XCTAssertEqual(window.width, 3024, "within 15 % of native: the Mac viewer's snap")
    }
}
