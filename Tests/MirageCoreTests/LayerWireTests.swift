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
}
