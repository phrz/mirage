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
        public var overuseMs = 60.0
        public var underuseMs = 25.0
        public var decrease = 0.85
        public var increasePerSecond = 0.08
        public var lossDecrease = 0.8
        /// Delivery-rate samples need at least this many datagrams and this much spread.
        public var minTrainFragments = 4
        public var minTrainNanos: UInt64 = 2_000_000
        /// Ladder: kbps the target must stay under (per native kilopixel × scale²) for `downNanos` to drop a rung,
        /// and over (for the rung above) for `upNanos` to climb.
        public var kbpsPerKpixelDown = 0.18
        public var kbpsPerKpixelUp = 0.30
        public var downNanos: UInt64 = 2_000_000_000
        public var upNanos: UInt64 = 5_000_000_000
        public init() {}
    }
    public static let scales: [Double] = [1.0, 0.75, 0.5, 0.375]

    public var tuning = Tuning()
    public private(set) var targetKbps: Int
    public var maxKbps: Int
    public private(set) var capacityKbps: Int = 0
    public private(set) var queueMs: Double = 0
    public private(set) var rung = 0
    public var scale: Double { Self.scales[rung] }
    public let nativePixels: Int

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

    public init(initialKbps: Int, maxKbps: Int, nativePixels: Int) {
        targetKbps = min(initialKbps, maxKbps); self.maxKbps = maxKbps; self.nativePixels = nativePixels
    }

    /// One acked frame: when the host sent its first datagram, when the viewer saw the first and
    /// last datagram, how many datagrams, how many bytes.
    public mutating func frameAcked(sentNanos: UInt64, firstReceived: UInt64, lastReceived: UInt64, fragments: Int, bytes: Int, now: UInt64, rttNanos: Double?) {
        if let rtt = rttNanos { srttNanos = srttNanos * 0.8 + rtt * 0.2 }
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
        rateSamples.removeAll { now - $0.nanos > 10_000_000_000 }
        if !rateSamples.isEmpty {
            // Windowed max over 10 s, trimmed: the 90th percentile is more robust to bursts than the max.
            let s = rateSamples.map(\.kbps).sorted()
            capacityKbps = Int(s[min(s.count - 1, Int(Double(s.count) * 0.9))])
        }
        adjust(now: now)
    }

    public mutating func lossDetected(now: UInt64) {
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
        updateRung(now: now)
    }

    private mutating func updateRung(now: UInt64) {
        let kpix = Double(nativePixels) / 1000
        let need = kpix * scale * scale * tuning.kbpsPerKpixelDown
        if Double(targetKbps) < need, rung < Self.scales.count - 1 {
            if belowSince == 0 { belowSince = now }
            if now - belowSince > tuning.downNanos { rung += 1; belowSince = 0; aboveSince = 0; lastRungChange = now }
        } else { belowSince = 0 }
        if rung > 0 {
            let up = Self.scales[rung - 1]
            if Double(targetKbps) > kpix * up * up * tuning.kbpsPerKpixelUp {
                if aboveSince == 0 { aboveSince = now }
                if now - aboveSince > tuning.upNanos { rung -= 1; aboveSince = 0; belowSince = 0; lastRungChange = now }
            } else { aboveSince = 0 }
        }
    }

    /// Byte budget split for the next second: tiles first (bounded so video keeps moving), video the rest.
    public struct Budget: Equatable { public var tileKbps: Int; public var videoKbps: Int }
    public func budget(videoActive: Bool) -> Budget {
        let tiles = videoActive ? Int(Double(targetKbps) * 0.45) : Int(Double(targetKbps) * 0.9)
        return Budget(tileKbps: tiles, videoKbps: max(100, targetKbps - (videoActive ? tiles : Int(Double(targetKbps) * 0.1))))
    }

    public var srttMs: Double { srttNanos / 1e6 }
    public var hasCapacityEstimate: Bool { capacityKbps > 0 }
}
