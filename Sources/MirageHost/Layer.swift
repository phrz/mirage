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
    /// Position on the display (display layer: the whole display), stream pixels.
    var frame: PixelRect
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
    var createdNanos: UInt64
    /// Captures with any change, and tile bytes sent, since the last stats line.
    var frames = 0
    var sentBytes = 0, sentRefine = 0, sentDirect = 0

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
        case blocks(remaining: [PixelRect])
        case done
        var description: String {
            switch self {
            case .base(let s): return "base(\(s))"
            case .climb(let s): return "climb(\(s))"
            case .still: return "still"
            case .blocks(let r): return "blocks(\(r.count) left)"
            case .done: return "done"
            }
        }
    }
    var fresh: Fresh = .done

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
    }

    var hasVideoPending: Bool { !pendingVideoTiles.isEmpty || wantKeyframe }
    var pixels: Int { width * height }

    /// Display coordinates → this layer's coordinates.
    func local(_ r: PixelRect) -> PixelRect { r.offset(-frame.x, -frame.y) }
    func local(x: Int, y: Int) -> (Int, Int) { (x - frame.x, y - frame.y) }
    var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }
}
