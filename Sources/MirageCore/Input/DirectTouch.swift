import Foundation
import CoreGraphics

/// How touches on the picture become Mac input (iOS). Persisted under `defaultsKey`; direct touch unless set otherwise.
public enum TouchMode: String, CaseIterable, Sendable {
    /// Workbench style: every touch acts where it lands (DirectTouch). The default.
    case direct
    /// The pointer moves relative to one finger, with acceleration; touches act at the pointer.
    case trackpad

    public static let defaultsKey = "touchMode"
    public static func stored(_ d: UserDefaults = .standard) -> TouchMode { d.string(forKey: defaultsKey).flatMap(TouchMode.init(rawValue:)) ?? .direct }
    public func store(_ d: UserDefaults = .standard) { d.set(rawValue, forKey: Self.defaultsKey) }
    public var title: String { self == .direct ? "Direct touch" : "Trackpad" }
}

/// Direct touch ("workbench") gestures as a pure state machine over raw touches, so the disambiguation is testable:
/// - a tap clicks where it lands (taps in a row at about the same place double- and triple-click, at the first tap's point);
/// - a finger held still for `holdDelay` presses the button there; moving then drags, lifting releases (held and lifted
///   without moving: a long click);
/// - a finger that moves past `slop` before that pans the view (presentation only), with momentum after it lifts;
/// - two fingers travelling together scroll at the point where they came down (the pointer goes there first), with
///   momentum; spreading or closing them zooms (`pinchThreshold`, decided before the scroll's `multiSlop`);
/// - a two-finger tap right-clicks at its centre, after `twoFingerTapWait` in case a second one makes it a double tap
///   (which toggles the zoom instead);
/// - three fingers pan the view.
/// Nothing is position-agnostic: every action that reaches the Mac carries the point it applies to. Points are view
/// points; times are seconds on any monotonic clock. `tick` must be called regularly (the display link): it fires the
/// hold and the deferred right click.
public struct DirectTouch {
    public enum Action: Equatable {
        case click(at: CGPoint, count: Int)
        case holdBegan(at: CGPoint)
        case holdMoved(to: CGPoint)
        case holdEnded(at: CGPoint)
        case rightClick(at: CGPoint)
        case scrollBegan(at: CGPoint)
        case scroll(dx: Double, dy: Double)
        case scrollEnded(vx: Double, vy: Double)
        case pinchBegan(at: CGPoint)
        case pinch(scale: Double, at: CGPoint)
        case pinchEnded
        case pan(dx: Double, dy: Double)
        case panEnded(vx: Double, vy: Double)
        case zoomToggle(at: CGPoint)
    }

    public var holdDelay = 0.35
    /// Travel (points) under which a finger is still a tap or a hold.
    public var slop = 10.0
    /// Travel of two fingers' centre that makes them a scroll.
    public var multiSlop = 12.0
    /// |ln(spread / spread at start)| that makes two fingers a pinch.
    public var pinchThreshold = 0.05
    public var doubleClickInterval = 0.45, doubleClickSlop = 24.0
    /// Two fingers down for longer than this are no tap; a second two-finger tap within `twoFingerTapWait` is a double tap.
    public var twoFingerTapMax = 0.4, twoFingerTapWait = 0.3

    public enum Multi: Equatable { case undecided, scroll, zoom, viewPan }
    public enum Phase: Equatable {
        case idle
        case pending(start: CGPoint, time: Double)
        case holding
        case panning
        case multi(Multi)
        /// The gesture is over; waiting for the remaining fingers to lift.
        case done
    }
    public private(set) var phase = Phase.idle
    private var touches: [Int: CGPoint] = [:]
    private var order: [Int] = []
    private var multiStart = (centroid: CGPoint.zero, spread: 1.0, time: 0.0)
    private var multiIDs: [Int] = []
    private var lastCentroid = CGPoint.zero, lastPan = CGPoint.zero
    private var maxTouches = 0
    private var samples: [(t: Double, p: CGPoint)] = []
    private var lastClick: (time: Double, at: CGPoint, count: Int)?
    private var pendingRight: (time: Double, at: CGPoint)?

    public init() {}

    /// Whether a hold (the button pressed) is in progress.
    public var holding: Bool { phase == .holding }
    public var touchCount: Int { touches.count }

    public mutating func began(_ id: Int, at p: CGPoint, time t: Double) -> [Action] {
        var out: [Action] = []
        touches[id] = p; order.append(id)
        maxTouches = max(maxTouches, touches.count)
        switch phase {
        case .idle:
            phase = .pending(start: p, time: t); samples = [(t, p)]; lastPan = p
        case .pending, .panning:
            if case .panning = phase { out.append(.panEnded(vx: 0, vy: 0)) }
            startMulti(time: t)
        case .multi(let m):
            if touches.count >= 3, m == .undecided || m == .scroll {
                if m == .scroll { out.append(.scrollEnded(vx: 0, vy: 0)) }
                phase = .multi(.viewPan); multiIDs = order; lastCentroid = centroid(multiIDs); samples = [(t, lastCentroid)]
            } else if m == .viewPan {
                multiIDs = order; lastCentroid = centroid(multiIDs)   // the centre jumps with a new finger: re-base
            }
        case .holding, .done:
            break   // a held drag ignores other fingers; a finished gesture waits for every finger to lift
        }
        return out
    }

    public mutating func moved(_ id: Int, to p: CGPoint, time t: Double) -> [Action] {
        guard touches[id] != nil else { return [] }
        touches[id] = p
        var out: [Action] = []
        switch phase {
        case .pending(let start, _):
            guard Self.distance(p, start) > slop else { break }
            flushRight(&out)
            phase = .panning
            out.append(.pan(dx: p.x - start.x, dy: p.y - start.y)); lastPan = p
            addSample(t, p)
        case .panning:
            out.append(.pan(dx: p.x - lastPan.x, dy: p.y - lastPan.y)); lastPan = p
            addSample(t, p)
        case .holding:
            if id == order.first { out.append(.holdMoved(to: p)) }
        case .multi(let m):
            let c = centroid(multiIDs)
            switch m {
            case .undecided:
                let spread = log(max(1, self.spread(multiIDs)) / multiStart.spread)
                if abs(spread) > pinchThreshold {
                    flushRight(&out)
                    phase = .multi(.zoom)
                    out.append(.pinchBegan(at: multiStart.centroid))
                    out.append(.pinch(scale: exp(spread), at: c))
                } else if Self.distance(c, multiStart.centroid) > multiSlop {
                    flushRight(&out)
                    phase = .multi(.scroll)
                    out.append(.scrollBegan(at: multiStart.centroid))
                    out.append(.scroll(dx: c.x - multiStart.centroid.x, dy: c.y - multiStart.centroid.y))
                    addSample(t, c)
                }
            case .scroll:
                out.append(.scroll(dx: c.x - lastCentroid.x, dy: c.y - lastCentroid.y)); addSample(t, c)
            case .zoom:
                out.append(.pinch(scale: max(1, self.spread(multiIDs)) / multiStart.spread, at: c))
            case .viewPan:
                out.append(.pan(dx: c.x - lastCentroid.x, dy: c.y - lastCentroid.y)); addSample(t, c)
            }
            lastCentroid = c
        case .idle, .done:
            break
        }
        return out
    }

    public mutating func ended(_ id: Int, at p: CGPoint, time t: Double) -> [Action] {
        guard touches[id] != nil else { return [] }
        touches[id] = p
        var out: [Action] = []
        switch phase {
        case .pending:
            flushRight(&out)
            out.append(tap(at: p, time: t))
            phase = .done
        case .holding:
            if id == order.first { out.append(.holdEnded(at: p)); phase = .done }
        case .panning:
            addSample(t, p)
            let v = velocity(at: t)
            out.append(.panEnded(vx: v.x, vy: v.y))
            phase = .done
        case .multi(let m):
            switch m {
            case .undecided:
                // The first finger of an undecided two-finger touch lifts: it was a tap if it was short (it goes out once
                // the double-tap wait is over, or turns a waiting one into a double tap).
                if maxTouches == 2, t - multiStart.time <= twoFingerTapMax {
                    if let r = pendingRight, t - r.time <= twoFingerTapWait + twoFingerTapMax {
                        pendingRight = nil; out.append(.zoomToggle(at: multiStart.centroid))
                    } else {
                        pendingRight = (t, multiStart.centroid)
                    }
                }
                phase = .done
            case .scroll:
                addSample(t, centroid(multiIDs))
                let v = velocity(at: t)
                out.append(.scrollEnded(vx: v.x, vy: v.y)); phase = .done
            case .zoom:
                out.append(.pinchEnded); phase = .done
            case .viewPan:
                addSample(t, centroid(multiIDs))
                let v = velocity(at: t)
                out.append(.panEnded(vx: v.x, vy: v.y)); phase = .done
            }
        case .idle, .done:
            break
        }
        remove(id)
        return out
    }

    /// The system took the touches (a call, an alert), or the mode changed: whatever is in progress ends, without a click.
    public mutating func cancel() -> [Action] {
        var out: [Action] = []
        switch phase {
        case .holding: out.append(.holdEnded(at: touches[order.first ?? -1] ?? .zero))
        case .panning: out.append(.panEnded(vx: 0, vy: 0))
        case .multi(.scroll): out.append(.scrollEnded(vx: 0, vy: 0))
        case .multi(.zoom): out.append(.pinchEnded)
        case .multi(.viewPan): out.append(.panEnded(vx: 0, vy: 0))
        default: break
        }
        touches = [:]; order = []; phase = .idle; maxTouches = 0; pendingRight = nil
        return out
    }

    /// Time passing: a still finger becomes a hold, a lone two-finger tap becomes a right click.
    public mutating func tick(time t: Double) -> [Action] {
        var out: [Action] = []
        if case .pending(_, let t0) = phase, touches.count == 1, t - t0 >= holdDelay, let id = order.first, let p = touches[id] {
            flushRight(&out)
            phase = .holding
            out.append(.holdBegan(at: p))
        }
        // Not while fingers that may still be the second tap of a double tap are down.
        if let r = pendingRight, t - r.time >= twoFingerTapWait {
            switch phase {
            case .pending, .multi(.undecided): break
            default: pendingRight = nil; out.append(.rightClick(at: r.at))
            }
        }
        return out
    }

    /// A waiting two-finger tap goes out before anything that follows it.
    private mutating func flushRight(_ out: inout [Action]) {
        if let r = pendingRight { pendingRight = nil; out.append(.rightClick(at: r.at)) }
    }

    // MARK: Internals

    private mutating func startMulti(time t: Double) {
        if touches.count >= 3 {
            phase = .multi(.viewPan); multiIDs = order
        } else {
            phase = .multi(.undecided); multiIDs = Array(order.prefix(2))
        }
        let c = centroid(multiIDs)
        multiStart = (c, max(1, spread(multiIDs)), t)
        lastCentroid = c
        samples = [(t, c)]
    }

    private mutating func tap(at p: CGPoint, time t: Double) -> Action {
        if let l = lastClick, t - l.time <= doubleClickInterval, Self.distance(p, l.at) <= doubleClickSlop {
            let n = min(3, l.count + 1)
            lastClick = (t, l.at, n)
            return .click(at: l.at, count: n)
        }
        lastClick = (t, p, 1)
        return .click(at: p, count: 1)
    }

    private mutating func remove(_ id: Int) {
        touches[id] = nil; order.removeAll { $0 == id }
        if touches.isEmpty { phase = .idle; maxTouches = 0 }
    }

    private func centroid(_ ids: [Int]) -> CGPoint {
        let ps = ids.compactMap { touches[$0] }
        guard !ps.isEmpty else { return .zero }
        return CGPoint(x: ps.map(\.x).reduce(0, +) / Double(ps.count), y: ps.map(\.y).reduce(0, +) / Double(ps.count))
    }
    private func spread(_ ids: [Int]) -> Double {
        let ps = ids.compactMap { touches[$0] }
        guard ps.count >= 2 else { return 0 }
        return Self.distance(ps[0], ps[1])
    }
    private mutating func addSample(_ t: Double, _ p: CGPoint) {
        samples.append((t, p))
        samples.removeAll { t - $0.t > 0.15 }
    }
    /// Velocity over the last ~0.1 s (points per second); zero when the finger rested before lifting.
    private func velocity(at t: Double) -> CGPoint {
        guard let last = samples.last, t - last.t < 0.1, let first = samples.first(where: { last.t - $0.t <= 0.1 }), last.t - first.t > 0.005 else { return .zero }
        let dt = last.t - first.t
        return CGPoint(x: (last.p.x - first.p.x) / dt, y: (last.p.y - first.p.y) / dt)
    }
    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }
}
