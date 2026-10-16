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
