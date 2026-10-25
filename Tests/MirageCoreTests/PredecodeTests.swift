import XCTest
import Metal
@testable import MirageCore

/// Crisp-first: tiles decoded off the video queue (Compositor.predecode) land exactly as decoding in applyTiles did.
final class PredecodeTests: XCTestCase {
    func testPredecodedTilesRenderTheSame() throws {
        guard let ctx = MetalContext() else { throw XCTSkip("no Metal device") }
        let w = 128, h = 64, stride = w * 4
        var px = [UInt8](repeating: 0, count: stride * h)
        for y in 0..<h { for x in 0..<w { let o = y * stride + x * 4; px[o] = UInt8(x * 2); px[o + 1] = UInt8(y * 4); px[o + 2] = UInt8((x ^ y) & 255); px[o + 3] = 255 } }
        let lossless = px.withUnsafeBytes { TileCodec.encode(base: $0.baseAddress!, width: w, height: h, stride: stride, format: .lossless)! }
        let still = px.withUnsafeBytes { TileCodec.encodeLossy(base: $0.baseAddress!, width: w, height: h, stride: stride, outWidth: w / 2, outHeight: h / 2, quality: 60)! }
        let tiles: [TileMessage.Tile] = [
            .init(rect: PixelRect(x: 0, y: 0, width: w, height: h), format: .lossless, data: lossless),
            .init(rect: PixelRect(x: 0, y: 64, width: w, height: h), format: .lossy, data: still),
            .init(rect: PixelRect(x: 128, y: 0, width: 64, height: 64), format: .solid, data: Data([10, 200, 30, 255])),
        ]
        func render(_ c: Compositor) -> [UInt8] {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 256, height: 128, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            let t = ctx.device.makeTexture(descriptor: d)!
            SceneRenderer.render(LayerScene(background: c, items: [], displacements: [], bandColors: [:]), context: ctx, target: t, dest: CGRect(x: 0, y: 0, width: 256, height: 128))
            let cb = ctx.commandQueue.makeCommandBuffer()!; try? cb.commitAndWaitBounded()
            var out = [UInt8](repeating: 0, count: 256 * 128 * 4)
            t.getBytes(&out, bytesPerRow: 256 * 4, from: MTLRegionMake2D(0, 0, 256, 128), mipmapLevel: 0)
            return out
        }
        let a = Compositor(context: ctx); a.configure(width: 256, height: 128)
        XCTAssertEqual(a.applyTiles(tiles), 3)
        let b = Compositor(context: ctx); b.configure(width: 256, height: 128)
        let decoded = Compositor.predecode(tiles, device: ctx.device, alpha: false)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(b.applyTiles(tiles, decoded: decoded), 3)
        XCTAssertEqual(render(a), render(b))
        // A tile that failed to decode ahead is skipped, as a failed decode in applyTiles is.
        let c = Compositor(context: ctx); c.configure(width: 256, height: 128)
        XCTAssertEqual(c.applyTiles(tiles, decoded: decoded.filter { $0.key.y == 0 && $0.key.x == 0 }), 1)
    }
}
