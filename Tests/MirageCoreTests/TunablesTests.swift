import XCTest
@testable import MirageCore

/// Host-given numbers for the viewer's local behaviour (DESIGN §3.0).
final class TunablesTests: XCTestCase {
    func testDefaultsClampingAndUnknownKeys() {
        let none = Tunables(values: [:])
        for k in Tunables.Key.allCases { XCTAssertEqual(none[k], k.spec.default, "\(k): default when the host sent nothing") }
        let t = Tunables(values: ["pinchRatio": 0.25, "holdDelay": 99, "maxZoom": -4, "crossfadeMs": .nan, "someFutureKey": 7])
        XCTAssertEqual(t[.pinchRatio], 0.25)
        XCTAssertEqual(t[.holdDelay], Tunables.Key.holdDelay.spec.max, "clamped to the key's bounds")
        XCTAssertEqual(t[.maxZoom], Tunables.Key.maxZoom.spec.min)
        XCTAssertEqual(t[.crossfadeMs], 220, "not finite: the default")
        XCTAssertEqual(Tunables.host(overrides: ["someFutureKey": 7]).values["someFutureKey"], 7, "the host keeps keys a newer viewer may know")
    }

    func testWireRoundTripAndTheRequestFlag() throws {
        let t = Tunables.host(overrides: ["scrollLeadFraction": 0.25])
        let framed = try Frame.encode(ControlMessage.tunables(t))
        XCTAssertEqual(try Frame.decode(ControlMessage.self, from: framed.dropFirst(4)), .tunables(t))
        // An older viewer's request carries no flag: it decodes as nil, and the host sends it no tunables message.
        let old = try JSONDecoder().decode(ControlMessage.StreamRequest.self, from: Data(#"{"width":100,"height":50,"bitrateKbps":800,"maxFPS":30}"#.utf8))
        XCTAssertNil(old.tunablesVersion)
        XCTAssertEqual(ControlMessage.StreamRequest(width: 1, height: 1, tunablesVersion: Tunables.schemaVersion).tunablesVersion, 1)
    }

    func testApplyingToTheViewerParts() {
        let t = Tunables(values: ["pinchRatio": 0.3, "holdDelay": 0.5, "maxZoom": 4, "scrollLeadFraction": 0.5, "levelFadeMs": 100])
        var k = TwoFingerClassifier(); t.apply(to: &k); XCTAssertEqual(k.pinchRatio, 0.3)
        var d = DirectTouch(); t.apply(to: &d); XCTAssertEqual(d.holdDelay, 0.5); XCTAssertEqual(d.twoFinger.pinchRatio, 0.3)
        var v = ZoomViewport(); t.apply(to: &v); XCTAssertEqual(v.maxZoom, 4)
        var p = Predictor(); t.apply(to: &p); XCTAssertEqual(p.scrollLeadFraction, 0.5)
        XCTAssertEqual(t.levelFadeNanos, 100_000_000)
    }
}
