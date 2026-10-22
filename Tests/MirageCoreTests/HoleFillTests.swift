import XCTest
@testable import MirageCore

final class HoleFillTests: XCTestCase {
    /// A window cut out of a desktop is filled from the desktop around it, never left as the window.
    func testAHoleIsFilledFromItsSurroundings() {
        let w = 64, h = 48
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { px[i * 4] = 200; px[i * 4 + 1] = 40; px[i * 4 + 2] = 30; px[i * 4 + 3] = 255 }      // blue desktop (BGRA)
        let hole = PixelRect(x: 20, y: 10, width: 24, height: 20)
        for y in hole.y..<hole.maxY { for x in hole.x..<hole.maxX { let o = (y * w + x) * 4; px[o] = 0; px[o + 1] = 0; px[o + 2] = 255 } }   // red window
        HoleFill.fill(&px, width: w, height: h, holes: [hole])
        let c = ((hole.y + 10) * w + hole.x + 12) * 4
        XCTAssertEqual(Int(px[c]), 200, accuracy: 3, "blue from around it")
        XCTAssertEqual(Int(px[c + 2]), 30, accuracy: 3, "no red left")
        XCTAssertEqual(px[c + 3], 255)
        XCTAssertEqual(px[0], 200, "known pixels untouched")
    }
}
