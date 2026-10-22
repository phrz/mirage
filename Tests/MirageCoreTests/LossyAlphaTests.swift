import XCTest
@testable import MirageCore

final class LossyAlphaTests: XCTestCase {
    /// A translucent grey (premultiplied BGRA), through the lossy still path and back: how far each channel moves.
    func testLossyStillKeepsPremultipliedTranslucency() {
        for (grey, a) in [(200, 128), (200, 200), (60, 128), (240, 230)] as [(Int, Int)] {
            let w = 64, h = 64
            let p = UInt8(grey * a / 255)
            var px = [UInt8](repeating: 0, count: w * h * 4)
            for i in stride(from: 0, to: px.count, by: 4) { px[i] = p; px[i + 1] = p; px[i + 2] = p; px[i + 3] = UInt8(a) }
            for (ow, oh) in [(64, 64), (16, 16)] {
                let d = px.withUnsafeBytes { TileCodec.encodeLossy(base: $0.baseAddress!, width: w, height: h, stride: w * 4, outWidth: ow, outHeight: oh, quality: 60, alpha: true) }!
                var out = [UInt8](repeating: 0, count: ow * oh * 4)
                XCTAssertTrue(out.withUnsafeMutableBytes { TileCodec.decode(d, into: $0.baseAddress!, width: ow, height: oh, stride: ow * 4) })
                let c = (ow * (oh / 2) + ow / 2) * 4
                // Premultiplied values survive (a translucent window's still is not darkened or lightened by the codec).
                for k in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(out[c + k]) - Int(p)), 2, "grey \(grey) alpha \(a) at \(ow)x\(oh)") }
                XCTAssertLessThanOrEqual(abs(Int(out[c + 3]) - a), 1)
            }
        }
    }
}
