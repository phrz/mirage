import Foundation

/// Numbers the viewer uses for its local behaviour (gesture thresholds, prediction, fades), sent by the host (DESIGN §3.0:
/// the host is the product; the viewer renders and predicts within host-given bounds). The host can retune them without
/// an app update. The viewer keeps the compiled-in defaults below, ignores keys it does not know, and clamps every value
/// to its key's bounds (a bad host value cannot break the viewer).
///
/// Wire: `ControlMessage.tunables`, sent after `streamInfo` only to viewers that put `tunablesVersion` in their stream
/// request (an older viewer would fail to decode an unknown control message). Host side: the defaults, overridden by
/// `tunables.json` in the host's store directory (`{"pinchRatio": 0.2}`), read at every stream start.
public struct Tunables: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var version: Int
    public var values: [String: Double]

    public init(version: Int = Tunables.schemaVersion, values: [String: Double] = [:]) { self.version = version; self.values = values }

    public enum Key: String, CaseIterable, Sendable {
        // Two fingers: scroll unless they clearly pinch (TwoFingerClassifier).
        case pinchRatio, pinchDistance, twoFingerDominance, twoFingerScrollSlop, twoFingerWindowTime, twoFingerWindowTravel, twoFingerOnsetTravel
        // Direct touch (DirectTouch).
        case holdDelay, touchSlop, doubleClickInterval, doubleClickSlop, twoFingerTapMax, twoFingerTapWait
        // Zoom (ZoomViewport).
        case maxZoom
        // Prediction: a scroll's rubber-band lead, as a fraction of the scroll view (Predictor).
        case scrollLeadFraction
        // Fades (Compositor): a refinement tile's crossfade and a presentation level's commit, in ms.
        case crossfadeMs, levelFadeMs
        // Host only: a small animation (under 2 % of a layer: a bouncing Dock icon, a spinner) goes as lossy half-size tiles at
        // this rate and quality instead of video.
        case smallAnimationFps, smallAnimationQuality
        // Host only: 1 = the compositor model (DESIGN "The compositor model"): a desktop-only display layer, an overlay layer
        // for everything above the normal level, every normal window a layer. 0 = the seam design.
        case compositorModel
        // Host only: an automatic-bitrate stream's ceiling in kbit/s (BitratePolicy): the controller starts at 800 and probes
        // up to whatever the link sustains, never above this.
        case autoMaxKbps

        /// Compiled-in default and the bounds a host value is clamped to.
        public var spec: (default: Double, min: Double, max: Double) {
            switch self {
            case .pinchRatio: return (0.18, 0.02, 1)
            case .pinchDistance: return (40, 4, 400)
            case .twoFingerDominance: return (1.5, 1, 10)
            case .twoFingerScrollSlop: return (12, 1, 200)
            case .twoFingerWindowTime: return (0.15, 0.02, 2)
            case .twoFingerWindowTravel: return (60, 4, 600)
            case .twoFingerOnsetTravel: return (2, 0, 50)
            case .holdDelay: return (0.35, 0.1, 3)
            case .touchSlop: return (10, 1, 100)
            case .doubleClickInterval: return (0.45, 0.1, 2)
            case .doubleClickSlop: return (24, 1, 200)
            case .twoFingerTapMax: return (0.4, 0.05, 2)
            case .twoFingerTapWait: return (0.3, 0, 2)
            case .maxZoom: return (3, 1, 10)
            case .scrollLeadFraction: return (1.0 / 3, 0, 1)
            case .crossfadeMs: return (220, 0, 2000)
            case .levelFadeMs: return (220, 0, 2000)
            case .smallAnimationFps: return (3, 0.5, 15)
            case .smallAnimationQuality: return (50, 10, 90)
            case .compositorModel: return (0, 0, 1)
            case .autoMaxKbps: return (50_000, 1_000, 200_000)
            }
        }
    }

    /// The value for `key`: the host's (clamped to the key's bounds, ignored if not finite), else the default.
    public subscript(_ key: Key) -> Double {
        let s = key.spec
        guard let v = values[key.rawValue], v.isFinite else { return s.default }
        return min(s.max, max(s.min, v))
    }

    /// The compiled-in defaults, as a host sends them when nothing is overridden.
    public static var defaults: Tunables { Tunables(values: Dictionary(uniqueKeysWithValues: Key.allCases.map { ($0.rawValue, $0.spec.default) })) }

    /// The defaults with `overrides` applied (unknown keys kept: a newer viewer may know them).
    public static func host(overrides: [String: Double]) -> Tunables {
        var t = defaults
        for (k, v) in overrides where v.isFinite { t.values[k] = v }
        return t
    }

    /// The host's tunables: the defaults overridden by a `{"key": number}` JSON file (nil or unreadable: the defaults).
    public static func load(from url: URL?) -> (tunables: Tunables, error: String?) {
        guard let url, let d = try? Data(contentsOf: url) else { return (defaults, nil) }
        guard let o = try? JSONDecoder().decode([String: Double].self, from: d) else { return (defaults, "\(url.lastPathComponent): not a {\"key\": number} object; defaults used") }
        return (host(overrides: o), nil)
    }

    // MARK: Applying

    public func apply(to k: inout TwoFingerClassifier) {
        k.pinchRatio = self[.pinchRatio]; k.pinchDistance = self[.pinchDistance]; k.dominance = self[.twoFingerDominance]
        k.scrollSlop = self[.twoFingerScrollSlop]; k.windowTime = self[.twoFingerWindowTime]; k.windowTravel = self[.twoFingerWindowTravel]
        k.onsetTravel = self[.twoFingerOnsetTravel]
    }
    public func apply(to d: inout DirectTouch) {
        d.holdDelay = self[.holdDelay]; d.slop = self[.touchSlop]
        d.doubleClickInterval = self[.doubleClickInterval]; d.doubleClickSlop = self[.doubleClickSlop]
        d.twoFingerTapMax = self[.twoFingerTapMax]; d.twoFingerTapWait = self[.twoFingerTapWait]
        apply(to: &d.twoFinger)
    }
    public func apply(to v: inout ZoomViewport) { v.maxZoom = self[.maxZoom] }
    public func apply(to p: inout Predictor) { p.scrollLeadFraction = self[.scrollLeadFraction] }
    public var crossfadeNanos: UInt64 { UInt64(self[.crossfadeMs] * 1_000_000) }
    public var levelFadeNanos: UInt64 { UInt64(self[.levelFadeMs] * 1_000_000) }
}
