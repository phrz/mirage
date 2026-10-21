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
        /// Pending as a direct change (changed pixels the rate limit or the budget held back, a correction): it is
        /// presented as soon as it lands, never staged with a refinement level (DESIGN §3.3).
        var direct = false
        /// Shown lossy (a moved window's backdrop level) and refined lossless only once the session is idle: not due,
        /// not owed by a presentation level, not part of a backlog (`holdUntilIdle`, `releaseHeld`).
        var held = false
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
        /// Tiles changing all the time in a region too small to be video (under `sustainedClusterTiles`: an animated Dock
        /// icon, a spinner): for the small-animation path (lossy, a few fps), refined once they stop. Only with `smallRegions`.
        public var flicker: [Int] = []
    }

    /// Records this capture's dirty tiles and classifies them.
    /// `copyGate`: a copy-rect explained at least half of this layer's change in this frame or the last 300 ms: then
    /// nothing is motion (a scroll's unexplained frames, momentum steps and exposed strips stay copy-rect + lossless;
    /// experiments/byterace: scroll 675 → 209 kbps at 2000 kbps and 291 → 209 at 600, text crisp instead of soft 93 %).
    /// `smallRegions`: frequently dirty tiles outside any video cluster go to `flicker` instead of lossless (the host passes
    /// false while input flows, so typed text stays lossless at once). Without it such a region went lossless up to 12.5
    /// times a second: an animated Dock icon took ~550 kbps of 800 on mac-daddy and starved refinement.
    public mutating func classify(dirty: [Int], now: UInt64, copyGate: Bool = false, smallRegions: Bool = false) -> Plan {
        var plan = Plan()
        guard !dirty.isEmpty else { return plan }
        // History update.
        for i in dirty {
            var c = cells[i]
            if now &- c.lastDirtyNanos > tuning.historyNanos { c.hits = 0 }
            c.hits = min(c.hits &+ 1, 16)
            c.lastDirtyNanos = now
            c.held = false
            cells[i] = c
        }
        var videoSet = Set<Int>()
        if copyGate {
            // Copy-rect gate: no motion this frame.
        } else if dirty.count >= tuning.motionTileCount {
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
        if smallRegions, !copyGate {
            plan.flicker = dirty.filter { !videoSet.contains($0) && Int(cells[$0].hits) >= tuning.sustainedHits }
            videoSet.formUnion(plan.flicker)
        }
        for i in videoSet {
            // A tile that moves again while queued for refinement is dropped and re-queued: its old place
            // in the oldest-first order would otherwise let a region that kept moving jump the queue
            // (review: a 1003-tile backlog during a drag).
            cells[i].pending = true; cells[i].viaVideo = true; cells[i].direct = false
            cells[i].pendingSince = now
            cells[i].dueNanos = now &+ tuning.settleNanos
        }
        for i in dirty where !videoSet.contains(i) {
            var c = cells[i]
            if now &- c.lastLosslessNanos >= tuning.losslessMinIntervalNanos {
                plan.lossless.append(i)
                c.lastLosslessNanos = now; c.pending = false; c.pendingSince = 0; c.viaVideo = false; c.direct = false
            } else {
                // Rate-limited: send later, from whatever the frame looks like then.
                c.pending = true; c.viaVideo = false; c.direct = true
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
            c.pending = true; c.viaVideo = true; c.direct = false; c.held = false
            c.pendingSince = now
            c.dueNanos = now &+ tuning.settleNanos
            cells[i] = c
        }
    }

    /// A moved window's backdrop change (Liquid Glass: translucent toolbars and sidebars show a blur of whatever is behind
    /// the window, so a move changes them everywhere): the tiles changed, are presented by one lossy whole-layer level, and
    /// are refined lossless only once the session is idle (`releaseHeld`). Lossless per move was ~400 KB on mac-daddy.
    public mutating func holdUntilIdle(_ tiles: [Int], now: UInt64) {
        for i in tiles {
            var c = cells[i]
            if now &- c.lastDirtyNanos > tuning.historyNanos { c.hits = 0 }
            c.lastDirtyNanos = now
            c.pending = true; c.viaVideo = true; c.direct = false; c.held = true
            if c.pendingSince == 0 { c.pendingSince = now }
            c.dueNanos = .max
            cells[i] = c
        }
    }
    /// These held tiles become due now (they came back onto the display). Returns how many.
    @discardableResult
    public mutating func releaseHeld(_ tiles: Set<Int>, now: UInt64) -> Int {
        var n = 0
        for i in tiles where i >= 0 && i < cells.count && cells[i].held { cells[i].held = false; cells[i].pendingSince = now; cells[i].dueNanos = now; n += 1 }
        return n
    }
    /// Held tiles become due refinement now (the session went idle). Returns how many.
    @discardableResult
    public mutating func releaseHeld(now: UInt64) -> Int {
        var n = 0
        for i in cells.indices where cells[i].held { cells[i].held = false; cells[i].pendingSince = now; cells[i].dueNanos = now; n += 1 }
        return n
    }
    public func isHeld(_ i: Int) -> Bool { cells[i].held }
    public func isPending(_ i: Int) -> Bool { cells[i].pending }
    public var heldCount: Int { cells.reduce(0) { $0 + ($1.held ? 1 : 0) } }

    /// Pending tiles inside `rect` (and in `only`, if given) become due now (a fovea moved over them, a
    /// covered part of a window was uncovered).
    @discardableResult
    public mutating func expedite(in rect: PixelRect, now: UInt64, only: Set<Int>? = nil) -> Int {
        var n = 0
        for i in tiles(covering: [rect]) where cells[i].pending && !cells[i].held && cells[i].dueNanos > now && (only?.contains(i) ?? true) { cells[i].dueNanos = now; n += 1 }
        return n
    }

    /// Lossless tiles the budget could not carry now: keep them pending, due shortly. `direct`: they are changed
    /// pixels (presented on arrival) or not (a refinement, staged); nil keeps what they were.
    public mutating func `defer`(_ tiles: [Int], now: UInt64, delayNanos: UInt64 = 50_000_000, direct: Bool? = nil) {
        for i in tiles {
            var c = cells[i]
            c.pending = true; c.held = false
            if let direct { c.direct = direct }
            if c.pendingSince == 0 { c.pendingSince = now }
            c.dueNanos = now &+ delayNanos
            cells[i] = c
        }
    }

    /// Pending tiles that must be resent as direct changes (a correction), due now.
    public mutating func markDirect(_ tiles: [Int], now: UInt64) {
        for i in tiles {
            var c = cells[i]
            c.pending = true; c.direct = true; c.held = false; c.viaVideo = false
            if c.pendingSince == 0 { c.pendingSince = now }
            c.dueNanos = now
            cells[i] = c
        }
    }
    /// Pending as a direct change (sent unstaged), not a refinement.
    public func isDirectPending(_ i: Int) -> Bool { cells[i].pending && cells[i].direct }
    /// Refinement still owed somewhere the viewer can see: pending, not direct, not in `excluding`, and not changed
    /// since `stableBefore` (a region that keeps changing is dropped from the pending level, not waited for).
    public func refinementOutstanding(excluding: Set<Int>, stableBefore: UInt64) -> Int {
        var n = 0
        for i in 0..<cells.count where cells[i].pending && !cells[i].direct && !cells[i].held && cells[i].lastDirtyNanos <= stableBefore && !excluding.contains(i) { n += 1 }
        return n
    }

    /// The client has this tile pixel-exact (last update was lossless or a copy of crisp pixels, nothing pending).
    /// When the tile last changed (receiver of the audit: only tiles quiet for a while are compared).
    public func lastDirty(_ i: Int) -> UInt64 { cells[i].lastDirtyNanos }
    public func isCrisp(_ i: Int) -> Bool { !cells[i].pending && cells[i].lastLosslessNanos >= cells[i].lastDirtyNanos }

    /// Marks tiles as updated by a copy-rect (they are crisp again if the source was crisp).
    public mutating func markCopied(_ tiles: [Int], now: UInt64) { markCopied(tiles, dx: 0, dy: 0, now: now) }
    /// Destination tiles a copy-rect by (dx, dy) filled: they are as crisp as the pixels they came from. A destination
    /// tile takes the worst of the source tiles it overlaps: video-soft source text stays pending (with its due time),
    /// else it would never be refined once the scroll stops (experiments/byterace finding 2: text soft 93 % of the time
    /// after scrolling in the classifier's replay).
    public mutating func markCopied(_ tiles: [Int], dx: Int, dy: Int, now: UInt64) {
        let before = cells
        let bounds = PixelRect(x: 0, y: 0, width: width, height: height)
        for i in tiles {
            let src = rect(of: i).offset(-dx, -dy).intersection(bounds)
            let sources = src.isEmpty ? [] : self.tiles(covering: [src])
            // Sources the viewer holds wrong (a pending direct change: held back, a correction) make the destination wrong too: a
            // direct change due now (9755f02 marked them crisp, and each further scroll step spread a stacked Finder toolbar).
            let wrong = sources.contains { before[$0].pending && before[$0].direct }
            let soft = sources.filter { before[$0].pending && before[$0].viaVideo && !before[$0].direct }
            var c = cells[i]
            c.lastDirtyNanos = now; c.lastLosslessNanos = now; c.direct = false; c.held = false
            if wrong {
                c.pending = true; c.direct = true; c.viaVideo = false
                c.pendingSince = now; c.dueNanos = now
            } else if soft.isEmpty {
                c.pending = false; c.pendingSince = 0; c.viaVideo = false
            } else {
                c.pending = true; c.viaVideo = true
                c.held = soft.contains { before[$0].held }
                c.pendingSince = soft.map { before[$0].pendingSince }.min() ?? now
                c.dueNanos = c.held ? .max : (soft.map { before[$0].dueNanos }.filter { $0 != .max }.max() ?? (now &+ tuning.settleNanos))
            }
            cells[i] = c
        }
    }

    /// Tiles that became video-quality and still need refinement (for stats).
    public var pendingRefinement: Int { cells.reduce(0) { $0 + ($1.pending && $1.viaVideo ? 1 : 0) } }
    public var pendingTotal: Int { cells.reduce(0) { $0 + ($1.pending ? 1 : 0) } }
    /// Pending and not held for idle (what a refinement backlog is made of).
    public var pendingUnheld: Int { cells.reduce(0) { $0 + ($1.pending && !$1.held ? 1 : 0) } }

    /// Pending tiles whose due time has passed, oldest-pending first and viewport-centre first
    /// among equals (within 100 ms). The caller sends as many as the byte budget allows and
    /// calls `sent` for those.
    public func due(now: UInt64, limit: Int, centre: (col: Int, row: Int)? = nil) -> [Int] {
        var out: [(Int, UInt64, Int)] = []
        let cx = centre?.col ?? cols / 2, cy = centre?.row ?? rows / 2
        for i in 0..<cells.count where cells[i].pending && cells[i].dueNanos <= now {
            let c = i % cols, r = i / cols
            out.append((i, cells[i].pendingSince / 100_000_000, abs(c - cx) + abs(r - cy)))
        }
        out.sort { a, b in a.1 != b.1 ? a.1 < b.1 : a.2 != b.2 ? a.2 < b.2 : a.0 < b.0 }
        return out.prefix(limit).map { $0.0 }
    }

    /// Due tiles pending as direct changes (rate-limited or held back changed pixels), oldest first.
    public func dueDirect(now: UInt64, limit: Int) -> [Int] {
        var out: [(Int, UInt64)] = []
        for i in 0..<cells.count where cells[i].pending && cells[i].direct && !cells[i].viaVideo && cells[i].dueNanos <= now { out.append((i, cells[i].pendingSince)) }
        out.sort { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
        return out.prefix(limit).map { $0.0 }
    }
    /// When the longest-waiting due direct tile has been due since (nil: none due).
    public func oldestDueDirect(now: UInt64) -> UInt64? {
        var oldest: UInt64? = nil
        for c in cells where c.pending && c.direct && !c.viaVideo && c.dueNanos <= now { oldest = min(oldest ?? c.dueNanos, c.dueNanos) }
        return oldest
    }

    public mutating func sent(lossless tiles: [Int], now: UInt64) {
        for i in tiles {
            var c = cells[i]
            c.lastLosslessNanos = now; c.pending = false; c.pendingSince = 0; c.viaVideo = false; c.direct = false; c.held = false
            cells[i] = c
        }
    }

    public mutating func reset() { cells = Array(repeating: Cell(), count: cols * rows) }

    /// Any tile under `rects` dirtied or moved (copy-rect) after `nanos`: pixels captured at `nanos`
    /// for those rects are stale and must not be sent.
    public func changedSince(nanos: UInt64, in rects: [PixelRect]) -> Bool {
        tiles(covering: rects).contains { cells[$0].lastDirtyNanos > nanos }
    }

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
