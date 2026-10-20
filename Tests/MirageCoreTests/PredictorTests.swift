import XCTest
@testable import MirageCore

final class PredictorTests: XCTestCase {
    let rect = PixelRect(x: 100, y: 100, width: 800, height: 600)

    func testScrollPredictionIsConsumedByHostCopyRect() {
        var p = Predictor()
        p.predict(kind: .scroll, windowID: 7, rect: rect, dx: 0, dy: -40, inputSeq: 10, now: 1)
        p.predict(kind: .scroll, windowID: 7, rect: rect, dx: 0, dy: -30, inputSeq: 11, now: 2)
        // Shown with the rubber band (51ba1fa): the remainder, resisted beyond small leads (a third of the 600-px view).
        XCTAssertEqual(p.displacements(), [.init(kind: .scroll, windowID: 7, rect: rect, dx: 0, dy: Predictor.rubberBand(-70, limit: 200))])
        p.hostCopyRect(windowID: 7, rect: rect, dx: 0, dy: -40, now: 3)
        XCTAssertEqual(p.displacements().first?.dy, Predictor.rubberBand(-30, limit: 200))
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

final class DragPredictionTests: XCTestCase {
    /// The host reports a diagonal drag axis by axis (window list) and coalesces moves; the client's
    /// displacement must stay (pointer − last confirmation) and every copy-rect must confirm.
    func testDragFollowsPointerAndConfirmsPerAxisHostCopyRects() {
        var p = Predictor()
        let frame = PixelRect(x: 100, y: 100, width: 400, height: 300)
        p.beginDrag(windowID: 7, frame: frame, pointer: (300, 110), inputSeq: 1, now: 0)
        var seq: UInt64 = 1
        var x = 300, y = 110
        var now: UInt64 = 0
        // 10 pointer moves of (6, 3) with no host answer yet: the window follows the pointer fully.
        for _ in 0..<10 { seq += 1; x += 6; y += 3; now += 16_000_000; p.dragPointer(windowID: 7, pointer: (x, y), inputSeq: seq, now: now) }
        XCTAssertEqual(p.displacements().first?.dx, 60); XCTAssertEqual(p.displacements().first?.dy, 30)
        XCTAssertEqual(p.displacements().first?.rect, frame)
        // The host confirms the first 4 moves axis by axis: (24, 0) at seq 5, then (0, 12) at seq 5.
        p.hostCopyRect(windowID: 7, rect: frame, dx: 24, dy: 0, inputSeq: 5, now: now)
        p.hostCopyRect(windowID: 7, rect: frame.offset(24, 0), dx: 0, dy: 12, inputSeq: 5, now: now)
        XCTAssertEqual(p.stats.confirmed, 2); XCTAssertEqual(p.stats.mismatched, 0)
        XCTAssertEqual(p.displacements().first?.dx, 36, "residual = pointer − confirmed"); XCTAssertEqual(p.displacements().first?.dy, 18)
        XCTAssertEqual(p.displacements().first?.rect, frame.offset(24, 12), "displaced from the confirmed frame")
        // A coalesced copy-rect for the rest (36, 18) at seq 11: confirmed, nothing left to show.
        p.hostCopyRect(windowID: 7, rect: frame.offset(24, 12), dx: 36, dy: 18, inputSeq: 11, now: now)
        XCTAssertEqual(p.stats.confirmed, 3)
        XCTAssertTrue(p.displacements().isEmpty)
        // More moves, then the host shows the new position through tiles/video (no copy-rect) for seq 14.
        for _ in 0..<3 { seq += 1; x += 6; y += 3; now += 16_000_000; p.dragPointer(windowID: 7, pointer: (x, y), inputSeq: seq, now: now) }
        p.hostUpdate(inputSeq: 14, rect: frame.offset(60, 30).union(frame.offset(78, 39)), now: now)
        XCTAssertTrue(p.displacements().isEmpty, "a host picture reflecting seq 14 shows the window where the pointer was at 14")
        p.endDrag(windowID: 7)
        p.expire(now: now)
        XCTAssertFalse(p.hasPending)
    }

    func testDragMismatchHidesUntilResync() {
        var p = Predictor()
        let frame = PixelRect(x: 100, y: 100, width: 400, height: 300)
        p.beginDrag(windowID: 7, frame: frame, pointer: (300, 110), inputSeq: 1, now: 0)
        for i in 2...6 { p.dragPointer(windowID: 7, pointer: (300 + 6 * (i - 1), 110), inputSeq: UInt64(i), now: UInt64(i) * 16_000_000) }
        // The host moved the window the other way (a snap): mismatch, displacement hidden, re-synced to the host.
        p.hostCopyRect(windowID: 7, rect: frame, dx: -40, dy: 0, inputSeq: 6, now: 100_000_000)
        XCTAssertEqual(p.stats.mismatched, 1)
        XCTAssertTrue(p.displacements().isEmpty)
        XCTAssertFalse(p.isConfident(7))
        XCTAssertEqual(p.dragResidual(windowID: 7).map { $0.dx } ?? -1, 0)
    }
}

