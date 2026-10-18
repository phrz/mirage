import XCTest
import Metal
@testable import MirageCore

final class CompositorTests: XCTestCase {
    /// Reads the canvas back as BGRA bytes.
    private func readback(_ c: Compositor) -> [UInt8] {
        let tex = c.canvas!
        let stride = tex.width * 4
        let buf = c.device.makeBuffer(length: stride * tex.height, options: .storageModeShared)!
        let cb = c.commandQueue.makeCommandBuffer()!   // same queue as the compositor: ordered after its work
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * tex.height)
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: UInt8.self), count: stride * tex.height))
    }
    private func pixel(_ px: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) { let o = (y * w + x) * 4; return (px[o], px[o+1], px[o+2]) }

    func testTilesLandAndCopyRectMoves() throws {
        guard let c = Compositor() else { throw XCTSkip("no Metal device") }
        c.configure(width: 256, height: 128)
        // A 64×64 tile: red left half, blue right half (BGRA).
        var tile = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for y in 0..<64 { for x in 0..<64 { let o = (y * 64 + x) * 4; if x < 32 { tile[o+2] = 255 } else { tile[o] = 255 }; tile[o+3] = 255 } }
        let data = tile.withUnsafeBytes { TileCodec.encode(base: $0.baseAddress!, width: 64, height: 64, stride: 256, format: .lossless)! }
        XCTAssertEqual(c.applyTiles([.init(rect: PixelRect(x: 64, y: 0, width: 64, height: 64), format: .lossless, data: data)]), 1)
        var px = readback(c)
        XCTAssertEqual(pixel(px, 256, 70, 10).2, 255, "red at the tile's left half")
        XCTAssertEqual(pixel(px, 256, 120, 10).0, 255, "blue at the tile's right half")
        XCTAssertEqual(pixel(px, 256, 10, 10).2, 20, "untouched canvas stays dark (clear colour)")
        // Scroll the tile down by 40 px: the copy must survive the overlap.
        c.applyCopyRect(PixelRect(x: 64, y: 0, width: 64, height: 64), dx: 0, dy: 40)
        px = readback(c)
        XCTAssertEqual(pixel(px, 256, 70, 50).2, 255)
        XCTAssertEqual(pixel(px, 256, 120, 100).0, 255)
        XCTAssertEqual(pixel(px, 256, 70, 10).2, 255, "source rows outside the destination keep their pixels")
    }

    func testVideoMaskOnlyTouchesMaskedTiles() throws {
        guard let c = Compositor() else { throw XCTSkip("no Metal device") }
        c.configure(width: 128, height: 128)
        // NV12 frame: Y = 235 (white, video range), neutral chroma.
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
        XCTAssertEqual(CVPixelBufferCreate(nil, 128, 128, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb), kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(pb!, 0), 235, CVPixelBufferGetBytesPerRowOfPlane(pb!, 0) * 128)
        memset(CVPixelBufferGetBaseAddressOfPlane(pb!, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(pb!, 1) * 64)
        CVPixelBufferUnlockBaseAddress(pb!, [])
        var mask = TileMask(cols: 2, rows: 2)
        mask[1, 1] = true
        c.applyVideo(pb!, region: PixelRect(x: 0, y: 0, width: 128, height: 128), mask: mask)
        let px = readback(c)
        XCTAssertGreaterThan(pixel(px, 128, 100, 100).1, 240, "masked tile is white")
        XCTAssertLessThan(pixel(px, 128, 10, 10).1, 40, "unmasked tile untouched")
    }

    /// Review T6/M1: a crossfaded refinement tile reaches the canvas without any render once its fade is over.
    func testCrossfadeSettlesWithoutRendering() throws {
        guard let c = Compositor() else { throw XCTSkip("no Metal device") }
        c.configure(width: 128, height: 64)
        c.crossfadeNanos = 1_000_000
        c.applyTiles([.init(rect: PixelRect(x: 0, y: 0, width: 64, height: 64), format: .solid, data: Data([0, 0, 255, 255]))], crossfade: true)
        XCTAssertTrue(c.hasActiveFades)
        usleep(5_000)
        c.settle()
        XCTAssertFalse(c.hasActiveFades)
        XCTAssertEqual(pixel(readback(c), 128, 10, 10).2, 255, "the faded-in tile is on the canvas")
    }
}
