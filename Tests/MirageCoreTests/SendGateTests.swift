import XCTest
@testable import MirageHost

/// Crisp-first: nothing enters the wire past the in-flight limit, whatever the encoders produce (phrz's iPhone,
/// 2026-10-25: 12 blocks ~5x their estimates finished together, 2.5 MB against a 148 KB cap).
final class SendGateTests: XCTestCase {
    func testTwelveOversizedBlocksNeverExceedCapPlusOneMessage() {
        let cap = 148_000, block = 210_000
        for local in [false, true] {
            var gate = SendGate<Int>()
            var inflight = 0, maxInflight = 0
            for i in 0..<12 { if gate.offer(i, bytes: block, inflight: inflight, cap: cap, local: local) != nil { inflight += block } }
            maxInflight = inflight
            var sent = maxInflight / block
            // Acks arrive one message at a time; whatever the gate releases goes in flight.
            while sent < 12 {
                inflight -= block
                let (go, dropped) = gate.release(inflight: inflight, cap: cap, local: local) { _ in false }
                XCTAssertTrue(dropped.isEmpty)
                inflight += go.count * block; sent += go.count
                maxInflight = max(maxInflight, inflight)
                if go.isEmpty && inflight == 0 { XCTFail("stalled with \(12 - sent) held"); break }
            }
            let limit = local ? cap * 2 : cap
            XCTAssertLessThanOrEqual(maxInflight, max(block, limit + block), "local \(local): at most the limit plus one message")
        }
    }
    func testOrderAndStaleDrop() {
        var gate = SendGate<String>()
        XCTAssertEqual(gate.offer("a", bytes: 50, inflight: 0, cap: 100, local: false), "a")
        XCTAssertNil(gate.offer("b", bytes: 50, inflight: 120, cap: 100, local: false))
        XCTAssertNil(gate.offer("c", bytes: 10, inflight: 0, cap: 100, local: false), "behind a held message, never ahead of it")
        let (go, dropped) = gate.release(inflight: 0, cap: 100, local: false) { $0 == "b" }
        XCTAssertEqual(dropped, ["b"]); XCTAssertEqual(go, ["c"])
        XCTAssertTrue(gate.held.isEmpty)
    }
}
