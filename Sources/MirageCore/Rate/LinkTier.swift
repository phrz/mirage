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

    /// Which tier the estimates call for, before hysteresis. The rate proxy is the controller's
    /// delay-limited target (DESIGN §3.9 correction: packet dispersion reads the physical path, 20–100
    /// Mbps on a tailnet whose usable rate is ~1 Mbps); it only counts when the link, not the viewer's
    /// cap, is what holds the target down (`limitedByLink`). RTT is the windowed minimum. Loss needs
    /// enough samples to mean anything (the controller zeroes it below 30 frames). A long round trip alone is never
    /// Extreme: Extreme's policy lowers the picture (tiny rung, 5 fps, a fresh picture on entry), and a slow round trip is
    /// not a narrow link (phrz's is ~200 ms at several Mbps; a bufferbloat spike past 400 ms must not shrink his screen).
    /// Constrained by round trip stays: its policy is Normal's. Nor is loss alone Extreme: a lossy Wi-Fi hop with 20 Mbps
    /// behind it is common, and loss is the transport's to answer (redundancy, smaller in-flight), not the picture's.
    /// Extreme is a link-limited rate under 500 kbps, nothing else.
    public static func classify(rateKbps: Int, limitedByLink: Bool, rttMs: Double, lossPercent: Double) -> LinkTier {
        if limitedByLink && rateKbps < 500 { return .extreme }
        // A LAN (round trip under 20 ms, no loss) is Local from its first sample, whatever the startup target: a 13 ms link
        // read Constrained (the 2 Mbps start counted as "limited by the link") and became Local only at +14 s, with video
        // on the lowest rungs meanwhile (phrz's LAN session, 2026-10-25 11:49Z: "worse than prior art").
        if rttMs < 20 && lossPercent < 1 { return .local }
        if (limitedByLink && rateKbps < 2000) || rttMs >= 100 { return .constrained }
        if rttMs < 10 && (!limitedByLink || rateKbps > 50_000) { return .local }
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
    /// To Local (min RTT under 20 ms, no loss) mid-session: 1 s. A phone's connect probe read 74 ms (iOS Wi-Fi power save
    /// until traffic flows) on a path that pinged 4 ms a minute later (2026-10-25): the LAN shows once data flows.
    public var dwellNanosUpLocal: UInt64 = 1_000_000_000
    public var dwellNanosExtreme: UInt64 = 10_000_000_000  // into Extreme

    public init(initial: LinkTier = .normal) { tier = initial; candidate = initial }
    /// The first measured classification is taken at once (no dwell): the initial tier is a guess, not a measurement.
    private var measured = false
    public mutating func adoptFirst(rateKbps: Int, limitedByLink: Bool, rttMs: Double, lossPercent: Double, now: UInt64) {
        guard !measured else { return }
        measured = true
        tier = LinkTier.classify(rateKbps: rateKbps, limitedByLink: limitedByLink, rttMs: rttMs, lossPercent: lossPercent); candidate = tier; candidateSince = now
    }

    /// A measurement that settles the tier outright (the connect probe found a LAN): no dwell, whatever was adopted before.
    public mutating func adopt(_ t: LinkTier, now: UInt64) {
        measured = true; tier = t; candidate = t; candidateSince = now
    }

    @discardableResult
    public mutating func update(rateKbps: Int, limitedByLink: Bool, rttMs: Double, lossPercent: Double, now: UInt64) -> LinkTier {
        let wanted = LinkTier.classify(rateKbps: rateKbps, limitedByLink: limitedByLink, rttMs: rttMs, lossPercent: lossPercent)
        if wanted != candidate { candidate = wanted; candidateSince = now }
        guard candidate != tier else { return tier }
        // Extreme (video on the tiny rung, a whole fresh picture on entry) needs its condition for 10 s: a target that dips
        // under our own burst (a window resent after a move) took a Constrained session to Extreme and back within 15 s,
        // restarting the whole picture each time (mac-daddy, 2026-10-20).
        let dwell = candidate.rawValue > tier.rawValue ? (candidate == .extreme ? max(dwellNanosDown, dwellNanosExtreme) : dwellNanosDown) : (candidate == .local ? dwellNanosUpLocal : dwellNanosUp)
        if now &- candidateSince >= dwell { tier = candidate }
        return tier
    }
}
