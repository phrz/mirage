import XCTest
import Metal
@testable import MirageCore

/// A native stream drawn at fit on a phone is minified ~2.5×: one bilinear tap per pixel skips source texels, so 1-px
/// text strokes come and go as the picture moves (shimmer). The scene renderer averages each pixel's footprint instead,
/// and is the exact single tap it always was at 1:1.
final class AreaFilterTests: XCTestCase {
    /// A canvas of 1-px black and white columns (the worst case: every column a stroke).
    private func stripes(width: Int = 640, height: Int = 64) throws -> Compositor {
        guard let c = Compositor() else { throw XCTSkip("no Metal device") }
        c.configure(width: width, height: height)
        var tile = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0..<64 { for x in 0..<64 where x % 2 == 0 { let o = (y * 64 + x) * 4; tile[o] = 0; tile[o+1] = 0; tile[o+2] = 0 } }
        let data = tile.withUnsafeBytes { TileCodec.encode(base: $0.baseAddress!, width: 64, height: 64, stride: 256, format: .lossless)! }
        var tiles: [TileMessage.Tile] = []
        for tx in stride(from: 0, to: width, by: 64) { tiles.append(.init(rect: PixelRect(x: tx, y: 0, width: 64, height: 64), format: .lossless, data: data)) }
        XCTAssertEqual(c.applyTiles(tiles), tiles.count)
        return c
    }

    private func render(_ c: Compositor, width: Int, height: Int, dest: CGRect) -> [UInt8] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let target = c.device.makeTexture(descriptor: d)!
        SceneRenderer.render(LayerScene(background: c, items: [], displacements: [], bandColors: [:]), context: c.context, target: target, dest: dest)
        let cb = c.context.commandQueue.makeCommandBuffer()!; cb.commit(); cb.waitUntilCompleted()   // after the render on the same queue
        var px = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&px, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return px
    }

    func testMinifiedStripesAreEvenGreyAtEveryOffset() throws {
        let c = try stripes()
        // 640 → 256 px (0.4×, a 3024-px stream at a phone's fit), at several sub-pixel pan offsets.
        var worst = 0
        for offset in [0.0, 0.25, 0.5, 0.75] {
            let px = render(c, width: 300, height: 32, dest: CGRect(x: offset, y: 0, width: 256, height: 25.6))
            let row = (4..<250).map { Int(px[(10 * 300 + $0) * 4 + 1]) }
            worst = max(worst, row.max()! - row.min()!)
            XCTAssertEqual(Double(row.reduce(0, +)) / Double(row.count), 127.5, accuracy: 20, "the average of the strokes")
        }
        XCTAssertLessThan(worst, 64, "no column of strokes stands out (a single bilinear tap swings from black to white here)")
    }

    func testOneToOneIsExact() throws {
        let c = try stripes(width: 128)
        let px = render(c, width: 128, height: 64, dest: CGRect(x: 0, y: 0, width: 128, height: 64))
        for x in 0..<128 { XCTAssertEqual(px[(5 * 128 + x) * 4 + 1], x % 2 == 0 ? 0 : 255) }
    }
}
