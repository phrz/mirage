import Foundation

/// A simulated link for testing (a developer setting, off by default): bandwidth each way, added round trip and random
/// loss, together, as Chrome DevTools' network throttling presets are one profile of bandwidth and latency. The viewer
/// picks it and sends it in its stream request; the host shapes its downstream (`LinkShaper`: send pacing to `downKbps`
/// behind a bounded queue, half the added RTT, the loss) and the viewer its upstream (input, acks, pings: `upKbps`, the
/// other half, the loss). Nothing tells the rate controller the profile: it sees the shaped link as a real one.
public struct NetworkThrottle: Codable, Equatable, Hashable, Sendable {
    /// Shown in the picker and the stats overlay ("Throttled: Slow 4G").
    public var name: String
    /// Host → viewer and viewer → host bandwidth in kbit/s (0 = not limited).
    public var downKbps: Int
    public var upKbps: Int
    /// Round trip added on top of the real one, split half each way.
    public var rttMs: Double
    /// Random loss each way, percent: datagrams are dropped, reliable messages wait one more round trip (a retransmit).
    public var lossPercent: Double

    public init(name: String, downKbps: Int, upKbps: Int, rttMs: Double, lossPercent: Double = 0) {
        self.name = name; self.downKbps = downKbps; self.upKbps = upKbps; self.rttMs = rttMs; self.lossPercent = lossPercent
    }

    /// Chrome DevTools' presets, with Chrome's own numbers (devtools-frontend, front_end/core/sdk/NetworkManager.ts:
    /// `Fast4GConditions`, `Slow4GConditions`, `Slow3GConditions`; download/upload there are bytes/s, latency ms):
    /// Fast 4G 9 Mbps × 0.9 down, 1.5 Mbps × 0.9 up, 60 ms × 2.75; Slow 4G (called "Fast 3G" before May 2024) 1.6 Mbps × 0.9
    /// down, 750 kbps × 0.9 up, 150 ms × 3.75; 3G (once "Slow 3G") 500 kbps × 0.8 each way, 400 ms × 5. Chrome adds the
    /// latency to every request, so it is a round trip here. No loss: Chrome's presets have none.
    public static let fast4G = NetworkThrottle(name: "Fast 4G", downKbps: 8100, upKbps: 1350, rttMs: 165)
    public static let slow4G = NetworkThrottle(name: "Slow 4G", downKbps: 1440, upKbps: 675, rttMs: 562.5)
    public static let threeG = NetworkThrottle(name: "3G", downKbps: 400, upKbps: 400, rttMs: 2000)
    /// experiments/linktraces/2026-10-17-japan-bus-4g (MacBook on a moving bus in rural Japan to mac-daddy in Dallas): the
    /// medians of its seven 1 MB scp probes (656 kbps down, 662 up), of 6098 ICMP RTTs at 5 Hz (419 ms; p10 399, p90 575)
    /// and its ICMP loss (0.85 %). Summary numbers; the trace itself replays with replay.sh (dummynet, sudo).
    public static let japanBus4G = NetworkThrottle(name: "Japan bus 4G", downKbps: 650, upKbps: 650, rttMs: 420, lossPercent: 0.85)
    /// DESIGN §3.9's Extreme tier: rural satellite or congested cellular.
    public static let extreme = NetworkThrottle(name: "Extreme", downKbps: 150, upKbps: 150, rttMs: 600, lossPercent: 1)
    public static let presets: [NetworkThrottle] = [fast4G, slow4G, threeG, japanBus4G, extreme]
    public static let customName = "Custom"

    /// One line for logs and the stats overlay.
    public var summary: String {
        func rate(_ k: Int) -> String { k <= 0 ? "∞" : k >= 1000 ? String(format: "%.3g Mbps", Double(k) / 1000) : "\(k) kbps" }
        return "\(rate(downKbps)) down, \(rate(upKbps)) up, +\(Int(rttMs.rounded())) ms" + (lossPercent > 0 ? String(format: ", %.3g %% loss", lossPercent) : "")
    }

    /// The shaper for one direction: the profile's rate that way, half its round trip, its loss.
    public func direction(upstream: Bool) -> LinkShaper.Parameters {
        LinkShaper.Parameters(rateKbps: max(0, upstream ? upKbps : downKbps), oneWayNanos: UInt64(max(0, min(10_000, rttMs)) * 500_000),
                              loss: max(0, min(50, lossPercent)) / 100)
    }
}

/// The viewer's bitrate cap and what the host makes of it. A viewer that knows automatic bitrate says so
/// (`StreamRequest.explicitBitrate`) and sends 0 for automatic or the person's cap. Older viewers always sent 800, their
/// compiled-in default rather than anyone's choice, so the host reads an unannounced 800 as automatic too (DESIGN §3.0:
/// the installed app gets the change with a host deploy). Automatic means the controller starts at `startKbps` and
/// probes up to whatever the link sustains, under the host's ceiling (`Tunables.Key.autoMaxKbps`).
public enum BitratePolicy {
    /// What viewers before automatic bitrate sent when nobody chose a cap.
    public static let legacyDefaultKbps = 800
    /// Where an automatic stream's controller starts (the old default: safe on the Japan link), probing up from there.
    public static let startKbps = 800
    public static let minimumCapKbps = 100

    /// Whether this request leaves the rate to the host.
    public static func isAutomatic(_ req: ControlMessage.StreamRequest) -> Bool {
        if req.bitrateKbps <= 0 { return true }
        return req.explicitBitrate != true && req.bitrateKbps == legacyDefaultKbps
    }
    /// The controller's ceiling for this request: the host's maximum when automatic, else the viewer's cap.
    public static func maxKbps(_ req: ControlMessage.StreamRequest, hostMaxKbps: Int) -> Int {
        isAutomatic(req) ? max(startKbps, hostMaxKbps) : max(minimumCapKbps, req.bitrateKbps)
    }
    /// The request as the streamer sees it: `bitrateKbps` is the ceiling (the streamer starts at min(ceiling, 800) and its
    /// controller probes up to the ceiling), announced, so resolving it again changes nothing.
    public static func resolved(_ req: ControlMessage.StreamRequest, hostMaxKbps: Int) -> ControlMessage.StreamRequest {
        var r = req
        r.bitrateKbps = maxKbps(req, hostMaxKbps: hostMaxKbps)
        r.explicitBitrate = true
        return r
    }
    /// For logs: "automatic (≤ 50000 kbps)" or "cap 2000 kbps".
    public static func describe(_ req: ControlMessage.StreamRequest, hostMaxKbps: Int) -> String {
        isAutomatic(req) ? "automatic (≤ \(maxKbps(req, hostMaxKbps: hostMaxKbps)) kbps)" : "cap \(maxKbps(req, hostMaxKbps: hostMaxKbps)) kbps"
    }
}

/// One direction of a simulated link: a bottleneck at `rateKbps` behind a bounded queue (`queueBytes`, dummynet's
/// `queue 50` of ~1250-byte packets), then a fixed one-way delay, and random loss.
/// - Datagrams join the bottleneck queue; one that finds it full is dropped (tail drop), others are lost at random.
/// - Reliable messages (QUIC streams) are never dropped: a lost packet costs one more round trip, and each reliable
///   channel stays in order (head-of-line blocking). Below the shaper QUIC sees a fast loopback, so its congestion control
///   cannot keep stream data out of this queue; the shaper does it instead: stream data waits in the *sender* and holds at
///   most half the bottleneck queue (`reliableShare`), as a congestion-controlled flow keeps a standing queue without
///   filling it. A datagram therefore queues behind at most that much stream data, not behind a whole fresh picture's
///   backlog (which dropped every video frame for seconds and read as 9 % loss on a Slow 4G profile).
/// Pure and clock-free, so it is testable; `LinkShaper` schedules what it decides.
public struct ShaperCore: Sendable {
    public var parameters: LinkShaper.Parameters
    /// When the bottleneck has sent everything admitted so far (stream data included).
    private var linkFreeAt: UInt64 = 0
    /// When the bottleneck has sent the datagrams admitted so far.
    private var datagramFreeAt: UInt64 = 0
    /// Last delivery time per reliable channel (ordering).
    private var lastDelivery: [Int: UInt64] = [:]
    private var rng: SplitMix64
    public private(set) var dropped = 0, droppedQueueFull = 0, delivered = 0
    /// The part of the bottleneck queue stream data may hold.
    public static let reliableShare = 0.5

    public init(parameters: LinkShaper.Parameters, seed: UInt64 = 0x5EED_1234_ABCD_0001) {
        self.parameters = parameters; rng = SplitMix64(seed: seed)
    }

    /// Bytes on the wire for a payload: QUIC/UDP/IP headers per ~1200-byte packet.
    public static func wireBytes(_ payload: Int) -> Int { payload + 40 * max(1, (payload + 1199) / 1200) }

    private func nanos(bytes: Int) -> UInt64 { UInt64(min(1e15, Double(bytes) * 8e6 / Double(parameters.rateKbps))) }   // bits / (kbit/s) × 1e6; ≤ 11 days
    private func bytes(nanos: UInt64) -> Int { Int(Double(nanos) * Double(parameters.rateKbps) / 8e6) }

    /// When a datagram sent at `now` would start on the wire: after the datagrams queued, and after the stream data that
    /// is in the bottleneck queue (at most its share; the rest still waits in the sender).
    private func datagramStart(now: UInt64) -> UInt64 {
        let streamCap = nanos(bytes: Int(Double(parameters.queueBytes) * Self.reliableShare))
        let streamAhead = linkFreeAt > now ? min(linkFreeAt - now, streamCap) : 0
        return max(now + streamAhead, datagramFreeAt)
    }

    /// The bottleneck queue a datagram sent at `now` would find, in bytes.
    public func queuedBytes(now: UInt64) -> Int {
        guard parameters.rateKbps > 0 else { return 0 }
        let s = datagramStart(now: now)
        return s > now ? bytes(nanos: s - now) : 0
    }

    /// Decides for one message of `bytes` sent at `now` on `channel`: when it arrives at the far end, or nil when it is lost.
    public mutating func admit(bytes: Int, channel: Int, reliable: Bool, now: UInt64) -> UInt64? {
        let p = parameters
        let wire = Self.wireBytes(bytes)
        if !reliable {
            if p.rateKbps > 0, queuedBytes(now: now) + wire > p.queueBytes { dropped += 1; droppedQueueFull += 1; return nil }
            if p.loss > 0, rng.nextUnit() < p.loss { dropped += 1; return nil }
        }
        var arrival: UInt64
        if p.rateKbps > 0 {
            let serialize = nanos(bytes: wire)
            if reliable {
                let start = max(now, linkFreeAt, datagramFreeAt)
                linkFreeAt = start + serialize
                arrival = linkFreeAt
            } else {
                let start = datagramStart(now: now)
                datagramFreeAt = start + serialize
                // Its slot is taken from the stream data still waiting in the sender (or it simply extends the link's work).
                linkFreeAt = linkFreeAt > start ? linkFreeAt + serialize : datagramFreeAt
                arrival = datagramFreeAt
            }
            arrival += p.oneWayNanos
        } else {
            arrival = now + p.oneWayNanos
        }
        if reliable {
            // A lost packet of the message is retransmitted after about a round trip.
            if p.loss > 0, rng.nextUnit() < min(0.9, p.loss * Double(max(1, (bytes + 1199) / 1200))) { arrival += 2 * p.oneWayNanos + 20_000_000 }
            if let last = lastDelivery[channel], arrival < last { arrival = last }
            lastDelivery[channel] = arrival
        }
        delivered += 1
        return arrival
    }
}

/// Schedules a `ShaperCore`'s decisions: each send runs at its arrival time, in order per channel. Thread-safe.
public final class LinkShaper: @unchecked Sendable {
    public struct Parameters: Equatable, Sendable {
        public var rateKbps: Int
        public var oneWayNanos: UInt64
        /// Probability 0…1.
        public var loss: Double
        /// The bottleneck's queue (dummynet's `queue 50` of ~1250-byte packets).
        public var queueBytes: Int
        public init(rateKbps: Int, oneWayNanos: UInt64, loss: Double, queueBytes: Int = 64_000) {
            self.rateKbps = rateKbps; self.oneWayNanos = oneWayNanos; self.loss = loss; self.queueBytes = queueBytes
        }
    }
    private let lock = NSLock()
    private var core: ShaperCore
    private let queue: DispatchQueue
    /// Pending sends per channel, in arrival order.
    private var pending: [Int: [(at: UInt64, run: () -> Void)]] = [:]
    public private(set) var profile: NetworkThrottle

    public init(profile: NetworkThrottle, upstream: Bool, label: String = "mirage.shaper") {
        self.profile = profile
        core = ShaperCore(parameters: profile.direction(upstream: upstream))
        queue = DispatchQueue(label: label, qos: .userInteractive)
    }
    /// A new profile on the same link (the queue already built drains as it was scheduled).
    public func update(_ profile: NetworkThrottle, upstream: Bool) {
        lock.lock(); self.profile = profile; core.parameters = profile.direction(upstream: upstream); lock.unlock()
    }
    public var counters: (delivered: Int, dropped: Int, queueFull: Int) { lock.lock(); defer { lock.unlock() }; return (core.delivered, core.dropped, core.droppedQueueFull) }

    /// Runs `send` when a message of `bytes` would arrive at the far end of the simulated link, or never (lost).
    /// The far end's own wire time is negligible here, so the real send happens at the simulated arrival.
    public func send(bytes: Int, channel: Int, reliable: Bool, _ send: @escaping () -> Void) {
        let now = Clock.nowNanos()
        lock.lock()
        guard let at = core.admit(bytes: bytes, channel: channel, reliable: reliable, now: now) else { lock.unlock(); return }
        pending[channel, default: []].append((at, send))
        lock.unlock()
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(at > now ? at - now : 0))) { [weak self] in self?.drain(channel) }
    }

    /// Everything on `channel` that is due, in order (a later timer may find its message already sent: nothing to do).
    private func drain(_ channel: Int) {
        let now = Clock.nowNanos()
        lock.lock()
        var due: [() -> Void] = []
        if var list = pending[channel] {
            var n = 0
            while n < list.count, list[n].at <= now + 1_000_000 { due.append(list[n].run); n += 1 }
            list.removeFirst(n); pending[channel] = list
        }
        lock.unlock()
        for f in due { f() }
    }

    /// Channels: one per stream or flow, so reliable streams keep their own order.
    public enum Channel { public static let datagrams = 0, control = 1, tiles = 2, fastTiles = 3 }
}
