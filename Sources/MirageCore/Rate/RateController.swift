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
    /// Frames acked and frames given up (the loss parity and NACKs could not repair), over the last 10 s.
    private var frameEvents: [(nanos: UInt64, lost: Bool)] = []
    private mutating func noteFrame(lost: Bool, now: UInt64) {
        frameEvents.append((now, lost))
        frameEvents.removeAll { now &- $0.nanos > 10_000_000_000 }
    }
    /// Fragment loss reported by the viewer (fragments that needed parity or a NACK), over a 10 s window.
    private var fragmentSamples: [(nanos: UInt64, lost: Int, total: Int)] = []
    public private(set) var fragmentLossPercent = 0.0
    /// Frames given up (unrecovered loss). Needs a few dozen frames before it means anything (one lost
    /// keyframe out of two is not "50 % loss").
    /// Residual loss over the last 10 s: only with at least 3 frames given up among at least 50. One stray frame of the few a
    /// mostly still desktop sends (small animations go as tiles) held 2.5 % for over a minute and the tier at Extreme on
    /// mac-daddy, a link whose 2–3 % raw loss parity and NACKs repaired.
    public var frameLossPercent: Double {
        let lost = frameEvents.reduce(0) { $0 + ($1.lost ? 1 : 0) }
        guard lost >= 3, frameEvents.count >= 50 else { return 0 }
        return Double(lost) * 100 / Double(frameEvents.count)
    }
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
        self.initialKbps = max(1, min(initialKbps, maxKbps))
        // Startup: a target under the ceiling (an automatic-bitrate stream starts at 800 under a 50 Mbps ceiling) probes up
        // multiplicatively (×`probeIncrease` per RTT once the queue has been clear for `probeAfterNanos`) until the link's
        // delay or loss pushes back, as after any decrease; the additive 8 %/s alone took a minute to reach a LAN's rate.
        probing = targetKbps < maxKbps
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
        if recovered { noteFrame(lost: false, now: now); return }
        ackedBytes.append((now, bytes)); ackedBytes.removeAll { now &- $0.nanos > 1_000_000_000 }
        if let rtt = rttNanos {
            // srtt only: the minimum RTT (the tier's input) comes from the delay probes. A video frame's RTT is measured
            // from its pacer's estimated end, which under heavy pacing reads low; one such sample took the minimum under
            // 100 ms and the tier to Normal at srtt 949 ms and 8 % loss (phrz's session, 22:47:45Z).
            srttNanos = srttNanos * 0.8 + rtt * 0.2
        }
        // One-way delay proxy (receiver clock − host clock); its minimum is the base, the rest is queue. Weighted by the bytes
        // the frame carried (full weight at 16 KB): a trickle of tiny frames (an animated icon) barely moves the estimate.
        videoSamples.append((now, bytes)); videoSamples.removeAll { now &- $0.nanos > 1_000_000_000 }
        noteOWD(Double(lastReceived) - Double(sentNanos), now: now, source: "video", weight: min(1, max(0.05, Double(bytes) / 16_000)))
        // Delivery rate from the datagram train.
        if fragments >= tuning.minTrainFragments, lastReceived > firstReceived, lastReceived - firstReceived >= tuning.minTrainNanos {
            let kbps = Double(bytes) * 8 / (Double(lastReceived - firstReceived) / 1e9) / 1000
            rateSamples.append((now, kbps))
        }
        noteFrame(lost: false, now: now)
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
        probeRTT = probeRTT.isNaN ? rtt : probeRTT * 0.5 + rtt * 0.5; lastProbeSampleNanos = now
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
            // No video for a second: the video queue estimate decays to zero and the target floats back toward the
            // ceiling (×1.25 per second), so the next motion starts near it. The ceiling includes what the link has
            // been seen to deliver (`deliveryCeilingKbps`): without it, a still screen's target climbed to the 50 Mbps
            // cap on phrz's 4G with no signal to stop it, and refinement queued far more than the link could carry.
            let dt = min(age - 1, 5)
            let factor = exp(-dt)
            owdEWMA = baseOWD + (owdEWMA - baseOWD) * factor
            queueMs = max(0, (owdEWMA - baseOWD) / 1e6)
            if age > 2 { lastSampleSource = "idle" }
            let ceiling = ceilingKbps()
            if targetKbps < ceiling, now &- lastIncreaseNanos >= 900_000_000 {
                targetKbps = min(ceiling, Int(Double(targetKbps) * tuning.probeIncrease)); lastIncreaseNanos = now
                if targetKbps >= ceiling { probing = false }
            }
            adjust(now: now)
        }
    }

    /// Windowed-minimum baseline (20 s, so a route change or an inflated opening is forgotten) and the
    /// smoothed one-way delay above it, which is the queue estimate.
    private mutating func noteOWD(_ owd: Double, now: UInt64, source: String, weight: Double = 1) {
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
        let alpha = min(0.95, max(0.1, 1 - exp(-dt / 0.3))) * weight
        owdEWMA = owdEWMA.isNaN ? owd : owdEWMA * (1 - alpha) + owd * alpha
        queueMs = max(0, (owdEWMA - baseOWD) / 1e6)
        lastSampleSource = source; lastSampleNanos = now
    }

    public mutating func lossDetected(now: UInt64) {
        noteFrame(lost: true, now: now)
        if Double(Clock.elapsed(since: lastDecreaseNanos, now: now)) > srttNanos {
            targetKbps = max(tuning.minKbps, Int(Double(targetKbps) * tuning.lossDecrease))
            lastDecreaseNanos = now; probing = true; underSince = 0; lastLinkDecreaseNanos = now; inStartup = false
        }
    }

    // Delay evidence (mac-daddy 2026-10-21: an animated Dock icon's video acks, ~1.5 KB frames a few times a second, read a
    // ~140 ms queue the probes did not see, and the target fell to 150 kbps, tier Extreme, with 0 frames lost).
    private var videoSamples: [(nanos: UInt64, bytes: Int)] = []
    private var probeRTT: Double = .nan
    private var lastProbeSampleNanos: UInt64 = 0
    /// When a decrease the link itself justified last happened (loss, or delay the probes confirm): only those count toward
    /// "limited by the link" for the tier.
    private var lastLinkDecreaseNanos: UInt64 = 0
    /// Enough video in the last second for its delay to push the target down: 5 samples and 24 KB.
    var videoDelayCredible: Bool { videoSamples.count >= 5 && videoSamples.reduce(0) { $0 + $1.bytes } >= 24_000 }
    /// The probes (a recent echo, within 3 s) see no queue: their RTT is within the overuse threshold of the minimum.
    func probesDisagree(now: UInt64) -> Bool {
        guard !probeRTT.isNaN, lastProbeSampleNanos > 0, now &- lastProbeSampleNanos < 3_000_000_000, minRTTNanos.isFinite else { return false }
        return (probeRTT - minRTTNanos) / 1e6 < tuning.overuseMs
    }

    /// The highest target the estimates allow: the cap, 0.7 × the video trains' capacity, and the delivery-rate ceiling.
    private func ceilingKbps() -> Int {
        let trains = capacityKbps > 0 ? min(maxKbps, max(tuning.minKbps, Int(Double(capacityKbps) * tuning.capacityFraction))) : maxKbps
        return max(tuning.minKbps, min(trains, deliveryCeilingKbps))
    }

    private mutating func adjust(now: UInt64) {
        let ceiling = ceilingKbps()
        ackedBytes.removeAll { now &- $0.nanos > 1_000_000_000 }
        let videoFlowing = recentVideoKbps * 5 >= targetKbps
        if queueMs > tuning.overuseMs, videoFlowing, videoDelayCredible {
            underSince = 0
            if Double(Clock.elapsed(since: lastDecreaseNanos, now: now)) > srttNanos {
                // Delay the probes do not see holds the target (no increase, no decrease) and is not "the link" for the tier.
                if !probesDisagree(now: now) {
                    targetKbps = max(tuning.minKbps, Int(Double(targetKbps) * tuning.decrease))
                    lastDecreaseNanos = now; probing = true; lastLinkDecreaseNanos = now
                }
            }
        } else if queueMs < tuning.underuseMs {
            if underSince == 0 { underSince = now }
            if probing, targetKbps < ceiling, Clock.elapsed(since: underSince, now: now) >= tuning.probeAfterNanos, Clock.elapsed(since: lastProbeNanos, now: now) >= max(UInt64(srttNanos), tuning.probeMinIntervalNanos) {
                // Recovery from a transient: the queue has been clear for a second, so climb back
                // multiplicatively, one step per RTT, until the ceiling (then the slow additive rule again).
                // Startup doubles per round trip (BBR-style, bounded by the delivery ceiling: 2 × what was delivered).
                targetKbps = min(ceiling, Int(Double(targetKbps) * (inStartup ? 2.0 : tuning.probeIncrease)))
                lastProbeNanos = now; lastIncreaseNanos = now
                if targetKbps >= ceiling, !inStartup { probing = false }
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
        // (In startup the delivery ceiling rises as acks show more: reaching it does not end the probe.)
        if targetKbps >= ceiling, !inStartup { probing = false }
        targetKbps = min(targetKbps, max(ceiling, tuning.minKbps))
        // The link, not the cap, is holding the target down when the target sits well under the cap
        // after a delay- or loss-driven decrease in the last few seconds.
        let limitedByLink = targetKbps < maxKbps * 8 / 10 && lastLinkDecreaseNanos > 0 && Clock.elapsed(since: lastLinkDecreaseNanos, now: now) < 5_000_000_000
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

    // MARK: Delivery rate (BBR-style, every byte the viewer acks)

    /// Video delay only signals congestion while video flows; a still screen sends tiles and blocks on reliable streams,
    /// whose queue the host cannot see (it is in QUIC's buffers and the path). So the controller also measures what the
    /// link delivers: bytes acked over the last max(1 s, 3 × srtt; shorter windows read the clumps of acks behind a retransmission as rate), every message (tiles, blocks, video frames). Over
    /// 10 s, its samples' max (startup) or 75th percentile (after) is the bottleneck rate; app-limited samples (the host had nothing to send, `noteIdle`)
    /// only raise it. The target stays at or under `deliveryGain` × that rate (2 in startup, until three rounds bring no
    /// 25 % growth, then 1.25), and the host keeps stream data in flight under `inflightCapBytes`.
    private var ackLog: [(nanos: UInt64, bytes: Int)] = []
    private var firstAckNanos: UInt64 = 0
    private var latestAckNanos: UInt64 = 0
    private var startupIdleRounds = 0
    private var deliverySamples: [(nanos: UInt64, kbps: Double)] = []
    /// The bottleneck rate estimate in kbit/s (0 until the first full window of acks).
    public private(set) var deliveryKbps = 0
    public private(set) var inStartup = true
    private var startupBestKbps = 0.0
    private var startupRoundStart: UInt64 = 0
    private var startupFlatRounds = 0
    private var lastDeliveryAdjust: UInt64 = 0
    /// 1.1 after startup: on mac-daddy's shaped Fast 4G the estimate itself read up to 1.19 × the link (the viewer's receive
    /// times clump too), and 1.25 × that put the target at 1.49 ×.
    public var deliveryGain: Double { inStartup ? 2.0 : (probeUpActive ? 1.25 : 1.1) }
    /// Ongoing probe-up (BBR's ProbeBW): every 6 s, for one round trip, the ceiling allows 1.25 × delivery, so bandwidth
    /// that came back after a dip is found again; the delivery estimate settles it either way.
    private var probeUpActive = false
    private var lastProbeUpNanos: UInt64 = 0
    /// Careful resume (the IETF draft's idea): start from this pairing's last estimate on this network, then verify.
    public mutating func resume(fromKbps k: Int) {
        guard k > 0 else { return }
        deliveryKbps = k
        targetKbps = min(maxKbps, max(tuning.minKbps, Int(Double(k) * 0.75)))
        inStartup = false   // the 1.1 × gain applies as soon as the first window of acks measures the link
    }
    private var deliveryWindowNanos: UInt64 { max(1_500_000_000, UInt64(4 * srttNanos)) }

    /// The delivery-rate ceiling on the target; before any estimate, 4 x the start (the doubling startup otherwise reached
    /// the 50 Mbps cap in ~150 ms on a 20 Mbps link, before a single window of acks).
    /// The connect probe's reading (burst or whole train), until delivery samples exist: it bounds the start both ways (the
    /// ceiling and the in-flight cap below), and is never saved or taken as delivery.
    public private(set) var probeKbps = 0
    public var deliveryCeilingKbps: Int {
        if deliveryKbps > 0 { return min(maxKbps, max(tuning.minKbps, Int(Double(deliveryKbps) * deliveryGain))) }
        // Before any delivery sample: 4 x the start. (Not lowered by the probe: sent behind stage 1's traffic, its train read
        // 878 kbps on a 20 Mbps link on mac-daddy, pinned the start at 2 Mbps and took crisp to 11.4 s. The in-flight cap
        // before delivery, 64 KB unless the probe allows more, keeps a slow link's queue short instead.)
        return min(maxKbps, max(tuning.minKbps, initialKbps * 4))
    }
    /// The highest delivery estimate measured from acks this session (never a seed): what careful resume may start from.
    public private(set) var measuredPeakKbps = 0
    private var initialKbps = 800
    /// Stream data the host may keep unacked: 2 × the bandwidth-delay product (delivery rate × min RTT), 3 × in startup, at
    /// least 32 KB, and 64 KB until there is an estimate. (At 2 × in startup, a round trip the link's queue inflates allowed
    /// ~25 % growth per window, which read as "no growth": startup ended at 1.4 Mbps of Fast 4G's 8.1 on mac-daddy.)
    public var inflightCapBytes: Int {
        guard deliveryKbps > 0 else {
            // Before delivery samples: 3 x (the target the probe allows) x srtt, from 64 KB (20 Mbps on mac-daddy: the fixed
            // 64 KB held a 5.6 Mbps target to ~3 Mbps for the first 1.9 s, and delivery then measured that).
            guard probeKbps > 0 else { return 64_000 }
            let rate = Double(min(targetKbps, probeKbps)) * 1000 / 8
            return min(2_000_000, max(64_000, Int(3 * rate * srttNanos / 1e9)))
        }
        let bdp = Double(deliveryKbps) * 1000 / 8 * minRttMs / 1000
        return max(32_000, Int((inStartup ? 3 : 2) * bdp))
    }

    private var lastIdleNanos: UInt64 = 0
    private var lastCappedNanos: UInt64 = 0
    /// The host held stream data back because `inflightCapBytes` was reached.
    public mutating func noteCapped(now: UInt64) { lastCappedNanos = now }
    /// The host had budget and room in flight but nothing to send (no backlog, no changes): acks soon after say what the
    /// host sent, not what the link can carry.
    public mutating func noteIdle(now: UInt64) { lastIdleNanos = now }
    /// The host had work queued but its own budget (the target's tokens) held it back: acks soon after say what the target
    /// allowed, not what the link carries.
    public mutating func noteBudgetLimited(now: UInt64) { lastBudgetLimitedNanos = now }
    /// The host's stream bytes in flight, sampled every tick (`linkBusy`: video is using the link meanwhile). A delivery
    /// window during which they stayed under half the in-flight cap most of the time says what the host sent, not what the
    /// link carries: app-limited, however the host got there. (Marking it only where refinement found nothing to do missed
    /// a stall elsewhere: on 20 Mbps one window of acks read 760 kbps and pulled the ceiling from 16 Mbps to 1.5.)
    public mutating func noteInflight(bytes: Int, linkBusy: Bool = false, now: UInt64) {
        inflightLog.append((now, !linkBusy && bytes * 2 < inflightCapBytes))
        let keep = deliveryWindowNanos + 2 * UInt64(srttNanos)
        if let f = inflightLog.first, now &- f.nanos > keep { inflightLog.removeAll { now &- $0.nanos > keep } }
    }
    private var inflightLog: [(nanos: UInt64, under: Bool)] = []
    /// Most of the window the acks at `now` answer (shifted back an RTT) had little in flight (at least 5 samples).
    private func underusedWindow(now: UInt64) -> Bool {
        let hi = now &- UInt64(srttNanos), lo = hi &- deliveryWindowNanos
        var n = 0, under = 0
        for s in inflightLog where s.nanos >= lo && s.nanos <= hi { n += 1; if s.under { under += 1 } }
        return n >= 5 && under * 2 > n
    }
    private var lastBudgetLimitedNanos: UInt64 = 0

    /// The connect-time probe (DESIGN M-FIVE): a packet train's delivery rate. The target starts at 0.7 × it (under the cap)
    /// instead of 800 kbps and a climb, and the delivery estimate starts there, so the first picture is sized for the link.
    public mutating func seedFromProbe(kbps: Int) {
        guard kbps > 0 else { return }
        probeKbps = max(probeKbps, kbps)
        deliveryKbps = max(deliveryKbps, kbps)
        targetKbps = min(maxKbps, max(targetKbps, max(tuning.minKbps, Int(Double(kbps) * tuning.capacityFraction))))
    }

    /// Raises the target only (never the delivery estimate, the ceiling or what a session saves): a weaker probe reading,
    /// held under the pre-estimate ceiling until delivery samples confirm the link.
    public mutating func seedTargetFromProbe(kbps: Int) {
        guard kbps > 0 else { return }
        probeKbps = max(probeKbps, kbps)
        targetKbps = min(deliveryCeilingKbps, max(targetKbps, max(tuning.minKbps, Int(Double(kbps) * tuning.capacityFraction))))
    }

    /// The whole train's dispersion (first to last arrival), when no burst is dense enough to read (a fast, short-RTT link:
    /// 40 packets of a 20 Mbps link arrive in ~20 ms, in receive batches; mac-daddy: "no burst to read" at every connect).
    /// At least 20 packets over at least 5 ms; any idle gap in the train only makes it read low.
    public static func trainRateWhole(_ received: [UInt64], packetBytes: Int) -> Int? {
        guard received.count >= 20, let first = received.first, let last = received.last, last > first else { return nil }
        let span = Double(last - first)
        guard span >= 5_000_000 else { return nil }
        return Int(Double((received.count - 1) * packetBytes) * 8 / (span / 1e9) / 1000)
    }

    /// The train's rate from its densest burst (packets with no gap over 5 ms, at least 4 of them, spanning 1 ms or more):
    /// the congestion window releases the train in bursts an RTT apart, and inside a burst the packets arrive at the link's
    /// rate. Nil without such a burst.
    public static func trainRate(_ received: [UInt64], packetBytes: Int) -> Int? {
        guard received.count >= 4 else { return nil }
        var best: Double = 0, start = 0
        for i in 1...received.count {
            if i == received.count || received[i] - received[i - 1] > 5_000_000 {
                let n = i - start, span = Double(received[i - 1] - received[start])
                // At least 10 packets over 4 ms: the viewer reads datagrams in batches, and a short clump stamped together read
                // a 20 Mbps link as 231 Mbps on mac-daddy.
                if n >= 10, span >= 4_000_000 { best = max(best, Double((n - 1) * packetBytes) * 8 / (span / 1e9) / 1000) }
                start = i
            }
        }
        return best > 0 ? Int(best) : nil
    }
    /// Bytes the viewer acked (a tile message, a block, a video frame). `receivedNanos`: when the viewer received them (its
    /// clock); the window is taken on those times when given, since acks come back over the uplink in clumps (Fast 4G's
    /// 1.35 Mbps up: an 8.1 Mbps link read 10 Mbps on the host's arrival times).
    public mutating func streamAcked(bytes: Int, receivedNanos: UInt64? = nil, now: UInt64) {
        guard bytes > 0 else { return }
        let t = receivedNanos ?? now
        if firstAckNanos == 0 || t < firstAckNanos { firstAckNanos = t }
        latestAckNanos = max(latestAckNanos, t)
        let w = deliveryWindowNanos
        ackLog.append((t, bytes))
        let edge = latestAckNanos &- w
        if let f = ackLog.first, f.nanos < edge { ackLog.removeAll { $0.nanos < edge } }
        // A full window of acks first: the opening burst of acks says nothing about the rate.
        guard latestAckNanos &- firstAckNanos >= w else { return }
        let acked = ackLog.reduce(0) { $0 + $1.bytes }
        let kbps = Double(acked) * 8 / (Double(w) / 1e9) / 1000
        // App-limited: the host ran out of things to send during the window these acks answer (shifted by an RTT). Held
        // back by the in-flight cap is not app-limited: that is the link's rate.
        let pathStressed = (!probeRTT.isNaN && minRTTNanos.isFinite && probeRTT > minRTTNanos * 1.25) || lossPercent > 1
        // Little in flight for most of the window counts too, unless the path itself says the link is the limit.
        let appLimited = (lastIdleNanos > 0 && now &- lastIdleNanos < w + UInt64(srttNanos)) || (!pathStressed && underusedWindow(now: now))
        // Held back by its own budget (tokens spent, work queued) counts as app-limited too: on 20 Mbps the fresh picture's
        // block estimates put the budget 426 KB in debt, sending stopped for 0.6 s, and that window's 1.5 Mbps replaced the
        // probe's 8 Mbps (ceiling 2.9 Mbps for 2 s). Not when the path says otherwise: a rising round trip (> 25 % over the
        // minimum) or loss caps the estimate whatever held the host back. Not an idle round for startup.
        let budgetLimited = !pathStressed && lastBudgetLimitedNanos > 0 && now &- lastBudgetLimitedNanos < w + UInt64(srttNanos)
        deliverySamples.removeAll { now &- $0.nanos > 10_000_000_000 }
        if !(appLimited || budgetLimited) || kbps > Double(deliveryKbps) { deliverySamples.append((now, kbps)) }
        // The windowed max (in startup) or the 75th percentile (after): after a retransmission the ordered stream lands in a
        // clump, also by receive time, and the max read 1.25 × a lossy 650 kbps link (Japan bus); the median lagged a ramp so
        // far that startup ended at a fifth of Fast 4G.
        if !deliverySamples.isEmpty {
            let sorted = deliverySamples.map(\.kbps).sorted()
            let i = inStartup ? sorted.count - 1 : min(sorted.count - 1, sorted.count * 3 / 4)
            deliveryKbps = max(1, Int(sorted[i]))
            measuredPeakKbps = max(measuredPeakKbps, deliveryKbps)
        }
        // Startup ends when three rounds bring less than 25 % growth. A round is one delivery window: the estimate cannot
        // grow faster than its window moves (rounds of one srtt ended startup within half a second on Fast 4G).
        if inStartup {
            if startupRoundStart == 0 { startupRoundStart = now }
            if now &- startupRoundStart >= w {
                startupRoundStart = now
                // A round counts as flat only if the in-flight cap held sending back during it (`noteCapped`): the link
                // had all it could take and did not deliver more. The host holding back for its own reasons (the fresh
                // picture's ladder waiting for acks) counted as flat and ended startup at 1.1 Mbps of Fast 4G's 8.1.
                let capped = lastCappedNanos > 0 && now &- lastCappedNanos < w
                if Double(deliveryKbps) >= startupBestKbps * 1.25 { startupBestKbps = Double(deliveryKbps); startupFlatRounds = 0; startupIdleRounds = 0 }
                else if capped { startupFlatRounds += 1; if startupFlatRounds >= 3 { inStartup = false } }
                // Nothing left to send for three windows (the backlog drained): no growth will be seen; startup ends there
                // too (it held the 2 × gain for good on a Fast 4G run, the target at 20 Mbps on an 8.1 Mbps link).
                else if appLimited { startupIdleRounds += 1; if startupIdleRounds >= 3 { inStartup = false } }
            }
        }
        // Startup ends on a rising round trip too (> 25 % over the minimum: a queue building).
        if inStartup, !probeRTT.isNaN, minRTTNanos.isFinite, probeRTT > minRTTNanos * 1.25, now &- firstAckNanos > 2 * UInt64(srttNanos) { inStartup = false }
        if !inStartup {
            if probeUpActive, now &- lastProbeUpNanos > max(UInt64(srttNanos), 250_000_000) { probeUpActive = false }
            if !probeUpActive, now &- lastProbeUpNanos > 6_000_000_000 { probeUpActive = true; lastProbeUpNanos = now }
        }
        if now &- lastDeliveryAdjust >= 100_000_000 {
            lastDeliveryAdjust = now
            if targetKbps > deliveryCeilingKbps { targetKbps = deliveryCeilingKbps }
            adjust(now: now)
        }
    }
}
