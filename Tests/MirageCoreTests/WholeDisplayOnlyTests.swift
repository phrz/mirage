import XCTest
@testable import MirageHost
@testable import MirageCore

/// The whole display as video (tunable wholeDisplayOnly, docs/reset): on by default (Desktop mode); one capture, one video frame.
final class WholeDisplayOnlyTests: XCTestCase {
    func testOnByDefault() {
        XCTAssertEqual(Tunables.defaults[.wholeDisplayOnly], 1)
        XCTAssertEqual(Tunables.host(overrides: ["wholeDisplayOnly": 0])[.wholeDisplayOnly], 0, "the off switch")
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
    /// Video's tile key ranks the size the encoder ran at, never the controller's rung: a 400-wide frame of a 3200-wide
    /// display is the tiny rung's rank even after the probe moved the rung to native, so the native frame after it wins.
    func testVideoKeyRanksTheEncodedSize() {
        XCTAssertEqual(MacDesktopStreamer.encodedRung(encodedWidth: 400, layerWidth: 3200), RateController.tinyRung)
        XCTAssertEqual(MacDesktopStreamer.encodedRung(encodedWidth: 3200, layerWidth: 3200), 0)
        XCTAssertEqual(MacDesktopStreamer.encodedRung(encodedWidth: 2400, layerWidth: 3200), 1)
        XCTAssertEqual(MacDesktopStreamer.encodedRung(encodedWidth: 1600, layerWidth: 3200), 2)
        XCTAssertEqual(MacDesktopStreamer.encodedRung(encodedWidth: 64, layerWidth: 300), RateController.tinyRung, "the 64-px floor")
        let tiny = TileKey.make(contentSeq: 7, rank: TileKey.video(rung: MacDesktopStreamer.encodedRung(encodedWidth: 400, layerWidth: 3200)))
        let native = TileKey.make(contentSeq: 7, rank: TileKey.video(rung: MacDesktopStreamer.encodedRung(encodedWidth: 3200, layerWidth: 3200)))
        XCTAssertGreaterThan(native, tiny)
    }
    /// A change between Desktop and Unified mode changes the pipeline, so it starts a whole picture.
    func testViewModeChangeRestartsTheWholePicture() {
        XCTAssertTrue(FreshPictureTrigger.viewMode.restartsWholePicture)
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
