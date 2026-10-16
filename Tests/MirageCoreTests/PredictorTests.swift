import XCTest
@testable import MirageCore

final class PredictorTests: XCTestCase {
    let rect = PixelRect(x: 100, y: 100, width: 800, height: 600)

    func testScrollPredictionIsConsumedByHostCopyRect() {
        var p = Predictor()
        p.predict(kind: .scroll, windowID: 7, rect: rect, dx: 0, dy: -40, inputSeq: 10, now: 1)
        p.predict(kind: .scroll, windowID: 7, rect: rect, dx: 0, dy: -30, inputSeq: 11, now: 2)
        XCTAssertEqual(p.displacements(), [.init(kind: .scroll, windowID: 7, rect: rect, dx: 0, dy: -70)])
        p.hostCopyRect(windowID: 7, rect: rect, dx: 0, dy: -40, now: 3)
        XCTAssertEqual(p.displacements().first?.dy, -30)
        p.hostCopyRect(windowID: 7, rect: rect, dx: 0, dy: -30, now: 4)
        XCTAssertTrue(p.displacements().isEmpty)
        XCTAssertEqual(p.stats.confirmed, 2); XCTAssertEqual(p.stats.mismatched, 0)
    }

    func testHostAnsweringWithVideoRetiresThePrediction() {
        var p = Predictor()
        p.predict(kind: .scroll, windowID: 7, rect: rect, dx: 0, dy: -40, inputSeq: 10, now: 1)
        // A video frame covering the rect, reflecting input 10, with no copy-rect: mismatch → hidden, confidence off.
        p.hostUpdate(inputSeq: 10, rect: rect, now: 5)
        XCTAssertTrue(p.displacements().isEmpty)
        XCTAssertFalse(p.isConfident(7))
        XCTAssertEqual(p.stats.mismatched, 1)
        // While not confident, predictions are tracked silently…
        p.predict(kind: .scroll, windowID: 7, rect: rect, dx: 0, dy: -40, inputSeq: 12, now: 6)
        XCTAssertTrue(p.displacements().isEmpty)
        // …and a matching host copy-rect restores confidence.
        p.hostCopyRect(windowID: 7, rect: rect, dx: 0, dy: -40, now: 7)
        XCTAssertTrue(p.isConfident(7))
    }

    func testUpdateForAnOlderInputDoesNotRetire() {
        var p = Predictor()
        p.predict(kind: .scroll, windowID: 7, rect: rect, dx: 0, dy: -40, inputSeq: 10, now: 1)
        p.hostUpdate(inputSeq: 9, rect: rect, now: 2)
        XCTAssertEqual(p.displacements().count, 1)
        p.hostUpdate(inputSeq: 10, rect: PixelRect(x: 2000, y: 2000, width: 10, height: 10), now: 3)   // elsewhere
        XCTAssertEqual(p.displacements().count, 1)
    }

    func testOppositeDirectionIsAMismatch() {
        var p = Predictor()
        p.predict(kind: .scroll, windowID: 7, rect: rect, dx: 0, dy: -40, inputSeq: 10, now: 1)
        p.hostCopyRect(windowID: 7, rect: rect, dx: 0, dy: 40, now: 2)
        XCTAssertTrue(p.displacements().isEmpty); XCTAssertFalse(p.isConfident(7))
    }

    func testExpiryAndRecovery() {
        var p = Predictor()
        p.timeoutNanos = 100; p.recoverNanos = 1000
        p.predict(kind: .drag, windowID: 3, rect: rect, dx: 20, dy: 10, inputSeq: 1, now: 0)
        p.expire(now: 50)
        XCTAssertEqual(p.displacements().count, 1)
        p.expire(now: 200)
        XCTAssertTrue(p.displacements().isEmpty); XCTAssertFalse(p.isConfident(3)); XCTAssertEqual(p.stats.expired, 1)
        p.expire(now: 1500)
        XCTAssertTrue(p.isConfident(3))
    }

    func testDragConsumesPerAxisAndUnknownWindowMatchesByRect() {
        var p = Predictor()
        p.predict(kind: .drag, windowID: 3, rect: rect, dx: 20, dy: 10, inputSeq: 1, now: 0)
        p.predict(kind: .drag, windowID: 3, rect: rect, dx: 15, dy: 5, inputSeq: 2, now: 1)
        p.hostCopyRect(windowID: 0, rect: rect, dx: 20, dy: 15, now: 2)   // host did not know the window
        XCTAssertEqual(p.displacements(), [.init(kind: .drag, windowID: 3, rect: rect, dx: 15, dy: 0)])
    }
}
