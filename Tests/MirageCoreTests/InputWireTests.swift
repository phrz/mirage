import XCTest
@testable import MirageCore

final class InputWireTests: XCTestCase {
    func testPacketRoundTrip() {
        let events: [InputPacket.Event] = [
            .init(seq: 10, message: .key(.init(keyCode: 0, down: true, isRepeat: false, modifiers: 1 << 20, characters: "é", seq: 10, scripted: true))),
            .init(seq: 11, message: .key(.init(keyCode: 0, down: false, isRepeat: true, modifiers: 0, characters: nil, seq: 11))),
            .init(seq: 12, message: .mouseButton(.init(button: 1, down: true, x: 0.25, y: 0.75, clickCount: 2, modifiers: 7, seq: 12))),
            .init(seq: 13, message: .scroll(.init(x: 0.5, y: 0.5, dx: -1.5, dy: 30, precise: true, modifiers: 0, seq: 13, scripted: true))),
            .init(seq: 14, message: .modifiers(.init(keyCode: 55, modifiers: 1 << 20, seq: 14))),
        ]
        let p = InputPacket(pointer: .init(seq: 15, x: 0.1, y: 0.9), events: events)
        let d = p.encode()
        XCTAssertLessThan(d.count, 200)
        guard let back = InputPacket.decode(d) else { return XCTFail("decode") }
        XCTAssertEqual(back.events.map(\.seq), [10, 11, 12, 13, 14])
        XCTAssertEqual(back.pointer?.seq, 15)
        XCTAssertEqual(back.pointer!.x, 0.1, accuracy: 1e-4); XCTAssertEqual(back.pointer!.y, 0.9, accuracy: 1e-4)
        if case .key(let k) = back.events[0].message { XCTAssertEqual(k.characters, "é"); XCTAssertEqual(k.scripted, true); XCTAssertEqual(k.modifiers, 1 << 20); XCTAssertTrue(k.down) } else { XCTFail() }
        if case .key(let k) = back.events[1].message { XCTAssertNil(k.characters); XCTAssertNil(k.scripted); XCTAssertTrue(k.isRepeat); XCTAssertFalse(k.down) } else { XCTFail() }
        if case .mouseButton(let m) = back.events[2].message { XCTAssertEqual(m.button, 1); XCTAssertEqual(m.clickCount, 2); XCTAssertEqual(m.x, 0.25, accuracy: 1e-4) } else { XCTFail() }
        if case .scroll(let s) = back.events[3].message { XCTAssertEqual(s.dx, -1.5); XCTAssertEqual(s.dy, 30); XCTAssertTrue(s.precise); XCTAssertEqual(s.scripted, true) } else { XCTFail() }
        if case .modifiers(let m) = back.events[4].message { XCTAssertEqual(m.keyCode, 55); XCTAssertEqual(m.seq, 14) } else { XCTFail() }
        let ack = InputAck(eventSeq: 14, pointerSeq: 15)
        XCTAssertEqual(InputAck.decode(ack.encode()), ack)
        XCTAssertNil(InputAck.decode(d)); XCTAssertNil(InputPacket.decode(ack.encode()))
    }

    func testReceiverIsIdempotentAndOrdered() {
        var rx = InputReceiver()
        let k = { (s: UInt64) in InputPacket.Event(seq: s, message: .key(.init(keyCode: 0, down: true, isRepeat: false, modifiers: 0, characters: "a", seq: s))) }
        // Cumulative packets: a later one repeats the earlier events.
        let r1 = rx.receive(.init(pointer: .init(seq: 2, x: 0.5, y: 0.5), events: [k(1)]))
        XCTAssertEqual(r1.apply.compactMap(\.inputSeq), [1, 2]); XCTAssertEqual(r1.ack, .init(eventSeq: 1, pointerSeq: 2))
        let r2 = rx.receive(.init(pointer: .init(seq: 2, x: 0.5, y: 0.5), events: [k(1), k(3), k(4)]))
        XCTAssertEqual(r2.apply.compactMap(\.inputSeq), [3, 4], "1 is a duplicate, the stale pointer is dropped")
        XCTAssertEqual(rx.duplicates, 1)
        // A reordered older packet changes nothing.
        let r3 = rx.receive(.init(pointer: .init(seq: 2, x: 0.5, y: 0.5), events: [k(1), k(3)]))
        XCTAssertTrue(r3.apply.isEmpty); XCTAssertEqual(r3.ack, .init(eventSeq: 4, pointerSeq: 2))
        // A pointer older than an event in the same packet is applied before it (a click after a move).
        let r4 = rx.receive(.init(pointer: .init(seq: 5, x: 0.1, y: 0.1), events: [k(6)]))
        XCTAssertEqual(r4.apply.compactMap(\.inputSeq), [5, 6])
        // A pointer newer than the events comes last.
        let r5 = rx.receive(.init(pointer: .init(seq: 9, x: 0.2, y: 0.2), events: [k(7), k(8)]))
        XCTAssertEqual(r5.apply.compactMap(\.inputSeq), [7, 8, 9]); XCTAssertEqual(r5.ack, .init(eventSeq: 8, pointerSeq: 9))
    }

    /// The §4a input-integrity proof at the logic level: 1000 keystrokes (down + up) with pointer
    /// moves interleaved, over a simulated link with 5 % random loss in each direction, 20 ms one-way
    /// delay, and a 2 s burst that drops everything. The host must apply every discrete event exactly
    /// once, in order, and the channel must drain by itself afterwards.
    func testThousandKeystrokesUnderLossAndBurst() {
        var ch = InputChannel(); ch.autoFlush = true; ch.setRTT(nanos: 40_000_000)
        var rx = InputReceiver()
        var rng = SplitMix64(seed: 42)
        let oneWay: UInt64 = 20_000_000
        var toHost: [(at: UInt64, data: Data)] = [], toViewer: [(at: UInt64, data: Data)] = []
        var applied: [ControlMessage] = []
        var expected: [ControlMessage] = []
        var pointerApplied = 0
        let burst: ClosedRange<UInt64> = 3_000_000_000...5_000_000_000
        func lossy(_ now: UInt64) -> Bool { burst.contains(now) || rng.nextUnit() < 0.05 }
        var now: UInt64 = 0
        var typed = 0, down = true
        var sentPackets = 0
        let text = Array("the quick brown fox jumps over the lazy dog 0123456789")
        while now < 120_000_000_000 {
            // Viewer: a key event every 25 ms while typing (1000 keystrokes = 2000 events in 50 s, 20 keys/s), a pointer move every 30 ms.
            var fresh = false
            if typed < 2000, now % 25_000_000 == 0 {
                let ch0 = text[(typed / 2) % text.count]
                let m: ControlMessage = .key(.init(keyCode: UInt16(typed % 50), down: down, isRepeat: false, modifiers: down ? 0 : 1 << 17, characters: down ? String(ch0) : nil))
                let seq = ch.enqueue(m, now: now)
                XCTAssertNotEqual(seq, 0, "queue cap hit at event \(typed)")
                if case .key(var k) = m { k.seq = seq; expected.append(.key(k)) }
                typed += 1; down.toggle(); fresh = true
            }
            if now % 30_000_000 == 0 { ch.pointer(x: Double(now % 1_000_000_000) / 1e9, y: 0.5); fresh = true }
            let out = fresh ? ch.packet(now: now) : ch.tick(now: now)
            if let out { sentPackets += 1; if !lossy(now) { toHost.append((now + oneWay, out)) } }
            // Host: deliver what has arrived, apply, ack.
            for (i, pkt) in toHost.enumerated().reversed() where pkt.at <= now {
                toHost.remove(at: i)
                guard let p = InputPacket.decode(pkt.data) else { XCTFail("undecodable packet"); continue }
                let r = rx.receive(p)
                for m in r.apply { if case .mouseMove = m { pointerApplied += 1 } else { applied.append(m) } }
                if !lossy(now) { toViewer.append((now + oneWay, r.ack.encode())) }
            }
            for (i, a) in toViewer.enumerated().reversed() where a.at <= now {
                toViewer.remove(at: i)
                if let ack = InputAck.decode(a.data) { ch.ack(ack) }
            }
            now += 1_000_000
            if typed == 2000, ch.queuedEvents == 0, toHost.isEmpty, toViewer.isEmpty { break }
        }
        XCTAssertEqual(typed, 2000)
        XCTAssertEqual(applied.count, 2000, "every event applied exactly once")
        XCTAssertEqual(applied, expected, "same events, same order, no duplicates")
        XCTAssertEqual(ch.queuedEvents, 0, "the channel drained by itself after the burst")
        XCTAssertEqual(ch.droppedByCap, 0)
        XCTAssertGreaterThan(rx.duplicates, 0, "redundant copies arrived and were ignored")
        XCTAssertGreaterThan(pointerApplied, 100)
        XCTAssertLessThan(now, 52_000_000_000, "drained within 2 s of the last keystroke")
        // Redundancy costs packets, not correctness: well under one packet per event.
        XCTAssertLessThan(sentPackets, 2000 * 2)
    }

    func testChannelHoldsAfterLongGapUntilFlushOrDiscard() {
        var ch = InputChannel()
        let k = ControlMessage.key(.init(keyCode: 0, down: true, isRepeat: false, modifiers: 0, characters: "x"))
        ch.enqueue(k, now: 0)
        XCTAssertNotNil(ch.packet(now: 0))
        // The host never answers; after the hold threshold the channel stops sending discrete events.
        var now: UInt64 = 0
        var sawEvents = 0, sawEmpty = 0
        while now < 15_000_000_000 {
            if let d = ch.tick(now: now), let p = InputPacket.decode(d) { if p.events.isEmpty { sawEmpty += 1 } else { sawEvents += 1 } }
            now += 100_000_000
        }
        XCTAssertTrue(ch.held); XCTAssertGreaterThan(sawEvents, 0)
        XCTAssertEqual(ch.queuedEvents, 1)
        ch.enqueue(k, now: now)   // typed during the hold: queued, not sent
        XCTAssertEqual(ch.queuedEvents, 2)
        XCTAssertEqual(InputPacket.decode(ch.packet(now: now)!)!.events.count, 0, "held: pointer state only")
        ch.flush()
        XCTAssertEqual(InputPacket.decode(ch.packet(now: now)!)!.events.count, 2)
        ch.ack(.init(eventSeq: 2, pointerSeq: 0))
        XCTAssertEqual(ch.queuedEvents, 0); XCTAssertFalse(ch.held)
        // Discard drops the queue and the host sees a sequence jump, which it accepts.
        ch.enqueue(k, now: now); ch.enqueue(k, now: now)
        ch.discard()
        XCTAssertEqual(ch.queuedEvents, 0)
        let seq = ch.enqueue(k, now: now)
        var rx = InputReceiver()
        _ = rx.receive(.init(pointer: nil, events: [.init(seq: 1, message: k)]))
        let r = rx.receive(InputPacket.decode(ch.packet(now: now)!)!)
        XCTAssertEqual(r.apply.count, 1); XCTAssertEqual(r.ack.eventSeq, seq)
    }

    func testQueueCapDropsAndCounts() {
        var ch = InputChannel(); ch.tuning.maxQueued = 10
        let k = ControlMessage.key(.init(keyCode: 0, down: true, isRepeat: false, modifiers: 0, characters: "x"))
        for _ in 0..<15 { ch.enqueue(k, now: 0) }
        XCTAssertEqual(ch.queuedEvents, 10); XCTAssertEqual(ch.droppedByCap, 5)
        // A packet never exceeds the datagram size even with many queued events.
        var big = InputChannel(); big.tuning.maxQueued = 1000
        for _ in 0..<500 { big.enqueue(.key(.init(keyCode: 0, down: true, isRepeat: false, modifiers: 0, characters: "abcdefgh")), now: 0) }
        let d = big.packet(now: 0)!
        XCTAssertLessThanOrEqual(d.count, 1200)
        XCTAssertLessThanOrEqual(InputPacket.decode(d)!.events.count, big.tuning.maxEventsPerPacket)
        XCTAssertGreaterThan(InputPacket.decode(d)!.events.count, 30)
    }

    func testLossInjectorRatesAndBursts() {
        let off = LossInjector(environment: [:])
        XCTAssertFalse(off.isActive); XCTAssertFalse(off.shouldDrop())
        let l = LossInjector(environment: ["MIRAGE_TEST_LOSS": "0.05", "MIRAGE_TEST_SEED": "1"])
        var drops = 0
        for _ in 0..<20000 where l.shouldDrop(now: 0) { drops += 1 }
        XCTAssertEqual(Double(drops) / 20000, 0.05, accuracy: 0.01)
        let b = LossInjector(environment: ["MIRAGE_TEST_BURST_MS": "2000", "MIRAGE_TEST_BURST_EVERY_S": "10"])
        let t0 = Clock.nowNanos()
        XCTAssertFalse(b.inBurst(now: t0 + 1_000_000_000))
        XCTAssertTrue(b.inBurst(now: t0 + 10_500_000_000))
        XCTAssertFalse(b.inBurst(now: t0 + 12_500_000_000))
        XCTAssertTrue(b.inBurst(now: t0 + 21_000_000_000))
    }
}

final class BestEffortPointerTests: XCTestCase {
    /// A disconnect with scrolls, clicks and keys queued: only the keys are held and counted; stale scrolls and presses go.
    func testOnlyKeystrokesAreHeldAndCountedAcrossAGap() {
        var ch = InputChannel()
        let t0: UInt64 = 1_000_000_000
        for i in 0..<300 { ch.enqueue(.scroll(.init(x: 0.5, y: 0.5, dx: 0, dy: -3, precise: true, modifiers: 0)), now: t0 + UInt64(i) * 1_000_000) }
        ch.enqueue(.mouseButton(.init(button: 0, down: true, x: 0.5, y: 0.5, clickCount: 1, modifiers: 0)), now: t0)
        ch.enqueue(.mouseButton(.init(button: 0, down: false, x: 0.5, y: 0.5, clickCount: 1, modifiers: 0)), now: t0)
        ch.enqueue(.key(.init(keyCode: 0, down: true, isRepeat: false, modifiers: 0, characters: "a")), now: t0)
        ch.enqueue(.key(.init(keyCode: 0, down: false, isRepeat: false, modifiers: 0, characters: "a")), now: t0)
        XCTAssertEqual(ch.queuedKeystrokes, 1)
        _ = ch.tick(now: t0 + 11_000_000_000)   // 11 s without an answer
        XCTAssertTrue(ch.held, "a keystroke waits for the user's decision")
        XCTAssertEqual(ch.queuedKeystrokes, 1, "the banner counts the one keystroke, not 300 scrolls")
        XCTAssertEqual(ch.queuedEvents, 3, "the button release and the key down/up stay; scrolls and the press are gone")
        XCTAssertEqual(ch.droppedStale, 301)
        // Pointer events alone never hold the channel.
        var p = InputChannel()
        p.enqueue(.scroll(.init(x: 0.5, y: 0.5, dx: 0, dy: -3, precise: true, modifiers: 0)), now: t0)
        _ = p.tick(now: t0 + 11_000_000_000)
        XCTAssertFalse(p.held); XCTAssertEqual(p.queuedEvents, 0)
    }
}
