import XCTest
@testable import MirageCore

/// M3 layered desktop: layer ids on the wire, window commands, the lossy still and alpha-exact tiles.
final class LayerWireTests: XCTestCase {
    func testResetCarriesTheLayerAndVideoFragmentsCarryTheLayer() throws {
        let reset = TileMessage.reset(layer: 4242, width: 800, height: 532)
        var p = TileStreamParser()
        let got = try p.feed(reset.encode(msgSeq: 9))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].message, reset)
        let frag = VideoFragment(frameSeq: 7, fragIndex: 0, fragCount: 1, flags: [.keyframe], captureNanos: 5, frameBytes: 3,
                                 captureSeq: 11, inputSeq: 12, region: PixelRect(x: 64, y: 0, width: 128, height: 64), layerID: 4242, payload: Data([1, 2, 3]))
        let d = frag.encode()
        XCTAssertEqual(d.count, VideoFragment.headerSize + 3)
        XCTAssertEqual(VideoFragment.decode(d), frag)
        // The assembler hands the layer on with the frame.
        var a = FrameAssembler()
        let ev = a.ingest(frag, now: 1)
        guard case .completed(let f)? = ev.first else { return XCTFail("expected a completed frame, got \(ev)") }
        XCTAssertEqual(f.layerID, 4242)
    }

    /// Desktop underlay tiles carry the window-free bit (flags bit 2); the refinement and staged bits are unchanged.
    func testWindowFreeTilesRoundTrip() throws {
        let h = TileMessage.Header(captureSeq: 5, inputSeq: 6, windowID: 0, captureNanos: 7)
        let tile = TileMessage.Tile(rect: PixelRect(x: 64, y: 128, width: 128, height: 64), format: .lossy, data: Data([9, 9, 9]))
        let under = TileMessage.tiles(.init(header: h, refinement: true, windowFree: true, tiles: [tile]))
        let plain = TileMessage.tiles(.init(header: h, refinement: true, staged: true, tiles: [tile]))
        var p = TileStreamParser()
        let got = try p.feed(under.encode(msgSeq: 1) + plain.encode(msgSeq: 2))
        XCTAssertEqual(got.map(\.message), [under, plain])
        if case .tiles(let t) = got[0].message { XCTAssertTrue(t.windowFree); XCTAssertTrue(t.refinement); XCTAssertFalse(t.staged) }
        if case .tiles(let t) = got[1].message { XCTAssertFalse(t.windowFree); XCTAssertTrue(t.staged) }
    }

    func testWindowListAndCommandRoundTrip() throws {
        let w = ControlMessage.WindowInfo(id: 1, pid: 2, title: "t", frame: PixelRect(x: -10, y: 20, width: 300, height: 200), z: 0, level: 0, layered: true, app: "Bench")
        let list = ControlMessage.WindowList(captureSeq: 3, windows: [w], inputSeq: 77)
        let decoded = try Frame.decode(ControlMessage.self, from: try Frame.encode(ControlMessage.windowList(list)).dropFirst(4))
        XCTAssertEqual(decoded, .windowList(list))
        if case .windowList(let l) = decoded { XCTAssertTrue(l.windows[0].isLayered); XCTAssertEqual(l.inputSeq, 77); XCTAssertEqual(l.windows[0].frame.x, -10, "frames may extend off the display") }
        let cmd = ControlMessage.windowCommand(.init(id: 1, action: .move, x: 40, y: 50, inputSeq: 78))
        XCTAssertEqual(try Frame.decode(ControlMessage.self, from: try Frame.encode(cmd).dropFirst(4)), cmd)
        // Old-style entries (no level/layered/app) still decode as display-layer windows.
        let old = try Frame.decode(ControlMessage.WindowInfo.self, from: Data(#"{"id":5,"pid":6,"title":"","frame":{"x":0,"y":0,"width":64,"height":64},"z":1}"#.utf8))
        XCTAssertFalse(old.isLayered); XCTAssertEqual(old.windowLevel, 0)
    }

    func testLossyStillDecodesAtItsOwnSizeAndAlphaStaysExact() {
        let w = 256, h = 128
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let o = (y * w + x) * 4
            let inside = x > 8 && y > 8 && x < w - 8 && y < h - 8
            px[o] = inside ? 200 : 0; px[o + 1] = inside ? 100 : 0; px[o + 2] = inside ? 50 : 0; px[o + 3] = inside ? 255 : 0   // premultiplied, transparent border
        } }
        let still = px.withUnsafeBytes { TileCodec.encodeLossy(base: $0.baseAddress!, width: w, height: h, stride: w * 4, outWidth: 64, outHeight: 32, quality: 60) }
        XCTAssertNotNil(still)
        guard let still else { return }
        XCTAssertEqual(TileCodec.size(of: still)?.width, 64)
        XCTAssertEqual(TileCodec.size(of: still)?.height, 32)
        XCTAssertLessThan(still.count, 2000)
        var out = [UInt8](repeating: 9, count: 64 * 32 * 4)
        XCTAssertTrue(out.withUnsafeMutableBytes { TileCodec.decode(still, into: $0.baseAddress!, width: 64, height: 32, stride: 64 * 4) })
        XCTAssertEqual(out[3], 0, "the transparent corner stays transparent")
        XCTAssertEqual(out[(16 * 64 + 32) * 4 + 3], 255, "the opaque middle stays opaque")
        // Lossless with alpha keeps every byte, alpha included.
        let exact = px.withUnsafeBytes { TileCodec.encode(base: $0.baseAddress!, width: w, height: h, stride: w * 4, format: .lossless, alpha: true) }!
        var back = [UInt8](repeating: 0, count: w * h * 4)
        XCTAssertTrue(back.withUnsafeMutableBytes { TileCodec.decode(exact, into: $0.baseAddress!, width: w, height: h, stride: w * 4) })
        XCTAssertEqual(back, px)
    }

    func testOcclusionAndChildFolding() {
        let display = PixelRect(x: 0, y: 0, width: 1000, height: 800)
        let front = ControlMessage.WindowInfo(id: 1, pid: 1, title: "", frame: PixelRect(x: 0, y: 0, width: 500, height: 800), z: 0)
        let back = ControlMessage.WindowInfo(id: 2, pid: 2, title: "", frame: PixelRect(x: 0, y: 0, width: 1000, height: 800), z: 1)
        let (fraction, covering) = WindowTrackerOcclusion.occlusion(of: back, in: [front, back], display: display)
        XCTAssertEqual(fraction, 0.5, accuracy: 0.05)
        XCTAssertEqual(covering, [PixelRect(x: 0, y: 0, width: 500, height: 800)])
        let (f2, _) = WindowTrackerOcclusion.occlusion(of: front, in: [front, back], display: display)
        XCTAssertEqual(f2, 1.0, accuracy: 0.001)
        // Half off the display counts as half visible.
        let edge = ControlMessage.WindowInfo(id: 3, pid: 3, title: "", frame: PixelRect(x: 800, y: 0, width: 400, height: 800), z: 0)
        XCTAssertEqual(WindowTrackerOcclusion.occlusion(of: edge, in: [edge], display: display).visibleFraction, 0.5, accuracy: 0.001)
    }

    func testStagedTilesAndCommitRoundTrip() throws {
        let h = TileMessage.Header(captureSeq: 1, inputSeq: 2, windowID: 7, captureNanos: 3)
        let staged = TileMessage.tiles(.init(header: h, refinement: true, staged: true, tiles: [.init(rect: PixelRect(x: 0, y: 0, width: 64, height: 64), format: .lossless, data: Data([1]))]))
        let commit = TileMessage.commit(layer: 7)
        var p = TileStreamParser()
        let got = try p.feed(staged.encode(msgSeq: 1) + commit.encode(msgSeq: 2))
        XCTAssertEqual(got.map(\.message), [staged, commit])
        if case .tiles(let t) = got[0].message { XCTAssertTrue(t.staged); XCTAssertTrue(t.refinement) }
    }

    /// Stage 1's commits as one message: the layer set survives the round trip, alongside separate messages in one write.
    func testCommitSetRoundTrip() throws {
        let set = TileMessage.commitSet(layers: [0, 400, 10602, 12532])
        var p = TileStreamParser()
        let got = try p.feed(set.encode(msgSeq: 5) + TileMessage.commit(layer: 9).encode(msgSeq: 6))
        XCTAssertEqual(got.map(\.message), [set, .commit(layer: 9)])
    }

    /// The alpha mask: clear and opaque flags carry no data; a soft-edged plane survives zlib exactly.
    func testAlphaMaskRoundTrip() throws {
        var plane = [UInt8](repeating: 255, count: 64 * 64)
        for y in 0..<64 { for x in 0..<12 { plane[y * 64 + x] = UInt8(x * 20) } }
        let z = try XCTUnwrap(AlphaPlane.compress(plane))
        XCTAssertLessThan(z.count, 600, "a mostly flat mask compresses well (\(z.count) B)")
        XCTAssertEqual(AlphaPlane.decompress(z, count: plane.count), plane)
        let m = TileMessage.alphaMask(layer: 7, tiles: [.init(col: 0, row: 0, kind: .plane, data: z), .init(col: 1, row: 0, kind: .clear), .init(col: 2, row: 3, kind: .opaque)])
        var p = TileStreamParser()
        XCTAssertEqual(try p.feed(m.encode(msgSeq: 1)).map(\.message), [m])
    }

    func testFrameEndRoundTrip() throws {
        let m = TileMessage.frameEnd(captureSeq: 4242, layers: [0, 13046, 4294967040])
        var p = TileStreamParser()
        XCTAssertEqual(try p.feed(m.encode(msgSeq: 9)).map(\.message), [m])
    }

    func testTileKeysRoundTrip() {
        let h = TileMessage.Header(captureSeq: 9, inputSeq: 1, windowID: 0, captureNanos: 2)
        let keys = [TileKey.make(contentSeq: 7, rank: TileKey.lossless), TileKey.make(contentSeq: 3, rank: TileKey.lossless)]
        let m = TileMessage.tiles(.init(header: h, refinement: true, tiles: [.init(rect: PixelRect(x: 0, y: 0, width: 128, height: 64), format: .lossless, data: Data([1, 2, 3]), keys: keys)]))
        let d = m.encode(msgSeq: 1)
        XCTAssertEqual(TileMessage.decode(kind: d[0], body: d.subdata(in: 9..<d.count)), m)
        let unkeyed = TileMessage.tiles(.init(header: h, refinement: true, tiles: [.init(rect: PixelRect(x: 0, y: 0, width: 64, height: 64), format: .lossless, data: Data([1]))]))
        let du = unkeyed.encode(msgSeq: 2)
        XCTAssertEqual(du[9 + 24] & 8, 0, "no keys, no flag: older viewers read it unchanged")
        let payload = VideoFramePayload.encode(parameterSets: [], tileMask: Data([0b101]), keys: [1, 2], sample: Data([9, 9]))
        let v = VideoFramePayload.decode(payload, hasParameterSets: false, hasTileMask: true, hasKeys: true)
        XCTAssertEqual(v?.keys, [1, 2]); XCTAssertEqual(v?.sample, Data([9, 9]))
    }
}
