import Foundation
import CoreGraphics

/// Two fingers on a touch screen: a scroll unless they clearly pinch, decided once per gesture.
///
/// The old rule (a pinch once the fingers spread or close by 5 % before their centre travels 12 pt) took phrz's natural
/// two-finger scrolls for pinches: fingers scrolling together drift apart or together by 5–15 % and are never quite
/// parallel. A pinch now needs all of:
/// - the distance between the fingers changed by at least `pinchRatio` of where it started *and* `pinchDistance` points;
/// - that change clearly dominates the centre's travel (`dominance` times it): fingers that travel together scroll;
/// - it happens early: while a finger has travelled at most `windowTravel` points, or within `windowTime` of the fingers
///   starting to move (a slow, deliberate pinch takes longer than 150 ms to reach 40 pt, a scroll never gets that far
///   without its centre dominating).
/// Otherwise it is a scroll: as soon as the centre has travelled `scrollSlop` points and at least as far as the distance
/// between the fingers changed, or when the window closes. Either decision holds until the fingers lift.
public struct TwoFingerClassifier {
    public enum Decision: Equatable { case undecided, scroll, pinch }

    public var pinchRatio = 0.18
    public var pinchDistance = 40.0
    public var dominance = 1.5
    public var scrollSlop = 12.0
    public var windowTime = 0.15
    public var windowTravel = 60.0
    /// Travel (points) of either finger that counts as the fingers starting to move (`windowTime` runs from then, so
    /// fingers resting before they move do not use it up).
    public var onsetTravel = 2.0

    public private(set) var decision = Decision.undecided
    public private(set) var startA = CGPoint.zero, startB = CGPoint.zero
    public private(set) var startSpread = 0.0
    public private(set) var startCentroid = CGPoint.zero
    private var onset: Double?

    public init() {}
    public init(_ a: CGPoint, _ b: CGPoint) { restart(a, b) }

    /// A new gesture: the fingers are down at `a` and `b` (the thresholds stay).
    public mutating func restart(_ a: CGPoint, _ b: CGPoint) {
        startA = a; startB = b
        startSpread = Self.distance(a, b)
        startCentroid = Self.midpoint(a, b)
        decision = .undecided; onset = nil
    }

    /// The fingers moved: the decision so far (once made, it never changes).
    @discardableResult
    public mutating func update(_ a: CGPoint, _ b: CGPoint, time t: Double) -> Decision {
        guard decision == .undecided else { return decision }
        let fingerTravel = max(Self.distance(a, startA), Self.distance(b, startB))
        if onset == nil, fingerTravel >= onsetTravel { onset = t }
        let change = abs(Self.distance(a, b) - startSpread)
        let travel = Self.distance(Self.midpoint(a, b), startCentroid)
        let inWindow = fingerTravel <= windowTravel || t - (onset ?? t) <= windowTime
        if inWindow, change >= pinchDistance, change >= pinchRatio * max(startSpread, 1), change > dominance * travel {
            decision = .pinch
        } else if travel >= scrollSlop, change <= travel {
            decision = .scroll
        } else if !inWindow {
            decision = .scroll
        }
        return decision
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }
    static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
}
