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

    func testAssemblerDeliversInOrderNacksHolesAndTimesOut() {
        var a = FrameAssembler()
        a.timeoutNanos = 1_000_000_000; a.nackAfterNanos = 30_000_000; a.nackRepeatNanos = 200_000_000
        let p1 = Data(repeating: 1, count: 3000), p2 = Data(repeating: 2, count: 3000)
        let f1 = VideoFragment.fragments(frameSeq: 1, flags: [], captureNanos: 1, payload: p1).compactMap(VideoFragment.decode)
        let f2 = VideoFragment.fragments(frameSeq: 2, flags: [], captureNanos: 2, payload: p2).compactMap(VideoFragment.decode)
        // Frame 1 arrives out of order, complete.
        XCTAssertTrue(a.ingest(f1[2], now: 10).isEmpty)
        XCTAssertTrue(a.ingest(f1[0], now: 11).isEmpty)
        let done = a.ingest(f1[1], now: 12)
        guard case .completed(let frame)? = done.first else { return XCTFail("expected completion, got \(done)") }
        XCTAssertEqual(frame.seq, 1); XCTAssertEqual(frame.sample, p1); XCTAssertEqual(frame.firstFragmentNanos, 10)
        // Frame 2 is missing its middle fragment; frame 3 completes behind it but is HELD (in-order delivery).
        _ = a.ingest(f2[0], now: 20); _ = a.ingest(f2[2], now: 21)
        let f3 = VideoFragment.fragments(frameSeq: 3, flags: [.keyframe], captureNanos: 3, payload: Data([7])).compactMap(VideoFragment.decode)
        XCTAssertTrue(a.ingest(f3[0], now: 30).isEmpty, "frame 3 waits for frame 2")
        XCTAssertEqual(a.pendingCount, 2)
        // 30 ms after the gap, the assembler asks for the missing fragment.
        let ev = a.tick(now: 21 + 31_000_000)
        guard case .nack(let seq, let missing)? = ev.first else { return XCTFail("expected a nack, got \(ev)") }
        XCTAssertEqual(seq, 2); XCTAssertEqual(missing, [1])
        // The resent fragment arrives: frame 2 and then frame 3 are delivered, in order.
        let ev2 = a.ingest(f2[1], now: 21 + 200_000_000)
        XCTAssertEqual(ev2.count, 2)
        guard case .completed(let d2)? = ev2.first, case .completed(let d3)? = ev2.last else { return XCTFail("\(ev2)") }
        XCTAssertEqual(d2.seq, 2); XCTAssertEqual(d2.sample, p2); XCTAssertEqual(d3.seq, 3)
        XCTAssertEqual(a.recoveredByNack, 1)
        // A partial nothing completes is given up after the timeout and reported lost.
        let f4 = VideoFragment.fragments(frameSeq: 4, flags: [], captureNanos: 4, payload: p1).compactMap(VideoFragment.decode)
        _ = a.ingest(f4[0], now: 1_000_000_000)
        let late = a.tick(now: 1_000_000_000 + a.timeoutNanos + 1)
        guard case .lost(let lostSeq)? = late.first else { return XCTFail("expected lost, got \(late)") }
        XCTAssertEqual(lostSeq, 4)
        XCTAssertEqual(a.pendingCount, 0)
    }

    func testPacedFrameIsNotDeclaredLostWhileStillArriving() {
        var a = FrameAssembler()
        a.timeoutNanos = 300_000_000   // what a 1 ms RTT gives
        let payload = Data(repeating: 5, count: 1157 * 40)
        let frags = VideoFragment.fragments(frameSeq: 1, flags: [.keyframe], captureNanos: 1, payload: payload).compactMap(VideoFragment.decode)
        XCTAssertEqual(frags.count, 40)
        // Fragments 30 ms apart: the frame takes 1.2 s, far beyond the 300 ms timeout, with no gap over 30 ms.
        var now: UInt64 = 1_000_000_000
        var completed = false
        for f in frags {
            let ev = a.ingest(f, now: now)
            XCTAssertFalse(ev.contains { if case .lost = $0 { return true } else { return false } }, "declared lost mid-flight at \(now)")
            if ev.contains(where: { if case .completed = $0 { return true } else { return false } }) { completed = true }
            _ = a.tick(now: now + 15_000_000)
            now += 30_000_000
        }
        XCTAssertTrue(completed)
    }

    func testParityRebuildsOneLostFragment() {
        var a = FrameAssembler()
        let payload = Data((0..<3500).map { UInt8($0 & 0xff) })
        let frags = VideoFragment.fragments(frameSeq: 9, flags: [.keyframe], captureNanos: 1, payload: payload)
        let decoded = frags.compactMap(VideoFragment.decode)
        let payloads = decoded.map(\.payload)
        let parity = ParityFragment.parity(frameSeq: 9, payloads: payloads).compactMap(ParityFragment.decode)
        XCTAssertEqual(parity.count, 1); XCTAssertEqual(decoded.count, 4)
        // Lose the last (short) fragment; parity rebuilds it.
        _ = a.ingest(decoded[0], now: 1); _ = a.ingest(decoded[1], now: 2); _ = a.ingest(decoded[2], now: 2)
        let ev = a.ingest(parity: parity[0], now: 3)
        guard case .completed(let f)? = ev.first else { return XCTFail("expected completion from parity, got \(ev)") }
        XCTAssertEqual(f.sample, payload)
        XCTAssertEqual(a.recoveredByParity, 1)
        // Lose a middle (full-size) fragment of another frame; parity arriving first still works.
        var b = FrameAssembler()
        let frags2 = VideoFragment.fragments(frameSeq: 10, flags: [], captureNanos: 1, payload: payload).compactMap(VideoFragment.decode)
        let par2 = ParityFragment.parity(frameSeq: 10, payloads: frags2.map(\.payload)).compactMap(ParityFragment.decode)
        _ = b.ingest(parity: par2[0], now: 1)
        _ = b.ingest(frags2[0], now: 2); _ = b.ingest(frags2[3], now: 2)
        let ev2 = b.ingest(frags2[2], now: 3)
        guard case .completed(let g)? = ev2.first else { return XCTFail("\(ev2)") }
        XCTAssertEqual(g.sample, payload)
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

final class TileMaskTests: XCTestCase {
    func testMaskBitsAndPayloadRoundTrip() {
        let region = PixelRect(x: 64, y: 128, width: 200, height: 70)   // 4 cols × 2 rows
        let g = TileMask.grid(for: region)
        XCTAssertEqual(g.cols, 4); XCTAssertEqual(g.rows, 2)
        var m = TileMask(cols: g.cols, rows: g.rows)
        m[3, 1] = true; m[0, 0] = true
        XCTAssertEqual(m.count, 2); XCTAssertTrue(m[3, 1]); XCTAssertFalse(m[1, 1])
        let payload = VideoFramePayload.encode(parameterSets: [Data([1])], tileMask: m.bits, sample: Data([7, 7]))
        let d = VideoFramePayload.decode(payload, hasParameterSets: true, hasTileMask: true)
        XCTAssertEqual(d?.parameterSets, [Data([1])]); XCTAssertEqual(d?.sample, Data([7, 7]))
        XCTAssertEqual(TileMask(cols: 4, rows: 2, bits: d!.tileMask!), m)
        XCTAssertEqual(TileMask.full(cols: 3, rows: 3).count, 9)
    }
}

final class ScriptedInputTests: XCTestCase {
    func testScriptedFlagAndLocusRoundTrip() throws {
        let k = ControlMessage.key(.init(keyCode: 0, down: true, isRepeat: false, modifiers: 0, characters: "a", seq: 5))
        XCTAssertFalse(k.isScripted)
        let s = k.markedScripted()
        XCTAssertTrue(s.isScripted)
        XCTAssertEqual(try Frame.decode(ControlMessage.self, from: try Frame.encode(s).dropFirst(4)).isScripted, true)
        let m = ControlMessage.mouseMove(.init(x: 0.25, y: 0.5))
        XCTAssertEqual(m.inputPoint?.x, 0.25); XCTAssertNil(k.inputPoint)
        let h = ControlMessage.hostStatus(.init(consoleLocked: true, frontmostApp: "loginwindow", frontmostWindowID: 0, frontmostWindowTitle: ""))
        XCTAssertEqual(try Frame.decode(ControlMessage.self, from: try Frame.encode(h).dropFirst(4)), h)
    }
}

final class WindowListDeltaTests: XCTestCase {
    func testDeltaAndApply() {
        let a = ControlMessage.WindowInfo(id: 1, pid: 1, title: "a", frame: PixelRect(x: 0, y: 0, width: 10, height: 10), z: 0)
        let b = ControlMessage.WindowInfo(id: 2, pid: 1, title: "b", frame: PixelRect(x: 5, y: 5, width: 10, height: 10), z: 1)
        var b2 = b; b2.frame = b.frame.offset(3, 0)
        let c = ControlMessage.WindowInfo(id: 3, pid: 2, title: "c", frame: PixelRect(x: 0, y: 0, width: 5, height: 5), z: 2)
        XCTAssertNil(ControlMessage.WindowList.delta(from: [a, b], to: [a, b], captureSeq: 1))
        let d = ControlMessage.WindowList.delta(from: [a, b], to: [b2, c], captureSeq: 2)!
        XCTAssertTrue(d.isDelta); XCTAssertEqual(d.changed, [b2, c]); XCTAssertEqual(d.removed, [1])
        XCTAssertEqual(d.apply(to: [a, b]), [b2, c])
        XCTAssertLessThan(try! Frame.encode(ControlMessage.windowList(d)).count, try! Frame.encode(ControlMessage.windowList(.init(captureSeq: 2, windows: [b2, c, a, a, a]))).count)
    }
}

final class LossRecoveryTests: XCTestCase {
    private func frames(_ seqs: [UInt32], flags: VideoFragment.Flags = [], bytes: Int = 3000) -> [UInt32: [VideoFragment]] {
        var out: [UInt32: [VideoFragment]] = [:]
        for s in seqs { out[s] = VideoFragment.fragments(frameSeq: s, flags: flags, captureNanos: UInt64(s), payload: Data(repeating: UInt8(s & 0xff), count: bytes)).compactMap(VideoFragment.decode) }
        return out
    }

    func testShortGapIsNackedWholeAndRepairedInOrder() {
        var a = FrameAssembler()
        a.timeoutNanos = 1_000_000_000; a.nackAfterNanos = 30_000_000; a.nackRepeatNanos = 200_000_000
        let f = frames([1, 2, 3, 4])
        for x in f[1]! { _ = a.ingest(x, now: 10) }
        // Frames 2 and 3 vanish entirely; frame 4 arrives: placeholders for 2 and 3, 4 is held.
        var ev: [FrameAssembler.Event] = []
        for x in f[4]! { ev += a.ingest(x, now: 100) }
        XCTAssertTrue(ev.isEmpty, "nothing delivered yet: \(ev)")
        XCTAssertEqual(a.pendingCount, 3)
        // After the reorder window both missing frames are asked for at once, whole.
        let nacks = a.tick(now: 100 + 31_000_000)
        XCTAssertEqual(nacks.count, 2)
        for n in nacks { if case .nack(_, let frags) = n { XCTAssertEqual(frags, []) } else { XCTFail("\(n)") } }
        XCTAssertEqual(Set(nacks.map(\.seq)), [2, 3])
        // The host resends both; everything comes out in order.
        var got: [UInt32] = []
        for x in f[3]! + f[2]! { for e in a.ingest(x, now: 200_000_000) { if case .completed(let fr) = e { got.append(fr.seq) } } }
        XCTAssertEqual(got, [2, 3, 4])
        XCTAssertEqual(a.recoveredByNack, 6)
    }

    func testLongGapReportsBurstImmediately() {
        var a = FrameAssembler()
        let f = frames([1, 50])
        for x in f[1]! { _ = a.ingest(x, now: 10) }
        let ev = a.ingest(f[50]![0], now: 20)
        guard case .gap(let from, let to)? = ev.first else { return XCTFail("expected gap, got \(ev)") }
        XCTAssertEqual(from, 2); XCTAssertEqual(to, 49)
        XCTAssertEqual(a.pendingCount, 1, "only frame 50 is pending; the burst is not NACKed frame by frame")
        for x in f[50]!.dropFirst() { _ = a.ingest(x, now: 21) }
        XCTAssertEqual(a.pendingCount, 0)
    }

    func testRecoveryFrameDropsOlderHoles() {
        var a = FrameAssembler()
        a.timeoutNanos = 1_000_000_000; a.nackAfterNanos = 30_000_000
        let p = frames([1, 2])
        let k = frames([3], flags: [.keyframe, .recovery], bytes: 500)
        for x in p[1]! { _ = a.ingest(x, now: 10) }
        _ = a.ingest(p[2]![0], now: 20)          // frame 2 has a hole
        var done: [UInt32] = []
        for x in k[3]! { for e in a.ingest(x, now: 30) { if case .completed(let fr) = e { done.append(fr.seq) } else if case .lost = e { XCTFail("no loss verdict expected") } } }
        XCTAssertEqual(done, [3], "the keyframe needs nothing before it; the hole is dropped silently")
        XCTAssertEqual(a.skippedForRecovery, 1)
        XCTAssertEqual(a.pendingCount, 0)
    }

    func testFragmentsLostIsReported() {
        var a = FrameAssembler()
        a.nackAfterNanos = 30_000_000
        let payload = Data((0..<9000).map { UInt8($0 & 0xff) })
        let frags = VideoFragment.fragments(frameSeq: 7, flags: [], captureNanos: 1, payload: payload)
        let parity = ParityFragment.parity(frameSeq: 7, payloads: frags.compactMap(VideoFragment.decode).map(\.payload)).compactMap(ParityFragment.decode)
        let decoded = frags.compactMap(VideoFragment.decode)
        for (i, x) in decoded.enumerated() where i != 2 { _ = a.ingest(x, now: 10) }
        var out: VideoFrame? = nil
        for e in a.ingest(parity: parity[0], now: 11) { if case .completed(let fr) = e { out = fr } }
        XCTAssertEqual(out?.sample, payload)
        XCTAssertEqual(out?.fragmentsLost, 1)
        XCTAssertEqual(a.recoveredByParity, 1)
    }
}
