import Foundation

/// The rule that keeps window pixels out of the desktop (display) layer whatever the capture does (the M3.1
/// ghost regressions on mac-daddy: the display stream carried an excluded window's pixels). Desktop tiles that
/// touch a layered window's current frame, or the area it swept in the last `historyNanos` (grown by `margin`
/// for the gap between the window list and the composited pixels), are never sent by the host and never
/// committed by the viewer. A tile becomes eligible again only once the window has been gone from it for
/// longer than the history, so it is refreshed from a capture taken after the window left.
public struct DisplayGuard {
    public var historyNanos: UInt64
    public var margin: Int
    private var history: [(id: UInt32, rect: PixelRect, nanos: UInt64)] = []

    public init(historyNanos: UInt64 = 1_000_000_000, margin: Int = 128) { self.historyNanos = historyNanos; self.margin = margin }

    /// The current frames of the layered windows (display pixels); remembers where they have been.
    public mutating func update(layered frames: [UInt32: PixelRect], now: UInt64) {
        history.removeAll { now &- $0.nanos > historyNanos }
        // A frame is remembered from the moment the window leaves it (and a window that stops being a layer
        // leaves its last frame now).
        for (id, old) in current where frames[id] != old { history.append((id, old, now)) }
        current = frames
    }
    public private(set) var current: [UInt32: PixelRect] = [:]

    /// Rects no desktop pixels may be sent or committed for, now: every current frame, and for a window that
    /// moved within the history the bounding box of everywhere it was, grown by the margin.
    public func guardedRects(now: UInt64) -> [PixelRect] {
        var out = Array(current.values)
        var ids = Set(current.keys)
        for h in history where now &- h.nanos <= historyNanos { ids.insert(h.id) }
        for id in ids {
            let past = history.filter { $0.id == id && now &- $0.nanos <= historyNanos }.map(\.rect)
            guard !past.isEmpty else { continue }
            if let f = current[id] {
                // Moving: everywhere it was in the history plus where it is, grown by the margin.
                let swept = past.reduce(f) { $0.union($1) }
                out.append(PixelRect(x: swept.x - margin, y: swept.y - margin, width: swept.width + 2 * margin, height: swept.height + 2 * margin))
            } else {
                out += past   // no longer a layer: its last frames
            }
        }
        return out
    }

    /// Tiles of `tracker` that touch any guarded rect.
    public func guardedTiles(_ tracker: TileTracker, now: UInt64) -> Set<Int> {
        Set(tracker.tiles(covering: guardedRects(now: now)))
    }

    /// Whether a desktop rect may be written now.
    public func allows(_ rect: PixelRect, now: UInt64) -> Bool {
        !guardedRects(now: now).contains { $0.intersects(rect) }
    }
}
