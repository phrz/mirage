import Foundation

/// One axis per scroll gesture, as a Mac trackpad does: the first `decideTravel` points of travel decide vertical,
/// horizontal or free, and a locked gesture passes only its axis, momentum included. Free (both axes) only for a clearly
/// diagonal motion: within `freeTolerance` degrees of 45° once it has travelled `freeTravel`. Motion along one axis only
/// decides at once. A pause of `gestureGap` seconds starts a new gesture; so does `begin()` (fingers down).
///
/// The viewer runs it on finger travel (so what it sends and what it predicts locally move along the same axis) and the
/// host on the precise deltas it posts (`ScrollShaper`), with the same rule, so they agree: a locked gesture reaches the
/// host as single-axis deltas and is decided at once there; a free one arrives diagonal and large and stays free.
public struct ScrollAxisLock {
    public enum Axis: Equatable { case vertical, horizontal, free }

    public var decideTravel = 10.0
    public var freeTravel = 30.0
    /// Degrees either side of 45° that may be free.
    public var freeTolerance = 20.0
    public var gestureGap = 0.25

    public private(set) var axis: Axis?
    /// Counts gestures (a new one on `begin()` or after a pause).
    public private(set) var gesture = 0
    /// Travel held back while the gesture is undecided.
    public private(set) var held = (dx: 0.0, dy: 0.0)
    private var lastTime: Double?

    public init() {}

    /// A new gesture starts (fingers down): its axis is decided again.
    public mutating func begin() {
        axis = nil; held = (0, 0); lastTime = nil; gesture += 1
    }

    /// The part of a delta to pass now (nil: nothing, while the gesture is undecided or for travel off its axis). On the
    /// decision, the travel held back so far goes out at once, along the chosen axis.
    public mutating func filter(dx: Double, dy: Double, time t: Double) -> (dx: Double, dy: Double)? {
        if let l = lastTime, t - l > gestureGap { begin() }
        lastTime = t
        if let a = axis { return Self.along(a, dx, dy) }
        held.dx += dx; held.dy += dy
        guard let a = decide(final: false) else { return nil }
        axis = a
        let out = Self.along(a, held.dx, held.dy)
        held = (0, 0)
        return out
    }

    /// The fingers lifted with velocity `vx`, `vy`: the gesture is decided now if it was not (on its dominant axis), the
    /// travel still held goes out (`flush`), and the momentum keeps to the axis (`velocity`).
    public mutating func end(vx: Double, vy: Double, time t: Double) -> (flush: (dx: Double, dy: Double)?, velocity: (vx: Double, vy: Double)) {
        lastTime = t
        var flush: (dx: Double, dy: Double)? = nil
        if axis == nil {
            if held.dx != 0 || held.dy != 0 {
                axis = decide(final: true)
                if let a = axis { flush = Self.along(a, held.dx, held.dy) }
            } else if vx != 0 || vy != 0 {
                axis = abs(vy) >= abs(vx) ? .vertical : .horizontal
            }
            held = (0, 0)
        }
        guard let a = axis else { return (flush, (vx, vy)) }
        let v = Self.along(a, vx, vy) ?? (0, 0)
        return (flush, (v.dx, v.dy))
    }

    /// The axis for the travel so far (nil: not yet).
    private func decide(final: Bool) -> Axis? {
        let (x, y) = (abs(held.dx), abs(held.dy))
        if x == 0, y == 0 { return nil }
        if x == 0 { return .vertical }
        if y == 0 { return .horizontal }
        let d = (x * x + y * y).squareRoot()
        if d < decideTravel, !final { return nil }
        let degrees = atan2(y, x) * 180 / .pi   // 0: horizontal, 90: vertical
        if abs(degrees - 45) <= freeTolerance {
            if d >= freeTravel { return .free }
            if !final { return nil }
        }
        return degrees >= 45 ? .vertical : .horizontal
    }

    private static func along(_ a: Axis, _ dx: Double, _ dy: Double) -> (dx: Double, dy: Double)? {
        let r: (dx: Double, dy: Double)
        switch a {
        case .vertical: r = (0, dy)
        case .horizontal: r = (dx, 0)
        case .free: r = (dx, dy)
        }
        return r.dx == 0 && r.dy == 0 ? nil : r
    }
}

/// Shapes precise (trackpad or touch) scroll deltas before the host posts them (DESIGN §3.5): one axis per gesture
/// (`ScrollAxisLock`, in host points), as a Mac trackpad does, and whole points with the remainder carried. phrz's iPhone
/// pans carried a sideways part (39, −114 px), so Finder's icon view, which cannot scroll sideways, rubber-banded
/// horizontally: the content moved diagonally, no copy-rect verified and every scroll went lossy. Fractional deltas
/// also put the content at fractional offsets.
public struct ScrollShaper {
    public typealias Axis = ScrollAxisLock.Axis
    public var lock = ScrollAxisLock()
    public var axis: Axis? { lock.axis }
    /// A pause this long starts a new gesture (its axis is decided again).
    public var gestureGapNanos: UInt64 {
        get { UInt64(lock.gestureGap * 1e9) }
        set { lock.gestureGap = Double(newValue) / 1e9 }
    }
    private var gesture = -1
    private var rx = 0.0, ry = 0.0

    public init() {}

    /// The whole-point delta to post for this event (nil: nothing to post yet).
    public mutating func shape(dx: Double, dy: Double, nanos: UInt64) -> (dx: Int, dy: Int)? {
        let d = lock.filter(dx: dx, dy: dy, time: Double(nanos) / 1e9)
        if lock.gesture != gesture { gesture = lock.gesture; rx = 0; ry = 0 }
        guard let d else { return nil }
        rx += d.dx; ry += d.dy
        let ox = rx.rounded(.towardZero), oy = ry.rounded(.towardZero)
        rx -= ox; ry -= oy
        guard ox != 0 || oy != 0 else { return nil }
        return (Int(ox), Int(oy))
    }
}
