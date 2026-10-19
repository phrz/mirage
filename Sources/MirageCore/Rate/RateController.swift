import Foundation

/// GCC/BBR-lite sender-side rate controller (DESIGN §3.4). Inputs are the viewer's acks: per
/// frame, host send time vs receiver arrival time (one-way delay up to a constant clock offset)
/// and the arrival spread of the frame's datagrams (packet-train dispersion → delivery rate).
/// Output: a target bitrate, its split between tiles and video, and the resolution rung.
public struct RateController {
    public struct Tuning: Sendable {
        public var minKbps = 150
        /// Fraction of the estimated capacity to aim for.
        public var capacityFraction = 0.7
        /// Queuing delay (above the base one-way delay) that triggers a decrease / allows an increase.
        /// Measured on the Dallas→Japan tailnet: the EWMA sits ~30 ms above the windowed minimum even
        /// when the link is nearly idle (tile acks ride a reliable stream), so the dead band starts above that.
        public var overuseMs = 90.0
        public var underuseMs = 40.0
        public var decrease = 0.85
        public var increasePerSecond = 0.08
        public var lossDecrease = 0.8
        /// After a decrease, once the queue has been under `underuseMs` for this long, the target is
        /// re-probed toward the ceiling multiplicatively (×`probeIncrease` per RTT, at least every
        /// `probeMinIntervalNanos`) instead of crawling back at 8 %/s: a one-sample RTT spike on an
        /// otherwise idle link (mac-daddy, 812 ms once) must not cost 10 s of half rate.
        public var probeAfterNanos: UInt64 = 1_000_000_000
        public var probeIncrease = 1.25
        public var probeMinIntervalNanos: UInt64 = 250_000_000
        /// Delivery-rate samples need at least this many datagrams and this much spread.
        public var minTrainFragments = 3
        public var minTrainNanos: UInt64 = 2_000_000
        /// Ladder: kbps the target must stay under (per native kilopixel × scale²) for `downNanos` to drop a rung,
        /// and over (for the rung above) for `upNanos` to climb.
        public var kbpsPerKpixelDown = 0.18
        public var kbpsPerKpixelUp = 0.30
        public var downNanos: UInt64 = 2_000_000_000
        public var upNanos: UInt64 = 5_000_000_000
        public init() {}
    }
    /// Resolution ladder. The last rung is the "tiny" one (1/8 of native, ~400×225 on a 3200-px host):
    /// every stream starts there so the first picture is one small keyframe within well under a
    /// second, and the Extreme tier lives there (DESIGN §3.3 lossy-first, §3.9 video-minimal).
    public static let scales: [Double] = [1.0, 0.75, 0.5, 0.375, 0.125]
    public static var tinyRung: Int { scales.count - 1 }

    public var tuning = Tuning()
    public private(set) var targetKbps: Int
    public var maxKbps: Int
    public private(set) var capacityKbps: Int = 0
    public private(set) var queueMs: Double = 0
    /// Which sample last moved the queue estimate ("video", "tile", "probe") and when; the stats line
    /// prints both so a frozen or starved estimate is visible from the field.
    public private(set) var lastSampleSource = "none"
    public private(set) var lastSampleNanos: UInt64 = 0
    public private(set) var rung = 0
    public var scale: Double { Self.scales[rung] }
    public let nativePixels: Int
    /// Link tier (DESIGN §3.9) from the controller's own estimates, with hysteresis; `policy` is what the host applies.
    public private(set) var tiers = TierSelector(initial: .constrained)
    /// Windowed minimum RTT: the tier must not react to queues we built ourselves.
    private var minRTTNanos: Double = .infinity
    private var minRTTCandidate: Double = .infinity
    private var minRTTWindowStart: UInt64 = 0
    public var minRttMs: Double { minRTTNanos.isFinite ? minRTTNanos / 1e6 : srttNanos / 1e6 }
    public var tier: LinkTier { tiers.tier }
    public var policy: LinkTier.Policy { tier.policy }
    private var ackedFrames = 0, lostFrames = 0
    /// Fragment loss reported by the viewer (fragments that needed parity or a NACK), over a 10 s window.
    private var fragmentSamples: [(nanos: UInt64, lost: Int, total: Int)] = []
    public private(set) var fragmentLossPercent = 0.0
    /// Frames given up (unrecovered loss). Needs a few dozen frames before it means anything (one lost
    /// keyframe out of two is not "50 % loss").
    public var frameLossPercent: Double { ackedFrames + lostFrames < 30 ? 0 : Double(lostFrames) * 100 / Double(ackedFrames + lostFrames) }
    /// The higher of the two, for display. The tier (§3.9: "> 2 % loss → Extreme") is driven by the loss the
    /// recovery layer could *not* hide (`frameLossPercent`): 5 % raw loss that parity and NACKs repair at
    /// 30 fps is not an Extreme link. The raw fragment rate sizes the parity groups instead.
    public var lossPercent: Double { max(fragmentLossPercent, frameLossPercent) }

    /// One acked frame's fragment accounting: `lost` of `total` did not arrive first time.
    public mutating func fragmentLoss(lost: Int, total: Int, now: UInt64) {
        guard total > 0 else { return }
        fragmentSamples.append((now, lost, total))
        fragmentSamples.removeAll { now - $0.nanos > 10_000_000_000 }
        let t = fragmentSamples.reduce(0) { $0 + $1.total }, l = fragmentSamples.reduce(0) { $0 + $1.lost }
        fragmentLossPercent = t >= 50 ? Double(l) * 100 / Double(t) : 0
    }
    /// Parity group size for the measured loss: one parity datagram per 8 fragments normally, per 4 above 2 %.
    public var parityGroupSize: Int { fragmentLossPercent > 2 ? 4 : 8 }

    private var baseOWD: Double = .infinity       // min(receiverNanos − hostNanos), includes the clock offset
    private var baseOWDWindowStart: UInt64 = 0
    private var baseOWDCandidate: Double = .infinity
    private var owdEWMA: Double = .nan
    private var rateSamples: [(nanos: UInt64, kbps: Double)] = []
    private var lastDecreaseNanos: UInt64 = 0
    private var lastIncreaseNanos: UInt64 = 0
    /// Post-decrease recovery: re-probing toward the ceiling once the queue has cleared.
    private var probing = false
    private var underSince: UInt64 = 0
    private var lastProbeNanos: UInt64 = 0
    private var srttNanos: Double = 250_000_000
    private var belowSince: UInt64 = 0, aboveSince: UInt64 = 0
    private var lastRungChange: UInt64 = 0
    /// Achieved vs wanted video frame rate while motion is active (review §2.2: density alone never
    /// engaged the ladder on full-screen motion; 4 fps at 800 kbps was the result).
    private var fpsShortfallSince: UInt64 = 0
    public private(set) var achievedFPS = 0.0

    public init(initialKbps: Int, maxKbps: Int, nativePixels: Int) {
        targetKbps = min(initialKbps, maxKbps); self.maxKbps = maxKbps; self.nativePixels = nativePixels
        // Lossy-first: start on the tiny rung whatever the target, so the first picture is one small
        // keyframe; the ladder climbs from there with its hysteresis as the target allows.
        rung = Self.tinyRung
    }

    /// One rung up, now (the fresh-picture climb drives this as each step is acked).
    public mutating func climbOneRung(now: UInt64) {
        if rung > policy.minRung { rung -= 1; belowSince = 0; aboveSince = 0; lastRungChange = now }
    }

    /// Lossy-first for a recovery or a newly visible picture: back to the tiny rung now, then climb again.
    public mutating func dropToTinyRung(now: UInt64) {
        rung = Self.tinyRung; belowSince = 0; aboveSince = 0; lastRungChange = now
    }

    /// Video bytes acked in the last second (delay-driven back-off applies only while video actually
    /// flows at ≥ 20 % of the target: an idle picture's stray sample must not halve the rate).
    private var ackedBytes: [(nanos: UInt64, bytes: Int)] = []
    public var recentVideoKbps: Int {
        ackedBytes.reduce(0) { $0 + $1.bytes } * 8 / 1000
    }

    /// One acked frame: when the host sent its first datagram, when the viewer saw the first and
    /// last datagram, how many datagrams, how many bytes.
    /// `recovered`: the frame needed parity or a NACK, so its arrival time says nothing about the path's
    /// queue (a NACK round trip is not queuing delay); it counts as acked and nothing else.
    public mutating func frameAcked(sentNanos: UInt64, firstReceived: UInt64, lastReceived: UInt64, fragments: Int, bytes: Int, now: UInt64, rttNanos: Double?, recovered: Bool = false) {
        if recovered { ackedFrames += 1; return }
        ackedBytes.append((now, bytes)); ackedBytes.removeAll { now &- $0.nanos > 1_000_000_000 }
        if let rtt = rttNanos {
            // srtt only: the minimum RTT (the tier's input) comes from the delay probes. A video frame's RTT is measured
            // from its pacer's estimated end, which under heavy pacing reads low; one such sample took the minimum under
            // 100 ms and the tier to Normal at srtt 949 ms and 8 % loss (phrz's session, 22:47:45Z).
            srttNanos = srttNanos * 0.8 + rtt * 0.2
        }
        // One-way delay proxy (receiver clock − host clock); its minimum is the base, the rest is queue.
        noteOWD(Double(lastReceived) - Double(sentNanos), now: now, source: "video")
        // Delivery rate from the datagram train.
        if fragments >= tuning.minTrainFragments, lastReceived > firstReceived, lastReceived - firstReceived >= tuning.minTrainNanos {
            let kbps = Double(bytes) * 8 / (Double(lastReceived - firstReceived) / 1e9) / 1000
            rateSamples.append((now, kbps))
        }
        ackedFrames += 1
        rateSamples.removeAll { now - $0.nanos > 10_000_000_000 }
        if !rateSamples.isEmpty {
            // Windowed max over 10 s, trimmed: the 90th percentile is more robust to bursts than the max.
            let s = rateSamples.map(\.kbps).sorted()
            capacityKbps = Int(s[min(s.count - 1, Int(Double(s.count) * 0.9))])
        }
        adjust(now: now)
    }

    /// A delay-only sample (tile-stream ack): updates the queue estimate without a rate sample.
    /// A reliable-stream (tile) message's delay, host enqueue → viewer apply. Not a path-delay sample:
    /// it measures head-of-line waiting on our own stream (a small tile queued behind a 30 KB
    /// refinement block waits that block's 70–90 ms of serialization at 3.5 Mbps) and QUIC's own send
    /// buffering, which read as a constant 85 ms "queue" on an idle mac-daddy link whatever the tile
    /// size. Path delay comes from the probe and video samples only; this is kept for accounting
    /// (`tileDelayMs`, the stream's backlog as the viewer experiences it).
    public mutating func delaySample(sentNanos: UInt64, receivedNanos: UInt64, bytes: Int = 0, now: UInt64) {
        let owd = Double(receivedNanos) - Double(sentNanos)
        if tileOWDMin.isInfinite || owd < tileOWDMin { tileOWDMin = owd }
        tileOWDEWMA = tileOWDEWMA.isNaN ? owd : tileOWDEWMA * 0.7 + owd * 0.3
        tileDelayMs = max(0, (tileOWDEWMA - tileOWDMin) / 1e6)
    }
    private var tileOWDMin: Double = .infinity
    private var tileOWDEWMA: Double = .nan
    /// Tile-stream backlog above its own minimum (diagnostic; not an input to the controller).
    public private(set) var tileDelayMs = 0.0

    /// A delay probe's echo: the host sent a 32-byte datagram at `sentNanos` (host clock), the viewer
    /// stamped it `receivedNanos` (its clock) and sent it straight back, arriving `now`. The host sends
    /// one every second unconditionally (0.3 kbps); it is the srtt / min-RTT source when video is idle.
    public mutating func probeSample(sentNanos: UInt64, receivedNanos: UInt64, now: UInt64) {
        // RTT and min-RTT only (mac-daddy, 2026-10-17 night: the probe datagram itself queues in the
        // host's QUIC send path behind refinement blocks, so its one-way delay read 91–98 ms of our own
        // buffering on an idle link and no baseline could tell). Path delay comes from video acks alone.
        let rtt = Double(now &- sentNanos)
        srttNanos = srttNanos * 0.8 + rtt * 0.2
        if minRTTWindowStart == 0 { minRTTWindowStart = now }
        minRTTCandidate = min(minRTTCandidate, rtt); minRTTNanos = min(minRTTNanos, rtt)
        if Clock.elapsed(since: minRTTWindowStart, now: now) > 30_000_000_000 { minRTTNanos = minRTTCandidate; minRTTCandidate = .infinity; minRTTWindowStart = now }
        _ = receivedNanos
    }

    /// Nanoseconds since the last delay sample of any kind (0 = none yet).
    public func sampleAgeNanos(now: UInt64) -> UInt64 { lastSampleNanos == 0 ? 0 : now &- lastSampleNanos }

    /// Time-driven (once a second): a queue estimate that no sample has refreshed for over a second
    /// decays toward zero with a 1 s time constant instead of holding; an idle link has no queue, and
    /// holding the last (possibly inflated) reading made the controller act on stale data for as long
    /// as the screen stayed still.
    public mutating func tick(now: UInt64) {
        guard lastSampleNanos > 0, !owdEWMA.isNaN, baseOWD.isFinite else { return }
        let age = Double(now &- lastSampleNanos) / 1e9
        if age > 1 {
            // No video for a second: you cannot congest a link you are not sending video on, and the
            // reliable streams are bounded by their own budget. The estimate decays to zero and the
            // target floats back toward the cap (×1.25 per second), so the next motion starts near it.
            let dt = min(age - 1, 5)
            let factor = exp(-dt)
            owdEWMA = baseOWD + (owdEWMA - baseOWD) * factor
            queueMs = max(0, (owdEWMA - baseOWD) / 1e6)
            if age > 2 { lastSampleSource = "idle" }
            let ceiling = capacityKbps > 0 ? min(maxKbps, max(tuning.minKbps, Int(Double(capacityKbps) * tuning.capacityFraction))) : maxKbps
            if targetKbps < ceiling, now &- lastIncreaseNanos >= 900_000_000 {
                targetKbps = min(ceiling, Int(Double(targetKbps) * tuning.probeIncrease)); lastIncreaseNanos = now
                if targetKbps >= ceiling { probing = false }
            }
            adjust(now: now)
        }
    }

    /// Windowed-minimum baseline (20 s, so a route change or an inflated opening is forgotten) and the
    /// smoothed one-way delay above it, which is the queue estimate.
    private mutating func noteOWD(_ owd: Double, now: UInt64, source: String) {
        if baseOWDWindowStart == 0 { baseOWDWindowStart = now }
        baseOWDCandidate = min(baseOWDCandidate, owd)
        if owd < baseOWD { baseOWD = owd }
        if Clock.elapsed(since: baseOWDWindowStart, now: now) > 20_000_000_000 {
            baseOWD = baseOWDCandidate; baseOWDCandidate = .infinity; baseOWDWindowStart = now
        }
        // Smoothing with a ~300 ms time constant, so the weight of a sample follows the time since the
        // last one: 30 fps video samples smooth over ~10 frames, a once-a-second probe on an idle link
        // replaces the estimate almost entirely (sparse samples must not take four seconds to converge).
        let dt = lastSampleNanos > 0 ? Double(now &- lastSampleNanos) / 1e9 : 1
        let alpha = min(0.95, max(0.1, 1 - exp(-dt / 0.3)))
        owdEWMA = owdEWMA.isNaN ? owd : owdEWMA * (1 - alpha) + owd * alpha
        queueMs = max(0, (owdEWMA - baseOWD) / 1e6)
        lastSampleSource = source; lastSampleNanos = now
    }

    public mutating func lossDetected(now: UInt64) {
        lostFrames += 1
        if Double(Clock.elapsed(since: lastDecreaseNanos, now: now)) > srttNanos {
            targetKbps = max(tuning.minKbps, Int(Double(targetKbps) * tuning.lossDecrease))
            lastDecreaseNanos = now; probing = true; underSince = 0
        }
    }

    private mutating func adjust(now: UInt64) {
        let ceiling = capacityKbps > 0 ? min(maxKbps, max(tuning.minKbps, Int(Double(capacityKbps) * tuning.capacityFraction))) : maxKbps
        ackedBytes.removeAll { now &- $0.nanos > 1_000_000_000 }
        let videoFlowing = recentVideoKbps * 5 >= targetKbps
        if queueMs > tuning.overuseMs, videoFlowing {
            underSince = 0
            if Double(Clock.elapsed(since: lastDecreaseNanos, now: now)) > srttNanos {
                targetKbps = max(tuning.minKbps, Int(Double(targetKbps) * tuning.decrease))
                lastDecreaseNanos = now; probing = true
            }
        } else if queueMs < tuning.underuseMs {
            if underSince == 0 { underSince = now }
            if probing, targetKbps < ceiling, Clock.elapsed(since: underSince, now: now) >= tuning.probeAfterNanos, Clock.elapsed(since: lastProbeNanos, now: now) >= max(UInt64(srttNanos), tuning.probeMinIntervalNanos) {
                // Recovery from a transient: the queue has been clear for a second, so climb back
                // multiplicatively, one step per RTT, until the ceiling (then the slow additive rule again).
                targetKbps = min(ceiling, Int(Double(targetKbps) * tuning.probeIncrease))
                lastProbeNanos = now; lastIncreaseNanos = now
                if targetKbps >= ceiling { probing = false }
            } else if Double(Clock.elapsed(since: lastDecreaseNanos, now: now)) > 2 * srttNanos {
                if lastIncreaseNanos == 0 { lastIncreaseNanos = now }
                let dt = Double(Clock.elapsed(since: lastIncreaseNanos, now: now)) / 1e9
                if dt >= 0.1 {
                    targetKbps = min(ceiling, targetKbps + max(10, Int(Double(targetKbps) * tuning.increasePerSecond * dt)))
                    lastIncreaseNanos = now
                }
            }
        } else {
            underSince = 0
        }
        if targetKbps >= ceiling { probing = false }
        targetKbps = min(targetKbps, max(ceiling, tuning.minKbps))
        if ackedFrames + lostFrames > 200 { ackedFrames /= 2; lostFrames /= 2 }   // sliding loss window
        // The link, not the cap, is holding the target down when the target sits well under the cap
        // after a delay- or loss-driven decrease in the last few seconds.
        let limitedByLink = targetKbps < maxKbps * 8 / 10 && Clock.elapsed(since: lastDecreaseNanos, now: now) < 5_000_000_000
        tiers.update(rateKbps: targetKbps, limitedByLink: limitedByLink, rttMs: minRttMs, lossPercent: frameLossPercent, now: now)
        updateRung(now: now)
    }

    /// Reports the frame rate video actually achieved over the last second while motion was active,
    /// against the frame rate the host actually asked for (review H7: small regions are capped at 15 fps
    /// by the host itself, so the comparison must use that cap). A sustained shortfall (< 60 % for 2 s)
    /// drops a rung, but only when frames were held back for *budget* (`budgetLimited`), never when the
    /// interval gate or a quiet picture was the reason.
    public mutating func videoRate(achievedFPS: Double, wantedFPS: Double, active: Bool, budgetLimited: Bool = true, now: UInt64) {
        self.achievedFPS = achievedFPS
        guard active, wantedFPS > 0, budgetLimited else { fpsShortfallSince = 0; return }
        if achievedFPS < 0.6 * wantedFPS {
            if fpsShortfallSince == 0 { fpsShortfallSince = now }
            if Clock.elapsed(since: fpsShortfallSince, now: now) > 2_000_000_000, rung < policy.maxRung, Clock.elapsed(since: lastRungChange, now: now) > 3_000_000_000 {
                rung += 1; lastRungChange = now; fpsShortfallSince = 0; belowSince = 0; aboveSince = 0
            }
        } else { fpsShortfallSince = 0 }
    }

    private mutating func updateRung(now: UInt64) {
        let kpix = Double(nativePixels) / 1000
        let need = kpix * scale * scale * tuning.kbpsPerKpixelDown
        let p = policy
        if rung < p.minRung { rung = p.minRung; lastRungChange = now }
        if rung > p.maxRung { rung = p.maxRung; lastRungChange = now }
        if Double(targetKbps) < need, rung < p.maxRung {
            if belowSince == 0 { belowSince = now }
            if Clock.elapsed(since: belowSince, now: now) > tuning.downNanos { rung += 1; belowSince = 0; aboveSince = 0; lastRungChange = now }
        } else { belowSince = 0 }
        if rung > p.minRung {
            let up = Self.scales[rung - 1]
            if Double(targetKbps) > kpix * up * up * tuning.kbpsPerKpixelUp {
                if aboveSince == 0 { aboveSince = now }
                if Clock.elapsed(since: aboveSince, now: now) > tuning.upNanos { rung -= 1; aboveSince = 0; belowSince = 0; lastRungChange = now }
            } else { aboveSince = 0 }
        }
    }

    /// Byte budget split: tiles may take up to 45 % while video is active (90 % otherwise), and
    /// video gets whatever tiles are not actually using (`recentTileKbps`, smoothed by the caller).
    public struct Budget: Equatable {
        public var tileKbps: Int; public var videoKbps: Int
        public init(tileKbps: Int, videoKbps: Int) { self.tileKbps = tileKbps; self.videoKbps = videoKbps }
    }
    public func budget(videoActive: Bool, recentTileKbps: Int = 0) -> Budget {
        let tiles = videoActive ? Int(Double(targetKbps) * policy.tileShareWhileVideo) : Int(Double(targetKbps) * 0.9)
        let reserved = max(Int(Double(targetKbps) * 0.1), min(tiles, Int(Double(recentTileKbps) * 1.25)))
        return Budget(tileKbps: tiles, videoKbps: max(100, targetKbps - reserved))
    }

    public var srttMs: Double { srttNanos / 1e6 }
    public var hasCapacityEstimate: Bool { capacityKbps > 0 }
}
