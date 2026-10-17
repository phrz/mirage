import Foundation

/// Client-side latency hiding for scroll and window drag (DESIGN §3.5 items 2–3): the client
/// moves pixels it already has at the input, then reconciles with the host's copy-rects.
/// Per window, predictions form a FIFO of unconfirmed deltas; host copy-rects consume them, a
/// host update that already reflects a prediction's input retires it, and a mismatch drops the
/// window's confidence (predictions tracked but not shown) until one is confirmed again.
public struct Predictor {
    public enum Kind: Equatable, Sendable { case scroll, drag }

    public struct Prediction: Equatable, Sendable {
        public var kind: Kind
        public var windowID: UInt32
        public var rect: PixelRect        // scroll rect, or the window frame at mouse-down
        public var dx: Int, dy: Int       // predicted delta
        public var remX: Int, remY: Int   // not yet confirmed by host copy-rects
        public var inputSeq: UInt64
        public var createdNanos: UInt64
    }

    /// What to draw: `rect` displaced by (dx, dy); scroll clips to `rect`, drag does not.
    public struct Displacement: Equatable, Sendable {
        public var kind: Kind
        public var windowID: UInt32
        public var rect: PixelRect
        public var dx: Int, dy: Int
    }

    struct WindowState {
        var predictions: [Prediction] = []
        var confident = true
        var lastMismatchNanos: UInt64 = 0
        var mismatches = 0
    }
    private var windows: [UInt32: WindowState] = [:]

    /// Window drag (DESIGN §3.5 item 2, reworked after the M2.5 field test): the client shows the dragged
    /// window at its own pointer, i.e. displaced from the host's last confirmed frame by (pointer now −
    /// pointer at that confirmation). Host copy-rects move the confirmed frame by their exact (dx, dy);
    /// any other host update that reflects input seq k moves it to where the pointer was at k. Nothing
    /// is matched one-to-one, so a host that reports a diagonal move axis by axis, or coalesces several
    /// moves, still confirms. A copy-rect counts as confirmed when the host's cumulative displacement
    /// since mouse-down agrees with the pointer's within 8 px, mismatched otherwise.
    struct DragState {
        var frame0: PixelRect
        var pointer0: (x: Int, y: Int)
        var seq0: UInt64
        var pointers: [(seq: UInt64, x: Int, y: Int)] = []
        var last: (x: Int, y: Int)
        var hostDX = 0, hostDY = 0
        var confirmedSeq: UInt64
        var lastHostNanos: UInt64
        var createdNanos: UInt64
        var ended = false
        func pointer(at seq: UInt64) -> (x: Int, y: Int) { pointers.last(where: { $0.seq <= seq }).map { ($0.x, $0.y) } ?? pointer0 }
        var residual: (dx: Int, dy: Int) { (last.x - pointer0.x - hostDX, last.y - pointer0.y - hostDY) }
        var confirmedFrame: PixelRect { frame0.offset(hostDX, hostDY) }
    }
    private var drags: [UInt32: DragState] = [:]

    public mutating func beginDrag(windowID: UInt32, frame: PixelRect, pointer: (Int, Int), inputSeq: UInt64, now: UInt64) {
        drags[windowID] = DragState(frame0: frame, pointer0: (pointer.0, pointer.1), seq0: inputSeq, pointers: [(inputSeq, pointer.0, pointer.1)], last: (pointer.0, pointer.1),
                                    confirmedSeq: inputSeq, lastHostNanos: now, createdNanos: now)
        if windows[windowID] == nil { windows[windowID] = WindowState() }
    }
    public mutating func dragPointer(windowID: UInt32, pointer: (Int, Int), inputSeq: UInt64, now: UInt64) {
        guard var d = drags[windowID] else { return }
        d.last = (pointer.0, pointer.1)
        d.pointers.append((inputSeq, pointer.0, pointer.1))
        if d.pointers.count > 512 { d.pointers.removeFirst(d.pointers.count - 512) }
        drags[windowID] = d
        if windows[windowID]?.confident ?? true { stats.shown += 1 }
    }
    public mutating func endDrag(windowID: UInt32) { drags[windowID]?.ended = true }
    public func dragResidual(windowID: UInt32) -> (dx: Int, dy: Int)? { drags[windowID]?.residual }

    public var timeoutNanos: UInt64 = 1_200_000_000
    /// After a mismatch, show predictions again once one has been confirmed or this much time has passed.
    public var recoverNanos: UInt64 = 2_000_000_000
    public private(set) var stats = (shown: 0, confirmed: 0, mismatched: 0, expired: 0)

    public init() {}

    public mutating func predict(kind: Kind, windowID: UInt32, rect: PixelRect, dx: Int, dy: Int, inputSeq: UInt64, now: UInt64) {
        guard dx != 0 || dy != 0 else { return }
        var w = windows[windowID] ?? WindowState()
        // Same kind, same rect, opposite direction: cancel against the newest unconfirmed delta first (wheel jitter).
        w.predictions.append(Prediction(kind: kind, windowID: windowID, rect: rect, dx: dx, dy: dy, remX: dx, remY: dy, inputSeq: inputSeq, createdNanos: now))
        windows[windowID] = w
        if w.confident { stats.shown += 1 }
    }

    /// A host copy-rect for `windowID` (0 = unknown: matched against any window whose rect intersects).
    public mutating func hostCopyRect(windowID: UInt32, rect: PixelRect, dx: Int, dy: Int, inputSeq: UInt64 = 0, now: UInt64) {
        // Drags: exact geometry from the copy-rect; confirmation by the cumulative displacement.
        let dragIDs = windowID != 0 ? (drags[windowID] != nil ? [windowID] : []) : drags.keys.filter { drags[$0]!.confirmedFrame.intersects(rect) }
        for id in dragIDs {
            guard var d = drags[id], var w = windows[id] else { continue }
            d.hostDX += dx; d.hostDY += dy; d.lastHostNanos = now
            if inputSeq > d.confirmedSeq { d.confirmedSeq = inputSeq }
            let p = d.pointer(at: inputSeq > 0 ? inputSeq : d.confirmedSeq)
            let ex = p.x - d.pointer0.x, ey = p.y - d.pointer0.y
            // Agreement per axis: the host has moved toward where the pointer was at k and not past it
            // (a host that reports the two axes in separate updates lags on one of them; that is fine).
            func agrees(_ h: Int, _ e: Int) -> Bool { h == 0 || (h.signum() == e.signum() && abs(h) <= abs(e) + 8) }
            if agrees(d.hostDX, ex) && agrees(d.hostDY, ey) {
                stats.confirmed += 1; if !w.confident { w.confident = true }
            } else {
                // Disagreement with the pointer: hide the displacement for a while and re-sync to the host.
                stats.mismatched += 1; w.mismatches += 1; w.confident = false; w.lastMismatchNanos = now
                d.hostDX = ex; d.hostDY = ey
            }
            drags[id] = d; windows[id] = w
        }
        let ids = windowID != 0 ? [windowID] : windows.keys.filter { id in windows[id]!.predictions.contains { $0.rect.intersects(rect) } }
        for id in ids {
            guard var w = windows[id], !w.predictions.isEmpty else { continue }
            var cx = dx, cy = dy
            // Sign conflict with the oldest unconfirmed prediction: the host went the other way.
            if let p = w.predictions.first(where: { $0.remX != 0 || $0.remY != 0 }),
               (cx != 0 && p.remX != 0 && (cx < 0) != (p.remX < 0)) || (cy != 0 && p.remY != 0 && (cy < 0) != (p.remY < 0)) {
                mismatch(&w, now: now); windows[id] = w; continue
            }
            for i in w.predictions.indices {
                if cx != 0, w.predictions[i].remX != 0 {
                    let take = cx > 0 ? min(cx, w.predictions[i].remX) : max(cx, w.predictions[i].remX)
                    w.predictions[i].remX -= take; cx -= take
                }
                if cy != 0, w.predictions[i].remY != 0 {
                    let take = cy > 0 ? min(cy, w.predictions[i].remY) : max(cy, w.predictions[i].remY)
                    w.predictions[i].remY -= take; cy -= take
                }
            }
            let before = w.predictions.count
            w.predictions.removeAll { $0.remX == 0 && $0.remY == 0 }
            let confirmed = before - w.predictions.count
            stats.confirmed += confirmed
            if confirmed > 0, !w.confident { w.confident = true }
            windows[id] = w
        }
    }

    /// Any host pixel update: `inputSeq` is the last input those pixels reflect. Predictions for an
    /// older input whose rect the update touches are due: unconfirmed remainder means a mismatch.
    public mutating func hostUpdate(inputSeq: UInt64, rect: PixelRect, now: UInt64) {
        guard inputSeq > 0 else { return }
        // Drags: a host picture that reflects input k (and was not a copy-rect for k) shows the window
        // where the pointer was at k.
        for id in drags.keys {
            guard var d = drags[id], inputSeq > d.confirmedSeq, inputSeq >= d.seq0, d.confirmedFrame.union(d.confirmedFrame.offset(d.residual.dx, d.residual.dy)).intersects(rect) else { continue }
            let p = d.pointer(at: inputSeq)
            d.hostDX = p.x - d.pointer0.x; d.hostDY = p.y - d.pointer0.y
            d.confirmedSeq = inputSeq; d.lastHostNanos = now
            drags[id] = d
        }
        for id in windows.keys {
            guard var w = windows[id] else { continue }
            let due = w.predictions.filter { $0.inputSeq <= inputSeq && $0.rect.intersects(rect) }
            guard !due.isEmpty else { continue }
            let unmatched = due.contains { abs($0.remX) > 2 || abs($0.remY) > 2 }
            w.predictions.removeAll { $0.inputSeq <= inputSeq && $0.rect.intersects(rect) }
            if unmatched { mismatch(&w, now: now) }
            windows[id] = w
        }
    }

    /// Drops predictions older than the timeout (nothing from the host matched them).
    public mutating func expire(now: UInt64) {
        for id in drags.keys {
            guard let d = drags[id] else { continue }
            let r = d.residual
            if d.ended && r.dx == 0 && r.dy == 0 { drags[id] = nil; continue }
            if (r.dx != 0 || r.dy != 0), now &- max(d.lastHostNanos, d.createdNanos) > timeoutNanos {
                stats.expired += 1
                if var w = windows[id] { w.confident = false; w.lastMismatchNanos = now; w.mismatches += 1; windows[id] = w }
                drags[id] = nil
            }
        }
        for id in windows.keys {
            guard var w = windows[id] else { continue }
            let stale = w.predictions.filter { now &- $0.createdNanos > timeoutNanos }
            guard !stale.isEmpty else { continue }
            w.predictions.removeAll { now &- $0.createdNanos > timeoutNanos }
            stats.expired += stale.count
            mismatch(&w, now: now)
            windows[id] = w
        }
        // Mismatched windows recover after a quiet period.
        for id in windows.keys where !windows[id]!.confident && now &- windows[id]!.lastMismatchNanos > recoverNanos { windows[id]!.confident = true }
    }

    private mutating func mismatch(_ w: inout WindowState, now: UInt64) {
        w.confident = false; w.lastMismatchNanos = now; w.mismatches += 1; stats.mismatched += 1
        w.predictions.removeAll()
    }

    /// What the renderer should displace right now, one entry per window with unconfirmed predictions.
    public func displacements() -> [Displacement] {
        var out: [Displacement] = []
        for (id, d) in drags where windows[id]?.confident ?? true {
            let r = d.residual
            if r.dx != 0 || r.dy != 0 { out.append(Displacement(kind: .drag, windowID: id, rect: d.confirmedFrame, dx: r.dx, dy: r.dy)) }
        }
        for (id, w) in windows where w.confident && !w.predictions.isEmpty {
            // Scroll: sum of remainders over the (latest) scroll rect. Drag: sum over the window frame.
            let kind = w.predictions.last!.kind
            let rect = w.predictions.last!.rect
            let dx = w.predictions.reduce(0) { $0 + $1.remX }, dy = w.predictions.reduce(0) { $0 + $1.remY }
            if dx != 0 || dy != 0 { out.append(Displacement(kind: kind, windowID: id, rect: rect, dx: dx, dy: dy)) }
        }
        return out.sorted { $0.windowID < $1.windowID }
    }

    public func isConfident(_ windowID: UInt32) -> Bool { windows[windowID]?.confident ?? true }
    public var hasPending: Bool { windows.values.contains { !$0.predictions.isEmpty } || drags.values.contains { $0.residual.dx != 0 || $0.residual.dy != 0 } }
    public mutating func forget(windowID: UInt32) { windows[windowID] = nil; drags[windowID] = nil }
}
