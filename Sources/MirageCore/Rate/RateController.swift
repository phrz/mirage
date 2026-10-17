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
    /// Needs a few dozen frames before it means anything (one lost keyframe out of two is not "50 % loss").
    public var lossPercent: Double { ackedFrames + lostFrames < 30 ? 0 : Double(lostFrames) * 100 / Double(ackedFrames + lostFrames) }

    private var baseOWD: Double = .infinity       // min(receiverNanos − hostNanos), includes the clock offset
    private var baseOWDWindowStart: UInt64 = 0
    private var baseOWDCandidate: Double = .infinity
    private var owdEWMA: Double = .nan
    private var rateSamples: [(nanos: UInt64, kbps: Double)] = []
    private var lastDecreaseNanos: UInt64 = 0
    private var lastIncreaseNanos: UInt64 = 0
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

    /// One acked frame: when the host sent its first datagram, when the viewer saw the first and
    /// last datagram, how many datagrams, how many bytes.
    public mutating func frameAcked(sentNanos: UInt64, firstReceived: UInt64, lastReceived: UInt64, fragments: Int, bytes: Int, now: UInt64, rttNanos: Double?) {
        if let rtt = rttNanos {
            srttNanos = srttNanos * 0.8 + rtt * 0.2
            if minRTTWindowStart == 0 { minRTTWindowStart = now }
            minRTTCandidate = min(minRTTCandidate, rtt); minRTTNanos = min(minRTTNanos, rtt)
            if now - minRTTWindowStart > 30_000_000_000 { minRTTNanos = minRTTCandidate; minRTTCandidate = .infinity; minRTTWindowStart = now }
        }
        // One-way delay proxy (receiver clock − host clock); its minimum is the base, the rest is queue.
        let owd = Double(lastReceived) - Double(sentNanos)
        if baseOWDWindowStart == 0 { baseOWDWindowStart = now }
        baseOWDCandidate = min(baseOWDCandidate, owd)
        if owd < baseOWD { baseOWD = owd }
        if now - baseOWDWindowStart > 20_000_000_000 {   // base ages out every 20 s so a route change is tracked
            baseOWD = baseOWDCandidate; baseOWDCandidate = .infinity; baseOWDWindowStart = now
        }
        owdEWMA = owdEWMA.isNaN ? owd : owdEWMA * 0.7 + owd * 0.3
        queueMs = max(0, (owdEWMA - baseOWD) / 1e6)
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
    public mutating func delaySample(sentNanos: UInt64, receivedNanos: UInt64, now: UInt64) {
        let owd = Double(receivedNanos) - Double(sentNanos)
        if baseOWDWindowStart == 0 { baseOWDWindowStart = now }
        baseOWDCandidate = min(baseOWDCandidate, owd)
        if owd < baseOWD { baseOWD = owd }
        owdEWMA = owdEWMA.isNaN ? owd : owdEWMA * 0.7 + owd * 0.3
        queueMs = max(0, (owdEWMA - baseOWD) / 1e6)
        adjust(now: now)
    }

    public mutating func lossDetected(now: UInt64) {
        lostFrames += 1
        if Double(now - lastDecreaseNanos) > srttNanos {
            targetKbps = max(tuning.minKbps, Int(Double(targetKbps) * tuning.lossDecrease))
            lastDecreaseNanos = now
        }
    }

    private mutating func adjust(now: UInt64) {
        let ceiling = capacityKbps > 0 ? min(maxKbps, max(tuning.minKbps, Int(Double(capacityKbps) * tuning.capacityFraction))) : maxKbps
        if queueMs > tuning.overuseMs {
            if Double(now - lastDecreaseNanos) > srttNanos {
                targetKbps = max(tuning.minKbps, Int(Double(targetKbps) * tuning.decrease))
                lastDecreaseNanos = now
            }
        } else if queueMs < tuning.underuseMs, Double(now - lastDecreaseNanos) > 2 * srttNanos {
            if lastIncreaseNanos == 0 { lastIncreaseNanos = now }
            let dt = Double(now - lastIncreaseNanos) / 1e9
            if dt >= 0.1 {
                targetKbps = min(ceiling, targetKbps + max(10, Int(Double(targetKbps) * tuning.increasePerSecond * dt)))
                lastIncreaseNanos = now
            }
        }
        targetKbps = min(targetKbps, max(ceiling, tuning.minKbps))
        if ackedFrames + lostFrames > 200 { ackedFrames /= 2; lostFrames /= 2 }   // sliding loss window
        tiers.update(capacityKbps: capacityKbps, rttMs: minRttMs, lossPercent: lossPercent, now: now)
        updateRung(now: now)
    }

    /// Reports the frame rate video actually achieved over the last second while motion was active,
    /// against the frame rate wanted. A sustained shortfall (< 60 % for 2 s) drops a rung.
    public mutating func videoRate(achievedFPS: Double, wantedFPS: Double, active: Bool, now: UInt64) {
        self.achievedFPS = achievedFPS
        guard active, wantedFPS > 0 else { fpsShortfallSince = 0; return }
        if achievedFPS < 0.6 * wantedFPS {
            if fpsShortfallSince == 0 { fpsShortfallSince = now }
            if now - fpsShortfallSince > 2_000_000_000, rung < policy.maxRung, now - lastRungChange > 3_000_000_000 {
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
            if now - belowSince > tuning.downNanos { rung += 1; belowSince = 0; aboveSince = 0; lastRungChange = now }
        } else { belowSince = 0 }
        if rung > p.minRung {
            let up = Self.scales[rung - 1]
            if Double(targetKbps) > kpix * up * up * tuning.kbpsPerKpixelUp {
                if aboveSince == 0 { aboveSince = now }
                if now - aboveSince > tuning.upNanos { rung -= 1; aboveSince = 0; belowSince = 0; lastRungChange = now }
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
