import XCTest
@testable import MirageHost
@testable import MirageCore

/// The whole display as video (tunable wholeDisplayOnly, docs/reset): off by default; one capture, one video frame.
final class WholeDisplayOnlyTests: XCTestCase {
    func testOffByDefault() {
        XCTAssertEqual(Tunables.defaults[.wholeDisplayOnly], 0)
        XCTAssertEqual(Tunables.host(overrides: ["wholeDisplayOnly": 1])[.wholeDisplayOnly], 1)
        XCTAssertEqual(Tunables.host(overrides: ["wholeDisplayOnly": 7])[.wholeDisplayOnly], 1, "clamped")
    }
    /// TRUTH: every presented frame is one capture. A capture's changed tiles all go in its video frame; none are left for
    /// tiles later (the layered path's direct tiles, rate-held tiles, small-animation tiles and fovea split one capture).
    func testEveryChangedTileOfACaptureGoesInItsVideoFrame() {
        for dirty in [[0], [3, 4, 5, 90], Array(0..<1450)] {
            let r = MacDesktopStreamer.wholeOnlyRoute(dirty: dirty)
            XCTAssertEqual(r.video, dirty); XCTAssertTrue(r.tiles.isEmpty)
        }
    }
    /// The sharpening pass: a low QP ceiling while the screen stands still, the budget's ceiling again at the next change.
    func testSharpeningTogglesTheEncodersCeiling() throws {
        let enc = try HEVCEncoder(width: 256, height: 144, bitrateKbps: 20_000, expectedFPS: 30)
        XCTAssertFalse(enc.sharpening)
        enc.setSharpening(true); XCTAssertTrue(enc.sharpening)
        enc.setSharpening(false); XCTAssertFalse(enc.sharpening)
        XCTAssertLessThan(HEVCEncoder.sharpenQP, HEVCEncoder.maxQP(bitrateKbps: 50_000, width: 3200, height: 1800, fps: 30))
    }
}
