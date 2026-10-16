import Foundation

/// Per-tile dirty history and the three-way classification of DESIGN §3.3: static → nothing,
/// sparse/settling → lossless, sustained motion → video. Also the refinement queue: tiles last
/// shown through video are re-sent lossless once they have been still for `settleNanos`.
/// Pure logic; the host feeds it dirty rects and reads back a plan per capture.
public struct TileTracker {
    public static let tile = 64
    public let width: Int, height: Int, cols: Int, rows: Int

    public struct Tuning: Sendable {
        /// A frame with at least this many dirty tiles is motion regardless of history.
        public var motionTileCount = 28
        /// A frame with at least this fraction of all tiles dirty is encoded as a whole frame.
        public var wholeFrameFraction = 0.40
        /// A tile dirty this often inside `historyNanos` is "sustained"...
        public var sustainedHits = 4
        public var historyNanos: UInt64 = 400_000_000
        /// ...and a cluster of at least this many sustained tiles goes to video (a spinner stays lossless).
        public var sustainedClusterTiles = 8
        /// Video-shown tiles are refined lossless after being still this long.
        public var settleNanos: UInt64 = 300_000_000
        /// A lossless tile is re-sent at most this often (caret blink, spinner).
        public var losslessMinIntervalNanos: UInt64 = 80_000_000
        public init() {}
    }
    public var tuning = Tuning()

    struct Cell {
        var hits: UInt8 = 0
        var lastDirtyNanos: UInt64 = 0
        var lastLosslessNanos: UInt64 = 0
        /// Needs a lossless (re)send: either shown through video, or rate-limited.
        var pending = false
        var pendingSince: UInt64 = 0     // when it first became pending (oldest-first ordering)
        var dueNanos: UInt64 = 0
        var viaVideo = false              // pending because video covered it (refinement) rather than a rate limit
    }
    private var cells: [Cell]

    public init(width: Int, height: Int) {
        self.width = width; self.height = height
        cols = (width + Self.tile - 1) / Self.tile
        rows = (height + Self.tile - 1) / Self.tile
        cells = Array(repeating: Cell(), count: cols * rows)
    }

    public var tileCount: Int { cols * rows }
    public func rect(of index: Int) -> PixelRect {
        let c = index % cols, r = index / cols
        return PixelRect(x: c * Self.tile, y: r * Self.tile, width: min(Self.tile, width - c * Self.tile), height: min(Self.tile, height - r * Self.tile))
    }
    public func index(col: Int, row: Int) -> Int { row * cols + col }

    /// Tiles touched by the given rects (clamped to the frame), deduplicated and sorted.
    public func tiles(covering rects: [PixelRect]) -> [Int] {
        var set = Set<Int>()
        for r in rects {
            let r = r.intersection(PixelRect(x: 0, y: 0, width: width, height: height))
            guard !r.isEmpty else { continue }
            let c0 = r.x / Self.tile, c1 = (r.maxX - 1) / Self.tile, r0 = r.y / Self.tile, r1 = (r.maxY - 1) / Self.tile
            for row in r0...r1 { for col in c0...c1 { set.insert(index(col: col, row: row)) } }
        }
        return set.sorted()
    }

    public struct Plan: Equatable {
        /// Tiles to send lossless now, from this capture.
        public var lossless: [Int] = []
        /// Tiles updated through video this capture (dirty tiles inside `videoRegion`).
        public var video: [Int] = []
        /// Bounding rect (tile-snapped) of `video`, or the whole frame.
        public var videoRegion: PixelRect = .zero
        public var wholeFrame = false
    }

    /// Records this capture's dirty tiles and classifies them.
    public mutating func classify(dirty: [Int], now: UInt64) -> Plan {
        var plan = Plan()
        guard !dirty.isEmpty else { return plan }
        // History update.
        for i in dirty {
            var c = cells[i]
            if now &- c.lastDirtyNanos > tuning.historyNanos { c.hits = 0 }
            c.hits = min(c.hits &+ 1, 16)
            c.lastDirtyNanos = now
            cells[i] = c
        }
        var videoSet = Set<Int>()
        if dirty.count >= tuning.motionTileCount {
            videoSet = Set(dirty)
        } else {
            // Sustained small motion: clusters of frequently-dirty tiles.
            let sustained = dirty.filter { Int(cells[$0].hits) >= tuning.sustainedHits }
            if sustained.count >= tuning.sustainedClusterTiles {
                let bb = boundingRect(sustained)
                // Everything dirty inside the sustained cluster's bounding box rides the same video frame.
                for i in dirty where bb.intersects(rect(of: i)) { videoSet.insert(i) }
            }
        }
        if Double(videoSet.count) >= tuning.wholeFrameFraction * Double(tileCount) {
            plan.wholeFrame = true
            plan.videoRegion = PixelRect(x: 0, y: 0, width: width, height: height)
        } else if !videoSet.isEmpty {
            plan.videoRegion = boundingRect(Array(videoSet))
        }
        plan.video = videoSet.sorted()
        for i in plan.video {
            cells[i].pending = true; cells[i].viaVideo = true
            if cells[i].pendingSince == 0 { cells[i].pendingSince = now }
            cells[i].dueNanos = now &+ tuning.settleNanos
        }
        for i in dirty where !videoSet.contains(i) {
            var c = cells[i]
            if now &- c.lastLosslessNanos >= tuning.losslessMinIntervalNanos {
                plan.lossless.append(i)
                c.lastLosslessNanos = now; c.pending = false; c.pendingSince = 0; c.viaVideo = false
            } else {
                // Rate-limited: send later, from whatever the frame looks like then.
                c.pending = true; c.viaVideo = false
                if c.pendingSince == 0 { c.pendingSince = now }
                c.dueNanos = c.lastLosslessNanos &+ tuning.losslessMinIntervalNanos
            }
            cells[i] = c
        }
        return plan
    }

    /// Marks tiles as shown through video (keyframe, recovery): they need refinement.
    public mutating func markVideo(_ tiles: [Int], now: UInt64) {
        for i in tiles {
            var c = cells[i]
            c.pending = true; c.viaVideo = true
            if c.pendingSince == 0 { c.pendingSince = now }
            c.dueNanos = now &+ tuning.settleNanos
            cells[i] = c
        }
    }

    /// Lossless tiles the budget could not carry now: keep them pending, due shortly.
    public mutating func `defer`(_ tiles: [Int], now: UInt64, delayNanos: UInt64 = 50_000_000) {
        for i in tiles {
            var c = cells[i]
            c.pending = true
            if c.pendingSince == 0 { c.pendingSince = now }
            c.dueNanos = now &+ delayNanos
            cells[i] = c
        }
    }

    /// The client has this tile pixel-exact (last update was lossless or a copy of crisp pixels, nothing pending).
    public func isCrisp(_ i: Int) -> Bool { !cells[i].pending && cells[i].lastLosslessNanos >= cells[i].lastDirtyNanos }

    /// Marks tiles as updated by a copy-rect (they are crisp again if the source was crisp).
    public mutating func markCopied(_ tiles: [Int], now: UInt64) {
        for i in tiles {
            var c = cells[i]
            c.lastDirtyNanos = now; c.lastLosslessNanos = now
            c.pending = false; c.pendingSince = 0; c.viaVideo = false
            cells[i] = c
        }
    }

    /// Tiles that became video-quality and still need refinement (for stats).
    public var pendingRefinement: Int { cells.reduce(0) { $0 + ($1.pending && $1.viaVideo ? 1 : 0) } }
    public var pendingTotal: Int { cells.reduce(0) { $0 + ($1.pending ? 1 : 0) } }

    /// Pending tiles whose due time has passed, oldest-pending first and viewport-centre first
    /// among equals (within 100 ms). The caller sends as many as the byte budget allows and
    /// calls `sent` for those.
    public func due(now: UInt64, limit: Int) -> [Int] {
        var out: [(Int, UInt64, Int)] = []
        let cx = cols / 2, cy = rows / 2
        for i in 0..<cells.count where cells[i].pending && cells[i].dueNanos <= now {
            let c = i % cols, r = i / cols
            out.append((i, cells[i].pendingSince / 100_000_000, abs(c - cx) + abs(r - cy)))
        }
        out.sort { a, b in a.1 != b.1 ? a.1 < b.1 : a.2 != b.2 ? a.2 < b.2 : a.0 < b.0 }
        return out.prefix(limit).map { $0.0 }
    }

    public mutating func sent(lossless tiles: [Int], now: UInt64) {
        for i in tiles {
            var c = cells[i]
            c.lastLosslessNanos = now; c.pending = false; c.pendingSince = 0; c.viaVideo = false
            cells[i] = c
        }
    }

    public mutating func reset() { cells = Array(repeating: Cell(), count: cols * rows) }

    public func boundingRect(_ tiles: [Int]) -> PixelRect {
        var r = PixelRect.zero
        for i in tiles { r = r.union(rect(of: i)) }
        return r
    }

    /// Merges a set of tiles into as few rects as possible: horizontal runs per row, then
    /// vertically adjacent runs with identical column spans (tilebench: bigger rects compress ~2x better).
    public func mergedRects(_ tiles: [Int]) -> [PixelRect] {
        let set = Set(tiles)
        struct Run { var row: Int, c0: Int, c1: Int, rowCount: Int }
        var runs: [Run] = []
        for i in tiles.sorted() {
            let c = i % cols, r = i / cols
            if let last = runs.indices.last, runs[last].row == r, runs[last].c1 + 1 == c, runs[last].rowCount == 1, set.contains(i) {
                runs[last].c1 = c
            } else {
                runs.append(Run(row: r, c0: c, c1: c, rowCount: 1))
            }
        }
        // Vertical merge: a run directly below another with the same span extends it.
        var merged: [Run] = []
        for run in runs {
            if let j = merged.indices.last(where: { merged[$0].c0 == run.c0 && merged[$0].c1 == run.c1 && merged[$0].row + merged[$0].rowCount == run.row }) {
                merged[j].rowCount += 1
            } else {
                merged.append(run)
            }
        }
        return merged.map { r in
            let x = r.c0 * Self.tile, y = r.row * Self.tile
            return PixelRect(x: x, y: y, width: min((r.c1 + 1) * Self.tile, width) - x, height: min((r.row + r.rowCount) * Self.tile, height) - y)
        }
    }
}
