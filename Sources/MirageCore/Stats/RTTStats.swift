import Foundation

/// Rolling RTT statistics with a terminal sparkline. Good enough for M0's
/// "RTT graph in the viewer"; a Swift Charts view can read the same samples later.
public struct RTTStats: Sendable {
    public private(set) var samples: [Double] = []   // milliseconds, most recent last
    public private(set) var sent: UInt64 = 0
    public private(set) var received: UInt64 = 0
    public let window: Int

    public init(window: Int = 120) { self.window = window }

    public mutating func recordSent() { sent += 1 }
    public mutating func record(rttMillis: Double) {
        received += 1
        samples.append(rttMillis)
        if samples.count > window { samples.removeFirst(samples.count - window) }
    }

    public var last: Double? { samples.last }
    public var min: Double? { samples.min() }
    public var max: Double? { samples.max() }
    public var mean: Double? { samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count) }
    public var p95: Double? {
        guard !samples.isEmpty else { return nil }
        let s = samples.sorted()
        return s[Swift.min(s.count - 1, Int(Double(s.count) * 0.95))]
    }
    /// Mean absolute successive difference, RFC 3550 style jitter.
    public var jitter: Double? {
        guard samples.count > 1 else { return nil }
        var acc = 0.0
        for i in 1..<samples.count { acc += abs(samples[i] - samples[i-1]) }
        return acc / Double(samples.count - 1)
    }
    public var lossPercent: Double {
        sent == 0 ? 0 : Double(sent - Swift.min(sent, received)) / Double(sent) * 100
    }

    public func sparkline(width: Int = 40) -> String {
        let bars: [Character] = ["▁","▂","▃","▄","▅","▆","▇","█"]
        let tail = samples.suffix(width)
        guard let hi = tail.max(), let lo = tail.min() else { return "" }
        let span = Swift.max(hi - lo, 1)
        return String(tail.map { v in bars[Int((v - lo) / span * 7)] })
    }

    public func summaryLine() -> String {
        func f(_ v: Double?) -> String { v.map { String(format: "%6.1f", $0) } ?? "   -  " }
        return "rtt last \(f(last)) ms  mean \(f(mean))  min \(f(min))  p95 \(f(p95))  jitter \(f(jitter))  loss \(String(format: "%4.1f", lossPercent))%  n=\(received)"
    }
}
