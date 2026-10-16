import XCTest
@testable import MirageCore

final class VideoWireTests: XCTestCase {
    func testFragmentRoundTrip() {
        let payload = Data((0..<5000).map { UInt8($0 & 0xff) })
        let frags = VideoFragment.fragments(frameSeq: 42, flags: [.keyframe, .parameterSets], captureNanos: 123_456, payload: payload)
        XCTAssertEqual(frags.count, 5)
        XCTAssertTrue(frags.allSatisfy { $0.count <= VideoFragment.datagramSize })
        let decoded = frags.compactMap(VideoFragment.decode)
        XCTAssertEqual(decoded.count, 5)
        XCTAssertEqual(decoded[0].frameSeq, 42)
        XCTAssertEqual(decoded[0].flags, [.keyframe, .parameterSets])
        XCTAssertEqual(decoded[0].captureNanos, 123_456)
        XCTAssertEqual(decoded.map(\.payload).reduce(Data(), +), payload)
    }

    func testPayloadParameterSets() {
        let sets = [Data([1, 2, 3]), Data([4, 5])]
        let sample = Data([9, 9, 9, 9])
        let enc = VideoFramePayload.encode(parameterSets: sets, sample: sample)
        let dec = VideoFramePayload.decode(enc, hasParameterSets: true)
        XCTAssertEqual(dec?.parameterSets, sets)
        XCTAssertEqual(dec?.sample, sample)
        XCTAssertEqual(VideoFramePayload.decode(sample, hasParameterSets: false)?.sample, sample)
    }

    func testAssemblerReordersAndDetectsLoss() {
        var a = FrameAssembler()
        let p1 = Data(repeating: 1, count: 3000), p2 = Data(repeating: 2, count: 3000)
        let f1 = VideoFragment.fragments(frameSeq: 1, flags: [], captureNanos: 1, payload: p1).compactMap(VideoFragment.decode)
        let f2 = VideoFragment.fragments(frameSeq: 2, flags: [], captureNanos: 2, payload: p2).compactMap(VideoFragment.decode)
        // Frame 1 arrives out of order, complete.
        XCTAssertTrue(a.ingest(f1[2], now: 10).isEmpty)
        XCTAssertTrue(a.ingest(f1[0], now: 11).isEmpty)
        let done = a.ingest(f1[1], now: 12)
        guard case .completed(let frame)? = done.first else { return XCTFail("expected completion, got \(done)") }
        XCTAssertEqual(frame.seq, 1); XCTAssertEqual(frame.sample, p1); XCTAssertEqual(frame.firstFragmentNanos, 10)
        // Frame 2 is missing a fragment; frame 3 completing does NOT declare it lost yet (reordering).
        _ = a.ingest(f2[0], now: 20)
        let f3 = VideoFragment.fragments(frameSeq: 3, flags: [.keyframe], captureNanos: 3, payload: Data([7])).compactMap(VideoFragment.decode)
        let ev = a.ingest(f3[0], now: 30)
        XCTAssertEqual(ev.count, 1)
        guard case .completed(let f3done)? = ev.first else { return XCTFail("expected completion, got \(ev)") }
        XCTAssertEqual(f3done.seq, 3)
        XCTAssertEqual(a.pendingCount, 1)
        // A late fragment of frame 2 (older than the newest completed frame) retires it quietly.
        XCTAssertTrue(a.ingest(f2[1], now: 31).isEmpty)
        XCTAssertEqual(a.pendingCount, 0)
        // A partial that nothing completes is declared lost once it is older than the timeout...
        let f4 = VideoFragment.fragments(frameSeq: 4, flags: [], captureNanos: 4, payload: p1).compactMap(VideoFragment.decode)
        _ = a.ingest(f4[0], now: 40)
        let f5 = VideoFragment.fragments(frameSeq: 5, flags: [], captureNanos: 5, payload: Data([1])).compactMap(VideoFragment.decode)
        let late = a.ingest(f5[0], now: 40 + a.timeoutNanos + 1)
        XCTAssertEqual(late.count, 2)
        guard case .lost(let lostSeq)? = late.first else { return XCTFail("expected lost first, got \(late)") }
        XCTAssertEqual(lostSeq, 4)
        // ...or once the stream is more than reorderWindow frames past it.
        let f6 = VideoFragment.fragments(frameSeq: 6, flags: [], captureNanos: 6, payload: p1).compactMap(VideoFragment.decode)
        _ = a.ingest(f6[0], now: 50)
        let far = VideoFragment.fragments(frameSeq: 6 + a.reorderWindow + 1, flags: [], captureNanos: 7, payload: Data([1])).compactMap(VideoFragment.decode)
        let ev2 = a.ingest(far[0], now: 51)
        XCTAssertTrue(ev2.contains { if case .lost(6) = $0 { return true } else { return false } }, "\(ev2)")
        XCTAssertEqual(a.pendingCount, 0)
    }

    func testDatagramPingHasTypeByte() {
        let d = DatagramPing.encode(seq: 7, size: 32)
        XCTAssertEqual(d[0], datagramMagic); XCTAssertEqual(d[1], DatagramType.ping.rawValue); XCTAssertEqual(d.count, 32)
        XCTAssertEqual(DatagramPing.decode(d)?.seq, 7)
        XCTAssertNil(VideoFragment.decode(d))
    }
}

final class TileWireTests: XCTestCase {
    func testFragmentCarriesRegionAndSeqs() {
        let frags = VideoFragment.fragments(frameSeq: 9, flags: [.recovery], captureNanos: 5, payload: Data(repeating: 3, count: 100),
                                            captureSeq: 77, inputSeq: 123_456_789_012, region: PixelRect(x: 64, y: 128, width: 640, height: 320))
        let f = VideoFragment.decode(frags[0])!
        XCTAssertEqual(f.captureSeq, 77); XCTAssertEqual(f.inputSeq, 123_456_789_012)
        XCTAssertEqual(f.region, PixelRect(x: 64, y: 128, width: 640, height: 320))
        XCTAssertEqual(frags[0].count, VideoFragment.headerSize + 100)
        var a = FrameAssembler()
        guard case .completed(let frame)? = a.ingest(f, now: 1).first else { return XCTFail() }
        XCTAssertEqual(frame.region.width, 640); XCTAssertEqual(frame.inputSeq, 123_456_789_012); XCTAssertEqual(frame.fragments, 1)
    }

    func testTileMessagesRoundTripThroughParserInPieces() throws {
        let h = TileMessage.Header(captureSeq: 5, inputSeq: 99, windowID: 4242, captureNanos: 1_000_000)
        let tiles = TileMessage.tiles(.init(header: h, refinement: true, tiles: [
            .init(rect: PixelRect(x: 0, y: 64, width: 128, height: 64), format: .lossless, data: Data([1, 2, 3])),
            .init(rect: PixelRect(x: 640, y: 0, width: 64, height: 64), format: .nearLossless, data: Data(repeating: 9, count: 700)),
        ]))
        let copy = TileMessage.copyRect(.init(header: h, rect: PixelRect(x: 10, y: 20, width: 300, height: 400), dx: -3, dy: 40))
        let reset = TileMessage.reset(width: 2560, height: 1440)
        let bytes = tiles.encode(msgSeq: 1) + copy.encode(msgSeq: 2) + reset.encode(msgSeq: 3)
        var p = TileStreamParser()
        var got: [(seq: UInt32, bytes: Int, message: TileMessage)] = []
        // Feed in awkward chunk sizes to exercise partial framing.
        var i = bytes.startIndex
        var n = 1
        while i < bytes.endIndex {
            let j = min(i + n, bytes.endIndex)
            got += try p.feed(bytes.subdata(in: i..<j))
            i = j; n = n * 3 + 1
        }
        XCTAssertEqual(got.map(\.seq), [1, 2, 3])
        XCTAssertEqual(got.map(\.message), [tiles, copy, reset])
        XCTAssertEqual(got.map(\.bytes).reduce(0, +), bytes.count)
    }

    func testPixelRectAlgebra() {
        let a = PixelRect(x: 0, y: 0, width: 100, height: 100), b = PixelRect(x: 50, y: 50, width: 100, height: 100)
        XCTAssertEqual(a.intersection(b), PixelRect(x: 50, y: 50, width: 50, height: 50))
        XCTAssertEqual(a.union(b), PixelRect(x: 0, y: 0, width: 150, height: 150))
        XCTAssertTrue(a.intersection(PixelRect(x: 100, y: 0, width: 10, height: 10)).isEmpty)
        XCTAssertEqual(a.union(.zero), a)
    }

    func testControlMessagesWithNewFieldsRoundTrip() throws {
        let msgs: [ControlMessage] = [
            .frameAck(.init(seq: 1, captureNanos: 2, receivedNanos: 3, decodedNanos: 4, bytes: 5, lost: false, firstReceivedNanos: 6, fragments: 7)),
            .tileAck(.init(msgSeq: 8, captureNanos: 9, receivedNanos: 10, bytes: 11)),
            .windowList(.init(captureSeq: 12, windows: [.init(id: 1, pid: 2, title: "t", frame: PixelRect(x: 1, y: 2, width: 3, height: 4), z: 0, scrollRect: nil)])),
            .rateState(.init(targetKbps: 700, capacityKbps: 1000, queueMs: 12.5, rung: 1, scale: 0.75, tileBudgetKbps: 200, videoKbps: 500, tileKbps: 80)),
            .scroll(.init(x: 0.5, y: 0.5, dx: 0, dy: -40, precise: true, modifiers: 0, seq: 77)),
        ]
        for m in msgs {
            let d = try Frame.encode(m)
            XCTAssertEqual(try Frame.decode(ControlMessage.self, from: d.dropFirst(4)), m)
        }
        XCTAssertEqual(msgs[4].inputSeq, 77)
    }
}
