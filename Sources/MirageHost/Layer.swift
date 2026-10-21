import Foundation
import CoreVideo
import VideoToolbox
import MirageCore

/// One captured layer of the desktop (DESIGN §3.2 layered desktop): the display without the layered
/// windows (id 0), or one window captured whole and unoccluded (its CGWindow id). Each layer has its
/// own tile tracker, last frame, and, when it moves, its own HEVC canvas and encoder; the streamer owns
/// the budget, the pacer and the ordering across layers.
final class Layer {
    let id: UInt32
    var isDisplay: Bool { id == 0 }
    private(set) var width: Int, height: Int
    var tracker: TileTracker
    var lastFrame: CVPixelBuffer?
    /// When a copy-rect last explained at least half of this layer's change (the copy-rect gate, TileTracker.classify).
    var copyGateNanos: UInt64 = 0
    /// Position on the display (display layer: the whole display), stream pixels.
    var frame: PixelRect
    /// The window's size in points when the layer was sized (a resize is a change of a point or more).
    var pointSize: CGSize = .zero
    var capturer: WindowCapturer?
    /// The viewer has been told this layer exists (`.reset`) and holds its first picture (the still).
    var announced = false
    var exposed = false
    /// Force the next capture through a full diff (resume, resize).
    var forceFullDiff = false
    /// Visible fraction of the window on the host (1 = nothing in front of it); covered tiles are not sent.
    var visibleFraction = 1.0
    var occludedTiles = Set<Int>()
    var frontmost = false
    var absentSince: UInt64 = 0
    /// When the layer's own capture was (re)started and has not delivered since (0: it has, or none is wanted).
    var awaitingOwnSince: UInt64 = 0
    var createdNanos: UInt64
    /// Display layer only: tiles the viewer may hold window pixels for (DisplayTaint) and the ones already queued for a re-send.
    var taint = DisplayTaint()
    var taintScheduled = Set<Int>()
    /// Display layer: tiles fully under a shown window (the underlay, sent at q75 for photographic areas) and the
    /// ones that went out lossy that way (refined at the normal quality once a window move uncovers them).
    var underLayer = Set<Int>()
    var underlayLossy = Set<Int>()
    /// Uncovered underlay tiles waiting for their upgrade to the normal quality (rate-limited, served last).
    var upgradePending = Set<Int>()
    /// Frames (inset) of the shown windows, for ordering the underlay edge-first.
    var underlayEdge: [PixelRect] = []
    /// Window layers: which of the layer's own 64-px tiles are opaque (alpha 255 at 5 sample points), refreshed
    /// from the last frame at most every 500 ms; and whether the window is opaque overall (≥ 90 % of tiles).
    var opaqueTiles = Set<Int>()
    var opaqueSampledNanos: UInt64 = 0
    var opaque = true
    func refreshOpacity(now: UInt64) {
        guard !isDisplay, let pb = lastFrame, Clock.elapsed(since: opaqueSampledNanos, now: now) > 500_000_000 else { return }
        opaqueSampledNanos = now
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetWidth(pb) == width else { return }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var set = Set<Int>()
        for i in 0..<tracker.tileCount {
            let r = tracker.rect(of: i)
            let pts = [(r.x + 2, r.y + 2), (r.maxX - 3, r.y + 2), (r.x + 2, r.maxY - 3), (r.maxX - 3, r.maxY - 3), (r.x + r.width / 2, r.y + r.height / 2)]
            if pts.allSatisfy({ p in p.0 >= 0 && p.1 >= 0 && p.0 < width && p.1 < height && base[p.1 * stride + p.0 * 4 + 3] == 255 }) { set.insert(i) }
        }
        opaqueTiles = set
        opaque = set.count * 10 >= tracker.tileCount * 9
    }
    /// Whether the window's pixels are opaque over a display-coordinate rect (all layer tiles it touches).
    func opaque(over displayRect: PixelRect) -> Bool {
        let r = local(displayRect)
        let ts = tracker.tiles(covering: [r])
        return !ts.isEmpty && ts.allSatisfy { opaqueTiles.contains($0) }
    }
    /// Captures with any change, and tile bytes sent, since the last stats line.
    var frames = 0
    var sentBytes = 0, sentRefine = 0, sentDirect = 0
    /// 30 s accounting by class (DESIGN §6 M3.1: what the steady traffic is): first-picture still, lossless blocks,
    /// per-tile refinement, direct changes, video, underlay (display only), and dirty tiles seen.
    struct Account { var still = 0, blocks = 0, refine = 0, direct = 0, video = 0, underlay = 0, dirtyTiles = 0, upgrade = 0, backdrop = 0, strip = 0, correction = 0
        var total: Int { still + blocks + refine + direct + video + underlay + backdrop + strip + correction } }
    /// Tiles pending as corrections (a copy-rect's wrong destination, an audit mismatch): accounted apart from other changes.
    var correctionTiles = Set<Int>()
    /// Window layers: when the window last moved on the host, and whether a backdrop change since then waits for its
    /// lossy level (TileTracker.holdUntilIdle); when the last held capture came.
    var movedNanos: UInt64 = 0
    /// Drops the blank captures Show Desktop produces (WindowBlanking).
    var blanking = WindowBlanking()
    var blankDropped = 0
    /// Tiles wholly off the display that the viewer was sent transparent (host-side crop, DESIGN §3.0).
    var blankedOffDisplay = Set<Int>()
    /// The layer's on-display part in its own coordinates (from the last occlusion pass) and whether to crop again.
    var onScreenLocal: PixelRect?
    var needsCrop = false
    /// When this layer's last small animation went out (lossy tiles at the capped rate).
    var smallAnimNanos: UInt64 = 0
    var backdropDirty = false
    var backdropHeldNanos: UInt64 = 0
    /// Window picture audit: where its slow sweep continues.
    var auditCursor = 0
    var account = Account()

    // Video.
    var canvas: CVPixelBuffer?
    var scaled: CVPixelBuffer?
    var transfer: VTPixelTransferSession?
    var encoder: HEVCEncoder?
    var pendingVideoTiles = Set<Int>()
    var pendingVideoRegion = PixelRect.zero
    var pendingWholeFrame = false
    var submitted: (tiles: Set<Int>, region: PixelRect, whole: Bool)? = nil
    var encoding = false
    var encodingSince: UInt64 = 0
    var wantKeyframe = false, keyframeArmed = false, wantLTRRefresh = false, progressiveKeyframe = false
    var ackedLTR: [Int64] = []
    var recoverySeq: UInt32 = 0, recoverySentNanos: UInt64 = 0, lastRecoveryWasLTR = false
    var videoActiveNanos: UInt64 = 0
    var encoderUseNanos: UInt64 = 0
    var lastSendNanos: UInt64 = 0
    var lastFpsCap = 30.0

    /// Fresh-picture state: the display layer climbs the ladder (tiny keyframe → rungs → lossless blocks);
    /// a window layer starts with one lossy still, then lossless blocks.
    enum Fresh: CustomStringConvertible, Equatable {
        case base(seq: UInt32)          // waiting for the ack of the tiny keyframe
        case climb(seq: UInt32)         // waiting for the ack of the last ladder step
        case still                      // a window layer's first picture: one lossy still, not sent yet
        case intermediate               // the whole-layer middle level (q90-class lossy at full size), not sent yet
        case blocks(remaining: [PixelRect])
        case done
        var description: String {
            switch self {
            case .base(let s): return "base(\(s))"
            case .climb(let s): return "climb(\(s))"
            case .still: return "still"
            case .intermediate: return "intermediate"
            case .blocks(let r): return "blocks(\(r.count) left)"
            case .done: return "done"
            }
        }
    }
    var fresh: Fresh = .done

    /// Presentation (DESIGN §3.3): refinement goes to the viewer staged (written off-screen); one `commit` presents
    /// the whole level once the visible part of the layer is complete. Open since, last staged send, staged
    /// messages still being encoded (the commit must follow them on the tile stream), levels presented.
    var stagedOpenSince: UInt64? = nil
    var lastStagedNanos: UInt64 = 0
    var stagedEncoding = 0
    var levelsCommitted = 0

    /// Layer pixel sizes are even (the capture and the HEVC canvas want that); a window layer's canvas is
    /// at most one pixel short of its frame.
    static func even(_ v: Int) -> Int { max(2, v & ~1) }

    init(id: UInt32, width: Int, height: Int, frame: PixelRect, now: UInt64) {
        self.id = id; self.width = id == 0 ? width : Self.even(width); self.height = id == 0 ? height : Self.even(height); self.frame = frame; createdNanos = now
        tracker = TileTracker(width: self.width, height: self.height)
    }

    /// New pixel size (a window resize, a stream reconfigure): everything pixel-shaped starts over.
    func resize(width: Int, height: Int) {
        self.width = Self.even(width); self.height = Self.even(height)
        tracker = TileTracker(width: self.width, height: self.height)
        lastFrame = nil; canvas = nil; scaled = nil; transfer = nil; encoder = nil
        pendingVideoTiles = []; pendingVideoRegion = .zero; pendingWholeFrame = false; submitted = nil
        encoding = false; wantKeyframe = false; keyframeArmed = false; ackedLTR = []
        occludedTiles = []
        announced = false; exposed = false
        fresh = .done
        stagedOpenSince = nil
        backdropDirty = false
    }

    var hasVideoPending: Bool { !pendingVideoTiles.isEmpty || wantKeyframe }
    var pixels: Int { width * height }

    /// Display coordinates → this layer's coordinates.
    func local(_ r: PixelRect) -> PixelRect { r.offset(-frame.x, -frame.y) }
    func local(x: Int, y: Int) -> (Int, Int) { (x - frame.x, y - frame.y) }
    var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }
}
