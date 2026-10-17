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

final class ReviewHighFindingsTests: XCTestCase {
    /// H1: a two-fragment frame loses its first (full-size) fragment; the known one is the short last one.
    func testParityRebuildsMissingFirstFragmentOfTwo() {
        let payload = Data((0..<(VideoFragment.maxPayload + 300)).map { UInt8($0 % 251) })
        let frags = VideoFragment.fragments(frameSeq: 9, flags: [.keyframe, .recovery], captureNanos: 1, payload: payload).compactMap(VideoFragment.decode)
        XCTAssertEqual(frags.count, 2)
        let parity = ParityFragment.parity(frameSeq: 9, payloads: frags.map(\.payload)).compactMap(ParityFragment.decode)
        var a = FrameAssembler()
        _ = a.ingest(frags[1], now: 10)
        var out: VideoFrame? = nil
        for e in a.ingest(parity: parity[0], now: 11) { if case .completed(let f) = e { out = f } }
        XCTAssertEqual(out?.sample, payload, "the rebuilt first fragment must be full-size, not the last one's length")
        XCTAssertEqual(out?.fragmentsLost, 1)
        // And the missing *last* fragment of a group whose other member is full-size.
        var b = FrameAssembler()
        _ = b.ingest(frags[0], now: 10)
        var out2: VideoFrame? = nil
        for e in b.ingest(parity: parity[0], now: 11) { if case .completed(let f) = e { out2 = f } }
        XCTAssertEqual(out2?.sample, payload)
    }

    /// H5: a frame still arriving from the pacer is not NACKed for its tail; a hole below the highest index is.
    func testNackAsksOnlyForFragmentsBelowTheHighestReceivedUntilTheTailIsOverdue() {
        var a = FrameAssembler(); a.nackAfterNanos = 30_000_000; a.nackRepeatNanos = 100_000_000
        let frags = VideoFragment.fragments(frameSeq: 1, flags: [.keyframe], captureNanos: 1, payload: Data(repeating: 1, count: 20 * VideoFragment.maxPayload)).compactMap(VideoFragment.decode)
        // Paced arrival every 20 ms: 0, 1, (2 lost), 3, 4 then a 35 ms silence (a scheduler hiccup).
        var t: UInt64 = 0
        for i in [0, 1, 3, 4] { t += 20_000_000; _ = a.ingest(frags[i], now: t) }
        let ev = a.tick(now: t + 35_000_000)
        guard case .nack(_, let missing)? = ev.first else { return XCTFail("expected a nack for the hole, got \(ev)") }
        XCTAssertEqual(missing, [2], "only the hole below the highest index, never the unsent tail")
        // The tail keeps arriving; after 4× the inter-fragment gap of silence the tail is asked for too.
        for i in 5...8 { t += 20_000_000; _ = a.ingest(frags[i], now: t) }
        _ = a.ingest(frags[2], now: t)   // the resend lands
        XCTAssertTrue(a.tick(now: t + 60_000_000).isEmpty, "60 ms after the last fragment: not yet overdue at a 20 ms spacing")
        let late = a.tick(now: t + 130_000_000)
        guard case .nack(_, let tail)? = late.first else { return XCTFail("expected the tail nack, got \(late)") }
        XCTAssertEqual(tail, Array(9..<20))
        // A later frame's fragment proves the tail should have landed: immediate.
        var b = FrameAssembler(); b.nackAfterNanos = 30_000_000
        _ = b.ingest(frags[0], now: 10); _ = b.ingest(frags[1], now: 20)
        let f2 = VideoFragment.fragments(frameSeq: 2, flags: [], captureNanos: 2, payload: Data([1])).compactMap(VideoFragment.decode)
        _ = b.ingest(f2[0], now: 30)
        let ev2 = b.tick(now: 20 + 31_000_000)
        guard case .nack(let s, let all)? = ev2.first else { return XCTFail("\(ev2)") }
        XCTAssertEqual(s, 1); XCTAssertEqual(all, Array(2..<20))
    }

    /// H6: pacing derives its interval from the rate; below ~1.85 Mbps it used to send a datagram every 5 ms regardless.
    func testPaceOffsetsFollowTheRate() {
        let at440 = FrameAssembler.paceOffsets(count: 31, payloadBytes: 1200, bytesPerSecond: 440_000 / 8 * 1.25)   // 68.75 KB/s
        XCTAssertEqual(Double(at440.last!) / 1e9, 30 * 1200 / 68750.0, accuracy: 0.001)   // ~0.52 s for a 36 KB keyframe
        XCTAssertGreaterThan(at440[1], 17_000_000)   // 17.5 ms per datagram, not 5
        let fast = FrameAssembler.paceOffsets(count: 100, payloadBytes: 1200, bytesPerSecond: 20_000_000 / 8)   // 20 Mbps: batches of 2 ms
        XCTAssertEqual(fast[0], 0); XCTAssertLessThanOrEqual(fast.last!, 100_000_000)
        XCTAssertEqual(Set(fast).count, Int(fast.last! / 2_000_000) + 1)
    }

    /// H3: the stale deadline covers the pacer time plus three RTTs; H4: one keyframe affordability predicate.
    func testStaleDeadlineAndKeyframeFit() {
        let d = FrameAssembler.staleDeadlineNanos(paceEndNanos: 1_900_000_000, sentNanos: 1_000_000_000, srttNanos: 450_000_000)
        XCTAssertEqual(d, 1_900_000_000 + 1_350_000_000 + 350_000_000, "a 0.9 s paced keyframe at 450 ms RTT is not stale at 1 s")
        XCTAssertTrue(FrameAssembler.keyframeFits(encodedWidth: 1200, encodedHeight: 675, videoKbps: 173))   // 20.25 KB vs 21.6 KB/s: just fits
        XCTAssertTrue(FrameAssembler.keyframeFits(encodedWidth: 400, encodedHeight: 225, videoKbps: 150))
        XCTAssertFalse(FrameAssembler.keyframeFits(encodedWidth: 3200, encodedHeight: 1800, videoKbps: 800))   // 144 KB vs 100 KB/s
    }

    /// H7 and the fragment-loss estimate in the rate controller.
    func testRateControllerShortfallNeedsBudgetLimitAndFragmentLoss() {
        var rc = RateController(initialKbps: 800, maxKbps: 800, nativePixels: 3200 * 1800)
        rc.climbOneRung(now: 1); rc.climbOneRung(now: 1); rc.climbOneRung(now: 1); rc.climbOneRung(now: 1)
        XCTAssertEqual(rc.rung, 0)
        var now: UInt64 = 10_000_000_000
        // A 15 fps-capped region achieving 12 fps against a 15 fps request: no shortfall.
        for _ in 0..<6 { rc.videoRate(achievedFPS: 12, wantedFPS: 15, active: true, budgetLimited: true, now: now); now += 1_000_000_000 }
        XCTAssertEqual(rc.rung, 0)
        // 5 of 30 wanted, but nothing was skipped for budget (the interval gate): no shortfall either.
        for _ in 0..<6 { rc.videoRate(achievedFPS: 5, wantedFPS: 30, active: true, budgetLimited: false, now: now); now += 1_000_000_000 }
        XCTAssertEqual(rc.rung, 0)
        // 5 of 30 because the budget held frames back: one rung down after the dwell.
        for _ in 0..<6 { rc.videoRate(achievedFPS: 5, wantedFPS: 30, active: true, budgetLimited: true, now: now); now += 1_000_000_000 }
        XCTAssertEqual(rc.rung, 1)
        // Fragment loss: 6 of 100 fragments needed parity or a NACK → 6 %, parity groups of 4, tier sees loss.
        XCTAssertEqual(rc.parityGroupSize, 8)
        for _ in 0..<10 { rc.fragmentLoss(lost: 0, total: 5, now: now) }
        rc.fragmentLoss(lost: 6, total: 50, now: now)
        XCTAssertEqual(rc.fragmentLossPercent, 6, accuracy: 0.01)
        XCTAssertEqual(rc.lossPercent, 6, accuracy: 0.01)
        XCTAssertEqual(rc.parityGroupSize, 4)
        XCTAssertEqual(rc.frameLossPercent, 0, "recovered loss does not count against the tier")
        XCTAssertNotEqual(rc.tier, .extreme)
    }
}

final class DelayControllerTests: XCTestCase {
    /// Mac-daddy regression (2026-10-17): a clean connection on a 148 ms, 3.5 Mbps, loss-free link read a
    /// constant ~90 ms queue after the opening refinement burst and decayed to the floor. Synthetic acks:
    /// 3 s of big refinement blocks whose one-way delay carries their own serialization, then an idle link
    /// with tiny caret tiles and a few paced video frames; the target must be back at the cap within a
    /// few seconds and the tier must never leave Constrained.
    func testTargetRecoversToCapAfterOpeningBurstOnIdleLink() {
        var rc = RateController(initialKbps: 800, maxKbps: 800, nativePixels: 1108 * 720)
        let base = 74_000_000.0            // one-way delay, 148 ms RTT
        var now: UInt64 = 1_000_000_000
        // Opening: paced keyframes (honest samples: sent = pace end), then 3 s of 30 KB blocks every 300 ms
        // whose delay is base + 70–90 ms of serialization at 3.5 Mbps.
        for _ in 0..<5 {
            rc.frameAcked(sentNanos: now, firstReceived: now + UInt64(base), lastReceived: now + UInt64(base) + 2_000_000, fragments: 1, bytes: 8000, now: now + 150_000_000, rttNanos: 148_000_000)
            now += 200_000_000
        }
        for _ in 0..<10 {
            rc.delaySample(sentNanos: now, receivedNanos: now + UInt64(base) + 85_000_000, bytes: 30_000, now: now + 160_000_000)
            now += 300_000_000
        }
        let afterBurst = rc.targetKbps
        // Idle: a 250 B caret tile every 500 ms for 8 s, delay = base + 3 ms.
        for _ in 0..<16 {
            rc.delaySample(sentNanos: now, receivedNanos: now + UInt64(base) + 3_000_000, bytes: 250, now: now + 80_000_000)
            now += 500_000_000
        }
        XCTAssertLessThan(rc.queueMs, 40, "an idle link reads no queue: big blocks' serialization is not path delay")
        XCTAssertGreaterThanOrEqual(rc.targetKbps, 760, "target back at the cap after the opening burst (was \(afterBurst) after it)")
        XCTAssertEqual(rc.tier, .constrained)
        XCTAssertNotEqual(rc.rung, RateController.tinyRung)
    }

    /// The old behaviour, kept as a guard: large messages fed as delay samples would read as queue.
    func testLargeTileMessagesAreNotDelaySamples() {
        var rc = RateController(initialKbps: 800, maxKbps: 800, nativePixels: 1108 * 720)
        var now: UInt64 = 1_000_000_000
        rc.delaySample(sentNanos: now, receivedNanos: now + 74_000_000, bytes: 200, now: now + 150_000_000)
        for _ in 0..<20 { now += 300_000_000; rc.delaySample(sentNanos: now, receivedNanos: now + 74_000_000 + 90_000_000, bytes: 30_000, now: now + 160_000_000) }
        XCTAssertLessThan(rc.queueMs, 10)
        XCTAssertEqual(rc.targetKbps, 800)
    }
}

final class TransientSpikeTests: XCTestCase {
    /// Mac-daddy follow-up: one 812 ms RTT sample on an idle link dropped the target to 417 and it was
    /// still there 6 s later. A spike lasting one RTT, then an idle link: the target must be back at
    /// 90 % of the cap within 3 s of the spike.
    func testTargetReprobesToCapWithinThreeSecondsAfterOneRttSpike() {
        var rc = RateController(initialKbps: 800, maxKbps: 800, nativePixels: 1108 * 720)
        let base = 74_000_000.0
        var now: UInt64 = 1_000_000_000
        func idle(_ seconds: Double) {
            let n = Int(seconds / 0.1)
            for _ in 0..<n {
                rc.delaySample(sentNanos: now, receivedNanos: now + UInt64(base) + 3_000_000, bytes: 250, now: now + 80_000_000)
                rc.frameAcked(sentNanos: now, firstReceived: now + UInt64(base), lastReceived: now + UInt64(base) + 2_000_000, fragments: 1, bytes: 3000, now: now + 150_000_000, rttNanos: 148_000_000)
                now += 100_000_000
            }
        }
        idle(5)
        XCTAssertEqual(rc.targetKbps, 800); XCTAssertLessThan(rc.queueMs, 10)
        // The spike: one frame and one tile sample 660 ms late (812 ms RTT), and the frame the host gave up on.
        rc.frameAcked(sentNanos: now, firstReceived: now + UInt64(base) + 660_000_000, lastReceived: now + UInt64(base) + 662_000_000, fragments: 1, bytes: 3000, now: now + 812_000_000, rttNanos: 812_000_000)
        rc.delaySample(sentNanos: now, receivedNanos: now + UInt64(base) + 660_000_000, bytes: 250, now: now + 812_000_000)
        rc.lossDetected(now: now + 900_000_000)
        now += 1_000_000_000
        let dropped = rc.targetKbps
        XCTAssertLessThan(dropped, 700, "the spike did cost a decrease (\(dropped))")
        let spikeEnd = now
        var recoveredAt: UInt64? = nil
        for _ in 0..<60 {
            idle(0.1)
            if rc.targetKbps >= 720 { recoveredAt = now; break }
        }
        guard let recoveredAt else { return XCTFail("target never recovered: \(rc.targetKbps)") }
        XCTAssertLessThanOrEqual(Double(recoveredAt - spikeEnd) / 1e9, 3.0, "back to 90 % of the cap within 3 s (took \(Double(recoveredAt - spikeEnd) / 1e9) s from \(dropped))")
        idle(2)
        XCTAssertEqual(rc.targetKbps, 800)
        XCTAssertEqual(rc.tier, .constrained)
    }
}

