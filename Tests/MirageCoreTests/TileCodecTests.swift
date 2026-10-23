import XCTest
@testable import MirageCore

final class TileCodecTests: XCTestCase {
    /// A synthetic "text" tile: white background, black 1-px glyph strokes, 64×64 BGRA.
    private func textTile(width: Int = 64, height: Int = 64, stride rowBytes: Int? = nil) -> [UInt8] {
        let stride = rowBytes ?? width * 4
        var px = [UInt8](repeating: 0xFF, count: stride * height)
        var rng: UInt32 = 12345
        for y in Swift.stride(from: 4, to: height - 4, by: 10) {
            for x in 2..<(width - 2) {
                rng = rng &* 1103515245 &+ 12345
                if (rng >> 16) & 3 != 0 { let o = y * stride + x * 4; px[o] = 0; px[o+1] = 0; px[o+2] = 0 }
                if (rng >> 18) & 1 == 0 { let o = (y + 1) * stride + x * 4; px[o] = 0x20; px[o+1] = 0x20; px[o+2] = 0x20 }
            }
        }
        return px
    }

    func testLosslessRoundTripIsExact() {
        let w = 64, h = 64, stride = 300 * 4   // stride larger than the rect, as inside a frame
        let px = textTile(width: w, height: h, stride: stride)
        let data = px.withUnsafeBytes { TileCodec.encode(base: $0.baseAddress!, width: w, height: h, stride: stride, format: .lossless) }
        XCTAssertNotNil(data)
        guard let data else { return }
        XCTAssertLessThan(data.count, 1500, "a text tile should be well under 1.5 KB, got \(data.count)")
        XCTAssertEqual(TileCodec.size(of: data)?.width, w)
        var out = [UInt8](repeating: 0, count: w * 4 * h)
        XCTAssertTrue(out.withUnsafeMutableBytes { TileCodec.decode(data, into: $0.baseAddress!, width: w, height: h, stride: w * 4) })
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            XCTAssertEqual(out[y * w * 4 + x * 4 + c], px[y * stride + x * 4 + c], "pixel \(x),\(y) channel \(c)")
        } } }
    }

    func testUniformTileIsTiny() {
        let w = 128, h = 64
        let px = [UInt8](repeating: 0x80, count: w * h * 4)
        let data = px.withUnsafeBytes { TileCodec.encode(base: $0.baseAddress!, width: w, height: h, stride: w * 4, format: .lossless) }!
        XCTAssertLessThan(data.count, 120)
    }

    func testNearLosslessDecodes() {
        let w = 64, h = 64
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { px[i * 4] = UInt8(i & 0xff); px[i * 4 + 1] = UInt8((i >> 3) & 0xff); px[i * 4 + 2] = UInt8((i >> 6) & 0xff); px[i * 4 + 3] = 0xff }
        let colours = px.withUnsafeBytes { TileCodec.colourCount(base: $0.baseAddress!, width: w, height: h, stride: w * 4) }
        XCTAssertGreaterThan(colours, 256)
        let data = px.withUnsafeBytes { TileCodec.encode(base: $0.baseAddress!, width: w, height: h, stride: w * 4, format: .nearLossless) }!
        var out = [UInt8](repeating: 0, count: w * h * 4)
        XCTAssertTrue(out.withUnsafeMutableBytes { TileCodec.decode(data, into: $0.baseAddress!, width: w, height: h, stride: w * 4) })
        var maxErr = 0
        for i in 0..<(w * h * 4) where i % 4 != 3 { maxErr = max(maxErr, abs(Int(out[i]) - Int(px[i]))) }
        XCTAssertLessThanOrEqual(maxErr, 16)
    }
}

final class SolidTileTests: XCTestCase {
    func testSolidDetectionAndFill() {
        var px = [UInt8](repeating: 0x40, count: 64 * 64 * 4)
        let solid = px.withUnsafeBytes { TileCodec.solidColour(base: $0.baseAddress!, width: 64, height: 64, stride: 256) }
        XCTAssertEqual(solid?.count, 4)
        px[1000] = 0x41
        XCTAssertNil(px.withUnsafeBytes { TileCodec.solidColour(base: $0.baseAddress!, width: 64, height: 64, stride: 256) })
        var out = [UInt8](repeating: 0, count: 16 * 4 * 8)
        XCTAssertTrue(out.withUnsafeMutableBytes { TileCodec.fillSolid(solid!, into: $0.baseAddress!, width: 16, height: 8, stride: 64) })
        XCTAssertEqual(out[0], 0x40); XCTAssertEqual(out[out.count - 2], 0x40); XCTAssertEqual(out[3], 0xFF)
        // The wire carries the format byte 2.
        let m = TileMessage.tiles(.init(header: .init(captureSeq: 1, inputSeq: 1, windowID: 0, captureNanos: 1), refinement: false, tiles: [.init(rect: PixelRect(x: 0, y: 0, width: 64, height: 64), format: .solid, data: solid!)]))
        var p = TileStreamParser()
        let got = try! p.feed(m.encode(msgSeq: 1))
        XCTAssertEqual(got.first?.message, m)
    }
}

/// A translucent tile (the glass menu bar's text over clear) must reach the viewer exact: composited at 50 % alpha over a
/// known backdrop, the decoded tile gives the source's result to within 1 level (check 5, 2026-10-23: near-lossless lost
/// 10-20 % of the bar's edge energy).
final class TranslucentTileTests: XCTestCase {
    func testHalfAlphaPhotographicTileCompositesExactly() {
        let w = 128, h = 64   // (more pixels than the 4096-colour bar)
        var src = [UInt8](repeating: 0, count: w * h * 4)
        var s: UInt32 = 9
        for i in 0..<(w * h) {
            s = s &* 1664525 &+ 1013904223
            let a: UInt8 = 128
            // Premultiplied, many colours (photographic: > 4096), "text" strokes every 5th column.
            let stroke = (i % w) % 5 == 0
            src[i * 4] = stroke ? 120 : UInt8(s >> 25); src[i * 4 + 1] = stroke ? 124 : UInt8((s >> 17) & 127); src[i * 4 + 2] = stroke ? 118 : UInt8((s >> 9) & 127); src[i * 4 + 3] = a
        }
        let photographic = src.withUnsafeBytes { TileCodec.colourCount(base: $0.baseAddress!, width: w, height: h, stride: w * 4, limit: 4096) > 4096 }
        XCTAssertTrue(photographic)
        let translucent = src.withUnsafeBytes { TileCodec.translucent(base: $0.baseAddress!, width: w, height: h, stride: w * 4) }
        XCTAssertTrue(translucent)
        let fmt = TileCodec.finalFormat(photographic: photographic, translucent: translucent)
        XCTAssertEqual(fmt, .lossless)
        guard let data = src.withUnsafeBytes({ TileCodec.encode(base: $0.baseAddress!, width: w, height: h, stride: w * 4, format: fmt, alpha: true) }) else { return XCTFail("encode") }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        XCTAssertTrue(out.withUnsafeMutableBytes { TileCodec.decode(data, into: $0.baseAddress!, width: w, height: h, stride: w * 4) })
        // Premultiplied "over" onto a backdrop, as the viewer's blend pipeline does (one, one-minus-source-alpha).
        func over(_ p: [UInt8], _ i: Int, _ bg: Int) -> Int { Int(p[i]) + bg * (255 - Int(p[i - i % 4 + 3])) / 255 }
        var worst = 0
        for i in 0..<(w * h * 4) where i % 4 != 3 { let bg = (i * 37) % 256; worst = max(worst, abs(over(out, i, bg) - over(src, i, bg))) }
        XCTAssertLessThanOrEqual(worst, 1)
        // And near-lossless would not be: the reason for the rule.
        if let nl = src.withUnsafeBytes({ TileCodec.encode(base: $0.baseAddress!, width: w, height: h, stride: w * 4, format: .nearLossless, alpha: true) }) {
            var o2 = [UInt8](repeating: 0, count: w * h * 4)
            _ = o2.withUnsafeMutableBytes { TileCodec.decode(nl, into: $0.baseAddress!, width: w, height: h, stride: w * 4) }
            var worstNL = 0
            for i in 0..<(w * h * 4) where i % 4 != 3 { let bg = (i * 37) % 256; worstNL = max(worstNL, abs(over(o2, i, bg) - over(src, i, bg))) }
            print("near-lossless worst error at 50 % alpha: \(worstNL)")
        }
    }
}
