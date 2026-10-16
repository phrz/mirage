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
    public mutating func hostCopyRect(windowID: UInt32, rect: PixelRect, dx: Int, dy: Int, now: UInt64) {
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
    public var hasPending: Bool { windows.values.contains { !$0.predictions.isEmpty } }
    public mutating func forget(windowID: UInt32) { windows[windowID] = nil }
}
