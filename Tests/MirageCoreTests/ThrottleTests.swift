import XCTest
@testable import MirageCore

/// Automatic bitrate (BitratePolicy: the old default read as automatic, the controller probing up from 800) and the
/// network throttle (NetworkThrottle's profiles, ShaperCore's rate, latency and loss, LinkShaper's scheduling), and the
/// wire fields that carry them.
final class ThrottleTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    // MARK: Default cap

    func testAnUnannouncedEightHundredIsTheOldDefaultAndMeansAutomatic() throws {
        // A viewer from before automatic bitrate: its request has no `explicitBitrate`.
        let old = try JSONDecoder().decode(ControlMessage.StreamRequest.self, from: Data(#"{"width":100,"height":50,"bitrateKbps":800,"maxFPS":30}"#.utf8))
        XCTAssertNil(old.explicitBitrate); XCTAssertNil(old.throttle)
        XCTAssertTrue(BitratePolicy.isAutomatic(old), "800 was the compiled-in default, nobody's choice")
        XCTAssertEqual(BitratePolicy.maxKbps(old, hostMaxKbps: 50_000), 50_000)
        // An older viewer started with another --bitrate chose it: a cap.
        var chosen = old; chosen.bitrateKbps = 2_000
        XCTAssertFalse(BitratePolicy.isAutomatic(chosen)); XCTAssertEqual(BitratePolicy.maxKbps(chosen, hostMaxKbps: 50_000), 2_000)
        // A newer viewer: 0 is automatic, anything else (800 included) is the person's cap.
        let auto = ControlMessage.StreamRequest(width: 100, height: 50, bitrateKbps: 0, explicitBitrate: true)
        XCTAssertTrue(BitratePolicy.isAutomatic(auto)); XCTAssertEqual(BitratePolicy.maxKbps(auto, hostMaxKbps: 30_000), 30_000)
        let cap800 = ControlMessage.StreamRequest(width: 100, height: 50, bitrateKbps: 800, explicitBitrate: true)
        XCTAssertFalse(BitratePolicy.isAutomatic(cap800), "a newer viewer's 800 is a choice")
        XCTAssertEqual(BitratePolicy.maxKbps(cap800, hostMaxKbps: 50_000), 800)
        XCTAssertEqual(BitratePolicy.maxKbps(.init(width: 1, height: 1, bitrateKbps: 20, explicitBitrate: true), hostMaxKbps: 50_000), BitratePolicy.minimumCapKbps)
        // Resolved once (what the streamer and a resumed session see), it resolves to itself.
        let r = BitratePolicy.resolved(old, hostMaxKbps: 50_000)
        XCTAssertEqual(r.bitrateKbps, 50_000); XCTAssertEqual(r.explicitBitrate, true)
        XCTAssertEqual(BitratePolicy.resolved(r, hostMaxKbps: 50_000), r)
        XCTAssertEqual(BitratePolicy.resolved(cap800, hostMaxKbps: 50_000).bitrateKbps, 800)
        // The host's ceiling is a host tunable.
        XCTAssertEqual(Tunables.defaults[.autoMaxKbps], 50_000)
        XCTAssertEqual(Tunables(values: ["autoMaxKbps": 10]).self[.autoMaxKbps], 1_000, "clamped")
    }

    func testRequestAndWelcomeEncodeTheNewFields() throws {
        let req = ControlMessage.StreamRequest(width: 1280, height: 720, bitrateKbps: 0, snapNative: true, tunablesVersion: 1, explicitBitrate: true, throttle: .slow4G)
        let framed = try Frame.encode(ControlMessage.streamRequest(req))
        XCTAssertEqual(try Frame.decode(ControlMessage.self, from: framed.dropFirst(4)), .streamRequest(req))
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(req), encoding: .utf8))
        for key in ["\"explicitBitrate\":true", "\"bitrateKbps\":0", "\"throttle\":{", "\"downKbps\":1440", "\"upKbps\":675", "\"rttMs\":562.5", "\"name\":\"Slow 4G\""] {
            XCTAssertTrue(json.contains(key), "\(key) in \(json)")
        }
        // No throttle: the key is absent, so an older host decodes the request as before.
        let plain = try XCTUnwrap(String(data: try JSONEncoder().encode(ControlMessage.StreamRequest(width: 1, height: 1, explicitBitrate: true)), encoding: .utf8))
        XCTAssertFalse(plain.contains("throttle"))
        let w = ControlMessage.Welcome(hostName: "h", sessionID: "s", hostBuild: "0.1 (1), built 2026-10-21 14:03Z")
        XCTAssertEqual(try Frame.decode(ControlMessage.self, from: try Frame.encode(ControlMessage.welcome(w)).dropFirst(4)), .welcome(w))
        let oldWelcome = try JSONDecoder().decode(ControlMessage.Welcome.self, from: Data(#"{"hostName":"h","sessionID":"s"}"#.utf8))
        XCTAssertNil(oldWelcome.hostBuild)
        XCTAssertFalse(BuildInfo.current.isEmpty)
    }

    func testChromePresetsAndTheJapanTrace() {
        // devtools-frontend NetworkManager.ts, bytes/s × 8 / 1000 and latency ms.
        XCTAssertEqual(NetworkThrottle.fast4G.downKbps, 9 * 1000 * 1000 / 8 * 9 / 10 * 8 / 1000)
        XCTAssertEqual(NetworkThrottle.fast4G.upKbps, 1350); XCTAssertEqual(NetworkThrottle.fast4G.rttMs, 60 * 2.75)
        XCTAssertEqual(NetworkThrottle.slow4G.downKbps, 1440); XCTAssertEqual(NetworkThrottle.slow4G.upKbps, 675); XCTAssertEqual(NetworkThrottle.slow4G.rttMs, 150 * 3.75)
        XCTAssertEqual(NetworkThrottle.threeG.downKbps, 400); XCTAssertEqual(NetworkThrottle.threeG.upKbps, 400); XCTAssertEqual(NetworkThrottle.threeG.rttMs, 400 * 5)
        XCTAssertEqual(NetworkThrottle.japanBus4G.rttMs, 420); XCTAssertEqual(NetworkThrottle.extreme.downKbps, 150); XCTAssertEqual(NetworkThrottle.extreme.rttMs, 600)
        XCTAssertEqual(Set(NetworkThrottle.presets.map(\.name)).count, NetworkThrottle.presets.count, "names identify presets")
        let d = NetworkThrottle.slow4G.direction(upstream: false), u = NetworkThrottle.slow4G.direction(upstream: true)
        XCTAssertEqual(d.rateKbps, 1440); XCTAssertEqual(u.rateKbps, 675)
        XCTAssertEqual(d.oneWayNanos + u.oneWayNanos, 562_500_000, "the added round trip, split half each way")
    }

    // MARK: Shaper

    func testShaperRate() {
        // 1000 kbps: 500 back-to-back 1200-byte datagrams (1240 bytes on the wire) take 500 × 1240 × 8 / 1000 kbps = 4.96 s.
        var core = ShaperCore(parameters: .init(rateKbps: 1000, oneWayNanos: 0, loss: 0, queueBytes: .max))
        var last: UInt64 = 0
        let t0: UInt64 = 1_000 * ms
        for _ in 0..<500 { last = core.admit(bytes: 1200, channel: 0, reliable: false, now: t0)! }
        XCTAssertEqual(Double(last - t0) / 1e9, 4.96, accuracy: 0.05)
        // Spaced sends below the rate are not delayed beyond their own serialization.
        var idle = ShaperCore(parameters: .init(rateKbps: 1000, oneWayNanos: 0, loss: 0))
        let a = idle.admit(bytes: 100, channel: 0, reliable: false, now: t0)!
        XCTAssertEqual(Double(a - t0) / 1e6, 140 * 8 / 1000.0, accuracy: 0.01, "140 bytes at 1000 kbps: 1.12 ms")
        // A bounded queue: a burst beyond 64 KB is tail-dropped (datagrams), so the controller sees loss as on a real link.
        var q = ShaperCore(parameters: .init(rateKbps: 1000, oneWayNanos: 0, loss: 0))
        var passed = 0
        for _ in 0..<200 { if q.admit(bytes: 1200, channel: 0, reliable: false, now: t0) != nil { passed += 1 } }
        XCTAssertEqual(passed, 64_000 / 1240, accuracy: 2)
        XCTAssertEqual(q.droppedQueueFull, 200 - passed)
        // Reliable messages are never dropped; they wait.
        for _ in 0..<50 { XCTAssertNotNil(q.admit(bytes: 1200, channel: 2, reliable: true, now: t0)) }
        // A stream's backlog (a fresh picture: 200 KB of tiles at once) waits in the sender, as under QUIC's congestion
        // control: a datagram behind it queues behind at most half the bottleneck queue (32 KB: 256 ms at 1000 kbps), and
        // the stream data after it waits for it.
        var s = ShaperCore(parameters: .init(rateKbps: 1000, oneWayNanos: 0, loss: 0))
        var lastTile: UInt64 = 0
        for _ in 0..<170 { lastTile = s.admit(bytes: 1200, channel: LinkShaper.Channel.tiles, reliable: true, now: t0)! }
        XCTAssertEqual(Double(lastTile - t0) / 1e9, 170 * 1240 * 8 / 1e6, accuracy: 0.01)
        let video = s.admit(bytes: 1200, channel: LinkShaper.Channel.datagrams, reliable: false, now: t0)
        XCTAssertNotNil(video, "not dropped behind the stream's backlog")
        XCTAssertEqual(Double(video! - t0) / 1e6, (32_000 + 1240) * 8 / 1000.0, accuracy: 3)
        let laterTile = s.admit(bytes: 1200, channel: LinkShaper.Channel.tiles, reliable: true, now: t0)!
        XCTAssertGreaterThan(laterTile, lastTile + 2 * 9_920_000 - 1_000, "the datagram's slot came out of the stream's time")
    }

    func testShaperLatencyAndLoss() {
        let t0: UInt64 = 1_000 * ms
        // Latency: a small message on an unlimited link arrives exactly one way later.
        var lat = ShaperCore(parameters: NetworkThrottle(name: "x", downKbps: 0, upKbps: 0, rttMs: 300).direction(upstream: false))
        XCTAssertEqual(lat.admit(bytes: 50, channel: 0, reliable: false, now: t0), t0 + 150 * ms)
        // Loss: 5 % of 20 000 datagrams, within tolerance; none of the reliable ones.
        var lossy = ShaperCore(parameters: .init(rateKbps: 0, oneWayNanos: 10 * ms, loss: 0.05))
        var lost = 0
        for i in 0..<20_000 { if lossy.admit(bytes: 200, channel: 0, reliable: false, now: t0 + UInt64(i) * ms) == nil { lost += 1 } }
        XCTAssertEqual(Double(lost) / 20_000, 0.05, accuracy: 0.008)
        // Reliable: a lost packet costs a round trip more, and the channel stays in order behind it.
        var arrivals: [UInt64] = []
        for i in 0..<2_000 { arrivals.append(lossy.admit(bytes: 200, channel: 1, reliable: true, now: t0 + UInt64(i) * ms)!) }
        XCTAssertEqual(arrivals, arrivals.sorted(), "in order")
        let late = zip(arrivals.indices, arrivals).filter { i, a in a > t0 + UInt64(i) * ms + 10 * ms }.count
        XCTAssertGreaterThan(late, 50, "some waited for a retransmit")
        XCTAssertEqual(lossy.dropped, lost, "only datagrams are dropped")
    }

    /// The scheduled shaper delivers at the simulated arrival time, in order per channel.
    func testLinkShaperDeliversLateAndInOrder() {
        let shaper = LinkShaper(profile: NetworkThrottle(name: "t", downKbps: 2000, upKbps: 2000, rttMs: 200), upstream: false)
        let done = expectation(description: "all delivered")
        done.expectedFulfillmentCount = 20
        let lock = NSLock()
        var got: [(Int, UInt64)] = []
        let start = Clock.nowNanos()
        for i in 0..<20 {
            shaper.send(bytes: 1200, channel: LinkShaper.Channel.tiles, reliable: true) {
                lock.lock(); got.append((i, Clock.nowNanos() - start)); lock.unlock(); done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(got.map(\.0), Array(0..<20), "in order")
        // 100 ms one way, then 20 × 1240 bytes at 2000 kbps (99 ms) for the last.
        XCTAssertEqual(Double(got.first!.1) / 1e6, 105, accuracy: 30)
        XCTAssertEqual(Double(got.last!.1) / 1e6, 199, accuracy: 40)
    }

    // MARK: The controller on a shaped link

    /// The host's loop over a ShaperCore link: video at the target rate (fragments back to back), acks back after the
    /// upstream delay, a delay probe every second. Returns the target each second.
    private func closedLoop(link: NetworkThrottle?, seconds: Int, maxKbps: Int = 50_000) -> [Int] {
        var rc = RateController(initialKbps: BitratePolicy.startKbps, maxKbps: maxKbps, nativePixels: 3200 * 1800)
        let down = link?.direction(upstream: false) ?? .init(rateKbps: 0, oneWayNanos: 1 * ms, loss: 0)
        let up = link?.direction(upstream: true) ?? .init(rateKbps: 0, oneWayNanos: 1 * ms, loss: 0)
        var downLink = ShaperCore(parameters: down)
        enum Event { case ack(sent: UInt64, first: UInt64, last: UInt64, fragments: Int, bytes: Int), lost, probe(sent: UInt64, received: UInt64) }
        var events: [(at: UInt64, e: Event)] = []
        var targets: [Int] = []
        let start: UInt64 = 10_000 * ms, fps = 30
        for t in 0..<(seconds * 1000) {
            let now = start + UInt64(t) * ms
            if t % (1000 / fps) == 0 {
                let bytes = max(1200, rc.targetKbps * 1000 / 8 / fps)
                let n = (bytes + 1199) / 1200
                var first: UInt64?, last: UInt64 = 0, dropped = false
                for _ in 0..<n { if let a = downLink.admit(bytes: 1200, channel: 0, reliable: false, now: now) { first = first ?? a; last = a } else { dropped = true } }
                if dropped || first == nil { events.append((last + up.oneWayNanos + 50 * ms, .lost)) }
                else { events.append((last + up.oneWayNanos, .ack(sent: now, first: first!, last: last, fragments: n, bytes: bytes))) }
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
                case .ack(let sent, let first, let last, let n, let bytes):
                    rc.frameAcked(sentNanos: sent, firstReceived: first, lastReceived: last, fragments: n, bytes: bytes, now: now, rttNanos: Double(now - sent))
                    rc.streamAcked(bytes: bytes, receivedNanos: last, now: now)   // as the host does for every acked frame
                case .lost: rc.lossDetected(now: now)
                case .probe(let sent, let received): rc.probeSample(sentNanos: sent, receivedNanos: received, now: now)
                }
            }
        }
        return targets
    }

    func testAutomaticRampsAboveTheOldCapOnAFastLink() {
        let targets = closedLoop(link: nil, seconds: 12)
        XCTAssertEqual(targets.first, 800)
        let at = targets.firstIndex { $0 >= 20_000 }
        XCTAssertNotNil(at, "reaches 20 Mbps (targets \(targets))")
        XCTAssertLessThanOrEqual(at ?? 99, 8, "within 8 s of the start (targets \(targets))")
        XCTAssertGreaterThanOrEqual(targets.last ?? 0, 40_000, "and the 50 Mbps ceiling soon after (targets \(targets))")
    }

    /// Startup grows the ceiling per few round trips, not per 1.5 s window: a fast link is reached within the connect's
    /// first seconds (20 Mbps crisp waited for a ramp that doubled once per 1.5 s).
    func testStartupReachesAFastLinkWithinSeconds() {
        let targets = closedLoop(link: nil, seconds: 6)
        let at = targets.firstIndex { $0 >= 16_000 }
        XCTAssertNotNil(at, "reaches 16 Mbps (targets \(targets))")
        XCTAssertLessThanOrEqual(at ?? 99, 3, "within 3 s (targets \(targets))")
    }

    func testTheControllerSeesAThrottledLinkAsARealOne() {
        // Slow 4G: 1440 kbps down behind a 64 KB queue, 562.5 ms added. Starting at 800 and probing up, the controller must
        // settle near the link (not at the 50 Mbps ceiling, not collapsed to its floor).
        let targets = closedLoop(link: .slow4G, seconds: 60)
        let tail = targets.suffix(30)
        let mean = Double(tail.reduce(0, +)) / Double(tail.count)
        XCTAssertLessThanOrEqual(tail.max() ?? 0, 1_600, "never far above the link's 1440 kbps (targets \(targets))")
        XCTAssertGreaterThan(mean, 450, "uses the link (targets \(targets))")
        // Extreme: 150 kbps, 600 ms, 1 % loss.
        let ext = closedLoop(link: .extreme, seconds: 60).suffix(30)
        XCTAssertLessThanOrEqual(ext.max() ?? 0, 400, "held near the 150 kbps link (targets \(Array(ext)))")
    }
}
