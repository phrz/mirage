import Foundation

/// Shapes precise (trackpad or touch) scroll deltas before the host posts them (DESIGN §3.5): one axis per gesture, as a
/// Mac trackpad does, and whole points with the remainder carried. phrz's iPhone pans carried a sideways part (39, −114
/// px), so Finder's icon view, which cannot scroll sideways, rubber-banded horizontally: the content moved diagonally,
/// no copy-rect verified and every scroll went lossy. Fractional deltas also put the content at fractional offsets.
public struct ScrollShaper {
    public enum Axis { case vertical, horizontal }
    /// A pause this long starts a new gesture (its axis is decided again).
    public var gestureGapNanos: UInt64 = 250_000_000
    public private(set) var axis: Axis?
    private var lastNanos: UInt64 = 0
    private var rx = 0.0, ry = 0.0

    public init() {}

    /// The whole-point delta to post for this event (nil: nothing to post yet).
    public mutating func shape(dx: Double, dy: Double, nanos: UInt64) -> (dx: Int, dy: Int)? {
        if lastNanos == 0 || nanos &- lastNanos > gestureGapNanos { axis = nil; rx = 0; ry = 0 }
        lastNanos = nanos
        if axis == nil, dx != 0 || dy != 0 { axis = abs(dy) >= abs(dx) ? .vertical : .horizontal }
        switch axis {
        case .vertical: ry += dy
        case .horizontal: rx += dx
        case nil: return nil
        }
        let ox = rx.rounded(.towardZero), oy = ry.rounded(.towardZero)
        rx -= ox; ry -= oy
        guard ox != 0 || oy != 0 else { return nil }
        return (Int(ox), Int(oy))
    }
}
