import XCTest
import Metal
@testable import MirageCore

final class CompositorTests: XCTestCase {
    /// Reads the canvas back as BGRA bytes.
    private func readback(_ c: Compositor) throws -> [UInt8] {
        let tex = c.canvas!
        let stride = tex.width * 4
        let buf = c.device.makeBuffer(length: stride * tex.height, options: .storageModeShared)!
        let cb = c.commandQueue.makeCommandBuffer()!   // same queue as the compositor: ordered after its work
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * tex.height)
        blit.endEncoding(); try cb.commitAndWaitBounded()
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
        var px = try readback(c)
        XCTAssertEqual(pixel(px, 256, 70, 10).2, 255, "red at the tile's left half")
        XCTAssertEqual(pixel(px, 256, 120, 10).0, 255, "blue at the tile's right half")
        XCTAssertEqual(pixel(px, 256, 10, 10).2, 20, "untouched canvas stays dark (clear colour)")
        // Scroll the tile down by 40 px: the copy must survive the overlap.
        c.applyCopyRect(PixelRect(x: 64, y: 0, width: 64, height: 64), dx: 0, dy: 40)
        px = try readback(c)
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
        let px = try readback(c)
        XCTAssertGreaterThan(pixel(px, 128, 100, 100).1, 240, "masked tile is white")
        XCTAssertLessThan(pixel(px, 128, 10, 10).1, 40, "unmasked tile untouched")
    }

    /// Video over a tile with an alpha mask takes the mask's alpha and keeps its colour under it (premultiplied); a tile
    /// whose mask went back to opaque is a plain blit again.
    func testVideoTakesTheAlphaMask() throws {
        guard let c = Compositor() else { throw XCTSkip("no Metal device") }
        c.configure(width: 128, height: 64)
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
        XCTAssertEqual(CVPixelBufferCreate(nil, 128, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb), kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(pb!, 0), 235, CVPixelBufferGetBytesPerRowOfPlane(pb!, 0) * 64)
        memset(CVPixelBufferGetBaseAddressOfPlane(pb!, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(pb!, 1) * 32)
        CVPixelBufferUnlockBaseAddress(pb!, [])
        // Left tile: alpha 128 on its left half, 255 on its right; right tile: fully clear.
        var plane = [UInt8](repeating: 255, count: 64 * 64)
        for y in 0..<64 { for x in 0..<32 { plane[y * 64 + x] = 128 } }
        c.applyAlphaMask([(PixelRect(x: 0, y: 0, width: 64, height: 64), .plane, plane), (PixelRect(x: 64, y: 0, width: 64, height: 64), .clear, nil)])
        XCTAssertEqual(c.alphaTileCount, 2)
        c.applyVideo(pb!, region: PixelRect(x: 0, y: 0, width: 128, height: 64), mask: nil)
        var px = try readback(c)
        let a = { (x: Int, y: Int) in px[(y * 128 + x) * 4 + 3] }
        XCTAssertEqual(Int(a(10, 10)), 128, accuracy: 1); XCTAssertLessThanOrEqual(Int(pixel(px, 128, 10, 10).1), 129, "colour kept under the alpha")
        XCTAssertEqual(a(50, 10), 255); XCTAssertGreaterThan(pixel(px, 128, 50, 10).1, 240)
        XCTAssertEqual(a(100, 10), 0); XCTAssertEqual(pixel(px, 128, 100, 10).1, 0, "clear: nothing")
        c.applyAlphaMask([(PixelRect(x: 64, y: 0, width: 64, height: 64), .opaque, nil)])
        c.applyVideo(pb!, region: PixelRect(x: 0, y: 0, width: 128, height: 64), mask: nil)
        px = try readback(c)
        XCTAssertEqual(px[(10 * 128 + 100) * 4 + 3], 255, "opaque again: a plain blit")
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
        XCTAssertEqual(pixel(try readback(c), 128, 10, 10).2, 255, "the faded-in tile is on the canvas")
    }

    private func solid(_ x: Int, _ y: Int, _ bgra: [UInt8], w: Int = 64, h: Int = 64) -> TileMessage.Tile {
        .init(rect: PixelRect(x: x, y: y, width: w, height: h), format: .solid, data: Data(bgra))
    }

    /// DESIGN §3.3: a staged level is invisible until its commit, then fades in whole; a direct change that lands on a
    /// staged tile meanwhile is what the commit shows there (never the older staged pixels).
    func testStagedLevelAppearsOnlyOnCommit() throws {
        guard let c = Compositor() else { throw XCTSkip("no Metal device") }
        c.configure(width: 192, height: 64)
        let red: [UInt8] = [0, 0, 255, 255], green: [UInt8] = [0, 255, 0, 255], blue: [UInt8] = [255, 0, 0, 255]
        c.applyTiles([solid(0, 0, red), solid(64, 0, red), solid(128, 0, red)])
        c.applyTiles([solid(0, 0, green), solid(64, 0, green)], staged: true)
        XCTAssertEqual(c.stagedTiles, 2)
        var px = try readback(c)
        XCTAssertEqual(pixel(px, 192, 10, 10).2, 255, "staged pixels are not shown")
        // A direct change on the second staged tile: shown now, and it is what the commit keeps there.
        c.applyTiles([solid(64, 0, blue)])
        px = try readback(c)
        XCTAssertEqual(pixel(px, 192, 70, 10).0, 255, "direct change shown at once")
        XCTAssertEqual(pixel(px, 192, 10, 10).2, 255)
        XCTAssertGreaterThan(c.commitStaged(durationNanos: 1_000_000), 0)
        usleep(5_000); c.settle()
        px = try readback(c)
        XCTAssertEqual(pixel(px, 192, 10, 10).1, 255, "staged tile presented")
        XCTAssertEqual(pixel(px, 192, 70, 10).0, 255, "the newer direct change survives the commit")
        XCTAssertEqual(pixel(px, 192, 140, 10).2, 255, "untouched tile unchanged")
        XCTAssertEqual(c.stagedTiles, 0)
    }

    /// A commit while a fade runs waits for it (a level never jumps mid-fade), then lands on its own.
    func testCommitWaitsForRunningFade() throws {
        guard let c = Compositor() else { throw XCTSkip("no Metal device") }
        c.configure(width: 128, height: 64)
        c.crossfadeNanos = 30_000_000
        c.applyTiles([solid(0, 0, [0, 0, 255, 255], w: 128)], crossfade: true)
        c.applyTiles([solid(0, 0, [0, 255, 0, 255])], staged: true)
        XCTAssertEqual(c.commitStaged(durationNanos: 1_000_000), 0, "deferred behind the running fade")
        XCTAssertTrue(c.hasStaged)
        usleep(40_000); c.settle()   // the fade ends and the deferred commit starts
        usleep(5_000); c.settle()
        let px = try readback(c)
        XCTAssertEqual(pixel(px, 128, 10, 10).1, 255, "staged level presented after the fade")
        XCTAssertEqual(pixel(px, 128, 100, 10).2, 255, "the faded level is on the canvas")
        XCTAssertFalse(c.hasStaged)
    }

    /// Staged tiles move with a copy-rect (a scroll during assembly) and are presented where they landed.
    func testStagedTilesMoveWithCopyRect() throws {
        guard let c = Compositor() else { throw XCTSkip("no Metal device") }
        c.configure(width: 64, height: 192)
        c.applyTiles([solid(0, 0, [0, 0, 255, 255])])
        c.applyTiles([solid(0, 0, [0, 255, 0, 255])], staged: true)
        c.applyCopyRect(PixelRect(x: 0, y: 0, width: 64, height: 64), dx: 0, dy: 128)
        var px = try readback(c)
        XCTAssertEqual(pixel(px, 64, 10, 140).2, 255, "the canvas moved its own (red) pixels")
        c.commitStaged(durationNanos: 1_000_000); usleep(5_000); c.settle()
        px = try readback(c)
        XCTAssertEqual(pixel(px, 64, 10, 140).1, 255, "the staged (green) tile is presented where it moved")
    }

    func testRunsMergeRowsWithTheSameSpan() {
        // 4×3 tiles: rows 0 and 1 have tiles 1–2, row 2 has tile 0 only.
        var m = [Bool](repeating: false, count: 12)
        m[1] = true; m[2] = true; m[5] = true; m[6] = true; m[8] = true
        let r = Compositor.runs(m, cols: 4, rows: 3, width: 250, height: 150)
        XCTAssertEqual(Set(r.map { "\($0)" }), Set(["\(PixelRect(x: 64, y: 0, width: 128, height: 128))", "\(PixelRect(x: 0, y: 128, width: 64, height: 22))"]))
    }
}
