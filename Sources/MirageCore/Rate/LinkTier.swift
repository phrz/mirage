import Foundation

/// Link tiers (DESIGN §3.9): one code path, four operating points chosen by the rate
/// controller's own estimates with hysteresis. Everything tier-dependent reads `Policy`, so a
/// tier is a single enum value driving fps caps, ladder bounds, video on/off and tile palette
/// depth. M2 implements the Normal and Constrained behaviours; Local and Extreme policies are
/// defined here so the seam exists (Extreme runs video-minimal on the tiny rung; its paletted
/// tiles, text mode and FEC do not exist yet).
public enum LinkTier: Int, Codable, Sendable, CaseIterable {
    case local = 0, normal = 1, constrained = 2, extreme = 3

    public struct Policy: Equatable, Sendable {
        /// Capture/encode ceiling for video (and for lossless-only motion when video is off).
        public var maxVideoFPS: Int
        /// Resolution ladder bounds (indices into `RateController.scales`).
        public var minRung: Int, maxRung: Int
        public var videoEnabled: Bool
        /// Colours a lossless tile is quantised to before encoding; nil = exact.
        public var tilePaletteColours: Int?
        /// Fraction of the target that lossless refinement may use while video is active.
        public var tileShareWhileVideo: Double
    }

    public var policy: Policy {
        switch self {
        // maxRung always includes the tiny rung: every tier starts there (lossy-first) and climbs.
        case .local:       return Policy(maxVideoFPS: 60, minRung: 0, maxRung: RateController.tinyRung, videoEnabled: true, tilePaletteColours: nil, tileShareWhileVideo: 0.6)
        case .normal:      return Policy(maxVideoFPS: 30, minRung: 0, maxRung: RateController.tinyRung, videoEnabled: true, tilePaletteColours: nil, tileShareWhileVideo: 0.45)
        case .constrained: return Policy(maxVideoFPS: 30, minRung: 0, maxRung: RateController.tinyRung, videoEnabled: true, tilePaletteColours: nil, tileShareWhileVideo: 0.45)
        // Video-minimal, not video-off: keyframes and motion on the tiny rung at 5 fps (1–2 KB a frame).
        case .extreme:     return Policy(maxVideoFPS: 5, minRung: RateController.tinyRung, maxRung: RateController.tinyRung, videoEnabled: true, tilePaletteColours: 16, tileShareWhileVideo: 0.9)
        }
    }

    public var name: String { ["Local", "Normal", "Constrained", "Extreme"][rawValue] }

    /// Which tier the estimates call for, before hysteresis. `capacityKbps` 0 = unknown.
    public static func classify(capacityKbps: Int, rttMs: Double, lossPercent: Double) -> LinkTier {
        if capacityKbps > 0 && capacityKbps < 500 || rttMs > 400 || lossPercent > 2 { return .extreme }
        if capacityKbps > 0 && capacityKbps < 2000 || rttMs >= 100 { return .constrained }
        if capacityKbps > 50_000 && rttMs < 10 { return .local }
        return .normal
    }
}

/// Hysteresis around `LinkTier.classify`: a new tier has to be called for continuously for
/// `dwellNanos` (longer when moving to a *better* tier) before it is adopted, so the badge and
/// the policies never flap on one bad RTT sample.
public struct TierSelector: Equatable {
    public private(set) var tier: LinkTier
    private var candidate: LinkTier
    private var candidateSince: UInt64 = 0
    public var dwellNanosDown: UInt64 = 2_000_000_000   // to a worse tier
    public var dwellNanosUp: UInt64 = 10_000_000_000    // to a better tier

    public init(initial: LinkTier = .normal) { tier = initial; candidate = initial }

    @discardableResult
    public mutating func update(capacityKbps: Int, rttMs: Double, lossPercent: Double, now: UInt64) -> LinkTier {
        let wanted = LinkTier.classify(capacityKbps: capacityKbps, rttMs: rttMs, lossPercent: lossPercent)
        if wanted != candidate { candidate = wanted; candidateSince = now }
        guard candidate != tier else { return tier }
        let dwell = candidate.rawValue > tier.rawValue ? dwellNanosDown : dwellNanosUp
        if now &- candidateSince >= dwell { tier = candidate }
        return tier
    }
}
