import XCTest
@testable import MirageCore

/// A still screen with a refinement backlog on a shaped link: no video, so the only congestion evidence is what the viewer
/// acks. phrz on 4G (2026-10-21, 06:05Z): the target climbed 3 → 28 → 50 Mbps with srtt flat and queue 0 ms, tiles went
/// out at 10–13 Mbps, and parts of windows stayed lossy for good.
final class DeliveryRateTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    struct Result { var targets: [Int]; var deliveredKbps: Double; var maxAckDelayMs: Double; var maxInflight: Int; var backlogLeft: Int }

    /// The host's loop: tile messages (20 KB blocks, 1.2 KB tiles) from a backlog, within the tile budget (90 % of the
    /// target, a token bucket) and the in-flight cap, on one reliable channel through a ShaperCore downlink; each ack
    /// returns after the uplink delay; a delay probe every second; `tick` every second.
    private func stillScreen(link: NetworkThrottle, seconds: Int, backlogBytes: Int) -> Result {
        var rc = RateController(initialKbps: BitratePolicy.startKbps, maxKbps: 50_000, nativePixels: 3200 * 1800)
        let up = link.direction(upstream: true)
        var downLink = ShaperCore(parameters: link.direction(upstream: false))
        enum Event { case ack(sent: UInt64, received: UInt64, bytes: Int), probe(sent: UInt64, received: UInt64) }
        var events: [(at: UInt64, e: Event)] = []
        var targets: [Int] = []
        var backlog = backlogBytes, inflight = 0, maxInflight = 0, delivered = 0, maxDelay = 0.0
        var tokens = 0.0
        let start: UInt64 = 10_000 * ms
        var deliveredTail = 0
        for t in 0..<(seconds * 1000) {
            let now = start + UInt64(t) * ms
            let budget = Double(rc.budget(videoActive: false).tileKbps) * 1000 / 8
            tokens = min(budget * 0.5, tokens + budget / 1000)
            // A trickle of small changes all the time (a clock, a caret), and the backlog as blocks.
            var sends: [Int] = []
            if t % 200 == 0 { sends.append(1200) }
            // The host holding back for its own reasons for the first 3 s (the fresh picture's ladder waits for acks).
            let held = t < 3000 && t % 1000 > 100
            if backlog > 0, tokens > 0, !held, inflight >= rc.inflightCapBytes { rc.noteCapped(now: now) }
            while backlog > 0, tokens > 0, !held, inflight < rc.inflightCapBytes {
                let b = min(20_000, backlog); backlog -= b; tokens -= Double(b); inflight += b; sends.append(b)
            }
            if backlog == 0, tokens > 0, !held, inflight < rc.inflightCapBytes { rc.noteIdle(now: now) }
            for b in sends {
                if b == 1200 { inflight += b }
                maxInflight = max(maxInflight, inflight)
                let a = downLink.admit(bytes: b, channel: 1, reliable: true, now: now)!
                // Acks ride the uplink: they come back in clumps (up to 300 ms late), the receive time is what they carry.
                let clump = UInt64((Int(a / ms) % 300)) * ms
                events.append((a + up.oneWayNanos + clump, .ack(sent: now, received: a, bytes: b)))
            }
            if t % 1000 == 0 {
                if let a = downLink.admit(bytes: 32, channel: 0, reliable: false, now: now) { events.append((a + up.oneWayNanos, .probe(sent: now, received: a))) }
                rc.tick(now: now)
                targets.append(rc.targetKbps)
            }
            events.sort { $0.at < $1.at }
            while let e = events.first, e.at <= now {
                events.removeFirst()
                switch e.e {
                case .ack(let sent, let received, let bytes):
                    inflight -= bytes; delivered += bytes
                    if t >= (seconds - 20) * 1000 { deliveredTail += bytes }
                    maxDelay = max(maxDelay, Double(now - sent) / 1e6)
                    rc.streamAcked(bytes: bytes, receivedNanos: received, now: now)
                case .probe(let sent, let received): rc.probeSample(sentNanos: sent, receivedNanos: received, now: now)
                }
            }
            // An endless backlog for the tail: the link must stay busy.
            if backlogBytes < 0 { backlog = 1 << 30 }
        }
        _ = delivered
        return Result(targets: targets, deliveredKbps: Double(deliveredTail) * 8 / 20 / 1000, maxAckDelayMs: maxDelay, maxInflight: maxInflight, backlogLeft: backlog)
    }

    private func check(_ link: NetworkThrottle, file: StaticString = #filePath, line: UInt = #line) {
        let rate = Double(link.downKbps)
        // Saturating: an endless backlog. The target settles near the link (not the 50 Mbps cap), the link stays busy, and
        // acks never wait anywhere near a block's 10 s timeout (the resend that would follow).
        let busy = stillScreen(link: link, seconds: 60, backlogBytes: -1)
        let tail = busy.targets.suffix(20)
        print("\(link.name): targets \(busy.targets) delivered \(Int(busy.deliveredKbps)) kbps, max ack delay \(Int(busy.maxAckDelayMs)) ms, max inflight \(busy.maxInflight)")
        XCTAssertLessThanOrEqual(Double(tail.max() ?? 0), rate * 1.35, "\(link.name): target near the link, not far above it (\(busy.targets))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(Double(tail.min() ?? 0), rate * 0.5, "\(link.name): target not collapsed (\(busy.targets))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(busy.deliveredKbps, rate * 0.6, "\(link.name): the link is used (\(Int(busy.deliveredKbps)) kbps)", file: file, line: line)
        XCTAssertLessThan(busy.maxAckDelayMs, 5_000, "\(link.name): no ack near the block timeout", file: file, line: line)
        // A finite backlog (a fresh picture's worth, 3 MB) drains.
        let fresh = stillScreen(link: link, seconds: 90, backlogBytes: 3_000_000)
        XCTAssertEqual(fresh.backlogLeft, 0, "\(link.name): the backlog drains", file: file, line: line)
    }

    func testFast4GStillScreenSettlesNearTheLinkAndDrains() { check(.fast4G) }
    func testJapanBusStillScreenSettlesNearTheLinkAndDrains() { check(.japanBus4G) }
    func testSlow4GStillScreen() { check(.slow4G) }

    func testInflightCapIsTwiceTheBDP() {
        var rc = RateController(initialKbps: 800, maxKbps: 50_000, nativePixels: 3200 * 1800)
        XCTAssertEqual(rc.inflightCapBytes, 64_000, "no estimate yet")
        rc.probeSample(sentNanos: 0, receivedNanos: 0, now: 200 * ms)
        var now: UInt64 = 1_000 * ms
        for _ in 0..<200 { rc.streamAcked(bytes: 10_000, now: now); now += 10 * ms }   // 8 Mbps
        XCTAssertEqual(Double(rc.deliveryKbps), 8_000, accuracy: 800)
        XCTAssertEqual(Double(rc.inflightCapBytes), (rc.inStartup ? 3 : 2) * 8_000_000 / 8 * 0.2, accuracy: 40_000, "2 × (3 × in startup) 1 MB/s × 200 ms")
    }

    /// M-FIVE: the connect probe seeds the target at 0.7 × the train's rate (not 800 kbps and a climb), under the cap.
    func testTheConnectProbeSeedsTheTarget() {
        var rc = RateController(initialKbps: 800, maxKbps: 50_000, nativePixels: 3200 * 1800)
        rc.seedFromProbe(kbps: 20_000)
        XCTAssertEqual(rc.targetKbps, 14_000)
        XCTAssertEqual(rc.deliveryKbps, 20_000)
        var capped = RateController(initialKbps: 800, maxKbps: 6_000, nativePixels: 3200 * 1800)
        capped.seedFromProbe(kbps: 20_000)
        XCTAssertEqual(capped.targetKbps, 6_000, "never above the cap")
        var slow = RateController(initialKbps: 800, maxKbps: 50_000, nativePixels: 3200 * 1800)
        slow.seedFromProbe(kbps: 600)
        XCTAssertEqual(slow.targetKbps, 800, "a slow probe does not lower the start (the controller does that from evidence)")
    }

    /// The probe reads the link from a burst's spacing, not the train's total time (which the congestion window stretches).
    func testTheTrainRateComesFromTheDensestBurst() {
        let ms: UInt64 = 1_000_000
        // 8.1 Mbps: a 1240-byte packet every ~1.22 ms; released in bursts of 10, an RTT (80 ms) apart.
        var r: [UInt64] = []
        for b in 0..<4 { for i in 0..<10 { r.append(UInt64(b) * 80 * ms + UInt64(Double(i) * 1.225 * 1e6)) } }
        let kbps = RateController.trainRate(r, packetBytes: 1240)!
        XCTAssertEqual(Double(kbps), 8_100, accuracy: 400, "the burst's rate, not 40 packets over ~251 ms (1.6 Mbps)")
        XCTAssertNil(RateController.trainRate([0, 10 * ms, 20 * ms, 30 * ms], packetBytes: 1240), "no burst: no estimate")
        let clump: [UInt64] = (0..<5).map { UInt64($0) * 20_000 } + (0..<5).map { 3 * ms + UInt64($0) * 20_000 }
        XCTAssertNil(RateController.trainRate(clump, packetBytes: 1240), "a clump stamped together is not a rate")
    }

    /// A fast, short-RTT link has no dense burst to read (the train arrives in a few receive batches): the whole train's
    /// dispersion is read instead, but only raises the target, held under the pre-estimate ceiling, and is never a delivery
    /// estimate or a saved peak (the 231 Mbps misread must not recur).
    func testTheWholeTrainOnlyRaisesTheTargetUnderTheCeiling() {
        let ms: UInt64 = 1_000_000
        // 20 Mbps: 40 packets of 1240 B in ~19.8 ms, stamped in batches of 8 over 5 ms apart (no 10-packet burst over 4 ms).
        let r: [UInt64] = (0..<40).map { i in UInt64(i / 8) * 5_500_000 + UInt64(i % 8) * 20_000 }
        XCTAssertNil(RateController.trainRate(r, packetBytes: 1240), "no dense burst")
        let whole = RateController.trainRateWhole(r, packetBytes: 1240)!
        XCTAssertGreaterThan(whole, 12_000, "the batch gaps only make it read low")
        XCTAssertNil(RateController.trainRateWhole(Array(r.prefix(10)), packetBytes: 1240), "too few packets")
        XCTAssertNil(RateController.trainRateWhole((0..<40).map { UInt64($0) * 50_000 }, packetBytes: 1240), "under 5 ms: a clump, not a rate")
        _ = ms
        var rc = RateController(initialKbps: 2_000, maxKbps: 50_000, nativePixels: 3200 * 1800)
        rc.seedTargetFromProbe(kbps: min(whole, 4 * 2_000))
        XCTAssertLessThanOrEqual(rc.targetKbps, 8_000, "held under 4 x the start")
        XCTAssertGreaterThan(rc.targetKbps, 2_000, "raised")
        XCTAssertEqual(rc.deliveryKbps, 0, "not a delivery estimate")
        XCTAssertEqual(rc.measuredPeakKbps, 0, "nothing a session would save")
        rc.seedTargetFromProbe(kbps: 500)
        XCTAssertGreaterThan(rc.targetKbps, 2_000, "never lowers")
    }

    /// Before delivery samples a fast probe reading raises the in-flight cap from 64 KB; a slow one changes nothing (it is not
    /// trusted downward); neither is delivery or a saved peak.
    func testTheProbeBoundsTheStartBeforeDelivery() {
        var slow = RateController(initialKbps: 2_000, maxKbps: 50_000, nativePixels: 3200 * 1800)
        XCTAssertEqual(slow.deliveryCeilingKbps, 8_000)
        XCTAssertEqual(slow.inflightCapBytes, 64_000)
        slow.seedTargetFromProbe(kbps: 621)
        XCTAssertEqual(slow.deliveryCeilingKbps, 8_000, "a low reading is not trusted downward (a train behind stage 1's traffic reads low)")
        XCTAssertLessThanOrEqual(slow.inflightCapBytes, 64_000 * 2, "but it does not raise the cap much either")
        XCTAssertLessThanOrEqual(slow.targetKbps, 2_000)
        var fast = RateController(initialKbps: 2_000, maxKbps: 50_000, nativePixels: 3200 * 1800)
        fast.seedTargetFromProbe(kbps: 8_000)
        XCTAssertEqual(fast.deliveryCeilingKbps, 8_000, "never above 4 x the start before delivery")
        XCTAssertGreaterThan(fast.inflightCapBytes, 64_000, "the cap follows the probe-allowed target")
        XCTAssertLessThanOrEqual(fast.inflightCapBytes, 2_000_000)
        XCTAssertEqual(fast.deliveryKbps, 0); XCTAssertEqual(fast.measuredPeakKbps, 0)
    }

    /// Careful resume: the last estimate on this network gives 0.75 × it at once, out of startup (1.1 × delivery from the
    /// first window of acks), so a worse network today is caught by the first measurement.
    func testCarefulResumeStartsAtThreeQuartersAndLeavesStartup() {
        var rc = RateController(initialKbps: 2_000, maxKbps: 50_000, nativePixels: 3200 * 1800)
        rc.resume(fromKbps: 18_000)
        XCTAssertEqual(rc.targetKbps, 13_500)
        XCTAssertFalse(rc.inStartup)
        XCTAssertEqual(rc.deliveryCeilingKbps, 19_800, "1.1 × the resumed estimate until acks measure the link")
    }

    /// The viewer reads datagrams in batches and stamps a batch with one time (the 231 Mbps misread of a 20 Mbps link).
    /// Whatever the batch size, the probe either reads nothing or reads within 2x of the truth; never 10x.
    func testBatchedArrivalsNeverReadTenTimesTheLink() {
        let spacing = 1.225e6   // 8.1 Mbps, 1240-byte packets
        for batch in 1...12 {
            for count in [16, 40] {
                // Packet i really arrives at i x spacing; the viewer stamps it when its batch is read (the batch's last packet).
                let r: [UInt64] = (0..<count).map { i in UInt64((Double((i / batch + 1) * batch - 1)) * spacing) }
                guard let kbps = RateController.trainRate(r, packetBytes: 1240) else { continue }
                XCTAssertLessThanOrEqual(Double(kbps), 8_100 * 2, "batch \(batch), \(count) packets: \(kbps) kbps")
                XCTAssertGreaterThanOrEqual(Double(kbps), 8_100 * 0.5, "batch \(batch), \(count) packets: \(kbps) kbps")
            }
        }
    }
}
