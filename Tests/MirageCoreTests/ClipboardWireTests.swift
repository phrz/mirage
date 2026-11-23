import XCTest
@testable import MirageCore

/// The shared clipboard's messages: they round-trip, never print their contents, and a clipboard too large for one
/// control frame is not sent (Frame.encode would trap on it).
final class ClipboardWireTests: XCTestCase {
    func testRoundTripAndQuietDescription() throws {
        let c = ControlMessage.Clipboard(id: 7, text: "secret text", png: Data([1, 2, 3]))
        let d = try JSONEncoder().encode(ControlMessage.clipboard(c))
        XCTAssertEqual(try JSONDecoder().decode(ControlMessage.self, from: d), .clipboard(c))
        XCTAssertFalse("\(c)".contains("secret"))
        XCTAssertEqual(try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(ControlMessage.clipboardApplied(.init(id: 7)))), .clipboardApplied(.init(id: 7)))
    }

    func testOnlyWhatFitsOneFrameIsShared() {
        XCTAssertTrue(ControlMessage.Clipboard(text: String(repeating: "a", count: 100_000), png: nil).fitsOneFrame)
        XCTAssertFalse(ControlMessage.Clipboard(text: String(repeating: "a", count: Frame.maxLength), png: nil).fitsOneFrame)
        // JSON escapes control characters six to one: the encoded size decides, not the text's.
        XCTAssertFalse(ControlMessage.Clipboard(text: String(repeating: "\u{1}", count: 300_000), png: nil).fitsOneFrame)
        XCTAssertFalse(ControlMessage.Clipboard(text: nil, png: Data(count: 700_000)).fitsOneFrame)
        XCTAssertTrue(ControlMessage.Clipboard(text: nil, png: nil).isEmpty)
    }
}
