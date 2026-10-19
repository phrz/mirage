import XCTest
@testable import MirageCore

final class TypeaheadTests: XCTestCase {
    private func caret(x: Int, seq: UInt64, field: PixelRect = PixelRect(x: 0, y: 0, width: 1000, height: 200), selection: Bool = false) -> ControlMessage.CaretInfo {
        .init(caret: PixelRect(x: x, y: 100, width: 0, height: 30), field: field, pid: 1, font: "Menlo-Regular", size: 14, color: nil, selection: selection, secure: false, inputSeq: seq)
    }

    func testPredictConfirmLand() {
        var t = Typeahead()
        t.host(caret(x: 200, seq: 0), now: 0)
        let a = t.typed("a", advancePx: 17, seq: 1, now: 1)
        let b = t.typed("b", advancePx: 17, seq: 2, now: 2)
        XCTAssertEqual(a?.rect, PixelRect(x: 200, y: 100, width: 17, height: 30))
        XCTAssertEqual(b?.rect.x, 217)
        // The host applied the first key: caret at 217.
        t.host(caret(x: 217, seq: 1), now: 3)
        XCTAssertEqual(t.glyphs.map(\.confirmed), [true, false])
        t.host(caret(x: 234, seq: 2), now: 4)
        XCTAssertEqual(t.confirmed, 2); XCTAssertEqual(t.mismatched, 0)
        // Its pixels landed over the first glyph: only the second is still drawn here.
        t.pixels(inputSeq: 1, rect: PixelRect(x: 192, y: 96, width: 64, height: 64))
        XCTAssertEqual(t.glyphs.map(\.text), ["b"])
    }

    func testMismatchErasesAndBacksOffUntilThreeSilentConfirmations() {
        var t = Typeahead()
        t.host(caret(x: 200, seq: 0), now: 0)
        t.typed("a", advancePx: 17, seq: 1, now: 1)
        t.host(caret(x: 260, seq: 1), now: 2)            // autocomplete: the caret went far
        XCTAssertTrue(t.glyphs.isEmpty); XCTAssertFalse(t.isTrusted); XCTAssertEqual(t.mismatched, 1)
        XCTAssertNil(t.typed("b", advancePx: 10, seq: 2, now: 3), "untrusted: tracked, not shown")
        t.host(caret(x: 270, seq: 2), now: 4)
        t.typed("c", advancePx: 10, seq: 3, now: 5); t.host(caret(x: 280, seq: 3), now: 6)
        t.typed("d", advancePx: 10, seq: 4, now: 7); t.host(caret(x: 290, seq: 4), now: 8)
        XCTAssertTrue(t.isTrusted)
        XCTAssertNotNil(t.typed("e", advancePx: 10, seq: 5, now: 9))
    }

    func testUnpredictableKeysSelectionsAndEdges() {
        var t = Typeahead()
        t.host(caret(x: 200, seq: 0), now: 0)
        t.typed("a", advancePx: 17, seq: 1, now: 1)
        t.invalidate(after: 2)                            // Return
        XCTAssertTrue(t.glyphs.isEmpty)
        XCTAssertNil(t.typed("b", advancePx: 17, seq: 3, now: 2), "waits for the host after Return")
        t.host(caret(x: 10, seq: 3), now: 3)
        XCTAssertNotNil(t.typed("c", advancePx: 17, seq: 4, now: 4))
        t.backspace(seq: 5)
        XCTAssertTrue(t.glyphs.isEmpty, "backspace takes the unconfirmed glyph back")
        t.host(caret(x: 10, seq: 5, selection: true), now: 5)
        XCTAssertNil(t.typed("d", advancePx: 17, seq: 6, now: 6), "a selection is replaced: no prediction")
        t.host(caret(x: 990, seq: 6), now: 7)
        XCTAssertNil(t.typed("e", advancePx: 17, seq: 7, now: 8), "past the field's edge the app wraps or scrolls")
        // Expiry.
        t.host(caret(x: 100, seq: 8), now: 9)
        t.typed("f", advancePx: 17, seq: 9, now: 10)
        t.expire(now: 10 + 3_000_000_000)
        XCTAssertTrue(t.glyphs.isEmpty); XCTAssertEqual(t.expired, 1)
    }
}
