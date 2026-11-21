import XCTest
@testable import MirageCore

/// Dynamic Resolution's request field: carried whole, and absent for viewers that do not ask (older hosts never see it).
final class FitDisplayWireTests: XCTestCase {
    func testAFitRoundTripsAndIsLeftOutWhenNotAsked() throws {
        var req = ControlMessage.StreamRequest(width: 2880, height: 1800)
        req.fitDisplay = .init(width: 1440, height: 900, scale: 2)
        let framed = try Frame.encode(ControlMessage.streamRequest(req))
        XCTAssertEqual(try Frame.decode(ControlMessage.self, from: framed.dropFirst(4)), .streamRequest(req))

        let plain = try XCTUnwrap(String(data: try JSONEncoder().encode(ControlMessage.StreamRequest(width: 1, height: 1)), encoding: .utf8))
        XCTAssertFalse(plain.contains("fitDisplay"))
        let old = try JSONDecoder().decode(ControlMessage.StreamRequest.self, from: Data(#"{"width":100,"height":50,"bitrateKbps":0,"maxFPS":30}"#.utf8))
        XCTAssertNil(old.fitDisplay)
    }
}
