import XCTest
@testable import MirageCore

final class SpriteShiftTests: XCTestCase {
    /// A 192-px textured icon over transparency, 40 px higher in the new frame (a Dock bounce).
    func frames(iconOld: Int, iconNew: Int, w: Int = 320, h: Int = 640) -> ([UInt8], [UInt8]) {
        var a = [UInt8](repeating: 0, count: w * h * 4), b = a
        func icon(_ p: inout [UInt8], _ top: Int) {
            for y in 0..<192 { for x in 0..<192 { let o = ((top + y) * w + 64 + x) * 4; p[o] = UInt8((x * 7 + y * 3) & 255); p[o + 1] = UInt8((x ^ y) & 255); p[o + 2] = UInt8(y & 255); p[o + 3] = 255 } }
        }
        icon(&a, iconOld); icon(&b, iconNew)
        return (a, b)
    }
    func testBounceIsOneCopyAndTheUncoveredStrip() {
        let w = 320, h = 640
        var (a, b) = frames(iconOld: 400, iconNew: 360)
        a.withUnsafeBytes { pa in b.withUnsafeMutableBytes { pb in
            let old = ShiftDetector.Frame(base: pa.baseAddress!, stride: w * 4, width: w, height: h), new = ShiftDetector.Frame(base: pb.baseAddress!, stride: w * 4, width: w, height: h)
            let r = SpriteShift.detect(old: old, new: new, region: PixelRect(x: 0, y: 320, width: 320, height: 320))
            XCTAssertEqual(r?.dy, -40)
            // Over transparency the copy of the whole column band is the whole update.
            XCTAssertEqual(r?.residual, [])
        } }
    }
    /// The icon over a static textured bar (the Dock's glass) at its bottom: the copy carries the bar along, so its rows are
    /// the residual, and only they.
    func testBounceOverABarLeavesTheBarRows() {
        let w = 320, h = 640
        var (a, b) = frames(iconOld: 400, iconNew: 360)
        for p in [0, 1] { for y in 560..<640 { for x in 0..<w where !(p == 0 && y < 592 && x >= 64 && x < 256) && !(p == 1 && y < 552 && x >= 64 && x < 256) {
            let o = (y * w + x) * 4; let v = UInt8((x * 5 + y * 11) & 255)
            if p == 0 { a[o] = v; a[o + 1] = 90; a[o + 2] = 120; a[o + 3] = 200 } else { b[o] = v; b[o + 1] = 90; b[o + 2] = 120; b[o + 3] = 200 }
        } } }
        a.withUnsafeBytes { pa in b.withUnsafeBytes { pb in
            let old = ShiftDetector.Frame(base: pa.baseAddress!, stride: w * 4, width: w, height: h), new = ShiftDetector.Frame(base: pb.baseAddress!, stride: w * 4, width: w, height: h)
            let r = SpriteShift.detect(old: old, new: new, region: PixelRect(x: 0, y: 320, width: 320, height: 320))
            XCTAssertEqual(r?.dy, -40)
            let res = r?.residual ?? []
            XCTAssertFalse(res.isEmpty)
            XCTAssertTrue(res.allSatisfy { $0.y >= 512 && $0.maxY <= 608 }, "\(res)")
        } }
    }
    func testNoTranslationNoShift() {
        let w = 320, h = 640
        var a = [UInt8](repeating: 0, count: w * h * 4), b = a
        var s: UInt32 = 1
        for i in 0..<(w * h * 4) { s = s &* 1664525 &+ 1013904223; a[i] = UInt8(s >> 24); s = s &* 1664525 &+ 1013904223; b[i] = UInt8(s >> 24) }
        a.withUnsafeBytes { pa in b.withUnsafeBytes { pb in
            let old = ShiftDetector.Frame(base: pa.baseAddress!, stride: w * 4, width: w, height: h), new = ShiftDetector.Frame(base: pb.baseAddress!, stride: w * 4, width: w, height: h)
            XCTAssertNil(SpriteShift.detect(old: old, new: new, region: PixelRect(x: 0, y: 0, width: 320, height: 640)))
        } }
    }
}
