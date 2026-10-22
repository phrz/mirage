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
        // Host only: 1 = placeholders (DESIGN §3.0b): at stream start every visible window gets a 32-px stand-in at once.
        case placeholders
        // 1 = a window drag is real mouse events on the host (down at the press, moves, up), the local layer drag only a
        // prediction reconciled to the host's frame; 0 = the window is moved and raised through Accessibility.
        case injectedDrags
        // Host only: 1 = the connect-time bandwidth probe (a 48 KB packet train at a fresh stream, M-FIVE); 0 = off.
        case connectProbe
        // Host only: an automatic stream's first rate in kbit/s on a network with no recent estimate (BBR-style startup doubles
        // it per round trip from there while delivery keeps up).
        case startKbps
        // Host only: an automatic-bitrate stream's ceiling in kbit/s (BitratePolicy): the controller starts at 800 and probes
        // up to whatever the link sustains, never above this.
        case autoMaxKbps
        // Host only: 1 = warm host (WarmPool): with no stream, the visible windows' captures keep running at 1 fps, their
        // latest frames in memory (never on disk, dropped on lock, display sleep or battery), adopted at connect; 0 = off.
        case warmCapture
        // Host only, warm host: how many windows (the largest) are kept warm; their capture size as a fraction of native
        // (under 1: smaller, cheaper for WindowServer, no usable first frame); 1 = warmed with the window-alone filter.
        case warmWindows, warmScale, warmIndependent
        // Host only, warm host: 0 = a display snapshot every warmSnapshotSeconds (phrz: never more often than every 30 s),
        // stage 1 cut from it at connect while the window layout is unchanged; 1 = the windows' captures kept running;
        // 2 = the snapshot plus the desktop and overlay display captures kept running (their starts took ~1.2 s of a connect).
        case warmMode, warmSnapshotSeconds
        // Host only: 1 = a window's first-frame snapshot at connect uses the window-alone filter (desktopIndependentWindow).
        case windowShotIndependent
        // Host only: stage 1's stills together cost this many seconds of the link's rate (M-FIVE; was 0.5: on Japan bus the
        // stills then arrived 2.3 s after the first picture, behind the probe train and 59 KB of cuts).
        case stage1Seconds
        // Host only: 1 = the shadow probe's result is published (WindowInfo.shadow); 0 = logged only, every window's shadow
        // unknown (drawn as before), until the probe is verified on real windows.
        case shadowProbe
        // Host only: 1 = a window nothing covers in the stage-1 picture takes its cut as its still (no window-alone shot);
        // 0 = every window waits for its window-alone shot, until the cut is verified equal to it (the cut check).
        case cutStills
        // Host only: 1 = translucent window tiles go as video with a greyscale alpha mask (viewers that read it); 0 = they
        // stay lossless tiles, as before, until the mask path is verified.
        case alphaMask
        // 1 = TRUTH (DESIGN §3.0): the host ends each capture's direct changes with frameEnd and the viewer shows them only
        // then, all at once (bounded wait: 2 srtt + 50 ms, then TRUTH TIMEOUT); 0 = changes show as they arrive.
        case transactional

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
            case .placeholders: return (1, 0, 1)
            case .injectedDrags: return (1, 0, 1)
            case .connectProbe: return (1, 0, 1)
            case .startKbps: return (2_000, 150, 50_000)
            case .autoMaxKbps: return (50_000, 1_000, 200_000)
            case .warmCapture: return (1, 0, 1)
            case .warmWindows: return (12, 0, 40)
            case .warmScale: return (1, 0.02, 1)
            case .warmIndependent: return (0, 0, 1)
            case .warmMode: return (0, 0, 2)
            case .warmSnapshotSeconds: return (30, 30, 3600)
            case .windowShotIndependent: return (1, 0, 1)
            case .stage1Seconds: return (0.2, 0.05, 2)
            case .shadowProbe: return (0, 0, 1)
            case .cutStills: return (0, 0, 1)
            case .alphaMask: return (0, 0, 1)
            case .transactional: return (0, 0, 1)
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

    /// The host's tunables file: `tunables.json` in its store, or the file MIRAGE_TUNABLES names (a test host on another port
    /// with its own tunables, the store's keys and pairings shared).
    public static func hostFileURL(_ store: Store?) -> URL? {
        if let p = ProcessInfo.processInfo.environment["MIRAGE_TUNABLES"], !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        return store?.url("tunables.json")
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
