import Foundation
import CoreGraphics

/// Presentation-only zoom and pan for a touch client: where the stream's picture is drawn in the view. Nothing here
/// reaches the host; the stream and what the host sends are the same at every zoom (DESIGN: the host never re-streams
/// for a pinch). All coordinates are view points; `content` is the picture's own size (stream pixels), used only for
/// its aspect and for mapping picture-pixel rects (the caret) into the view.
///
/// Rules, per axis: a picture that fits the visible area stays put (centred in the container, lifted above the
/// on-screen keyboard when that covers it); a picture larger than the visible area can be panned until its edges meet
/// the visible area's edges (the container's top and sides, the keyboard's top), never further.
public struct ZoomViewport: Equatable {
    /// Where the picture lives: the view's safe area.
    public private(set) var container: CGRect = .zero
    /// The top of the on-screen keyboard (view points), nil while it is hidden.
    public private(set) var keyboardTop: Double?
    /// The picture's own size (stream pixels).
    public private(set) var content: CGSize = .zero
    /// 1 = the picture fitted into the container.
    public private(set) var zoom = 1.0
    /// The picture's top-left corner, view points.
    public private(set) var origin: CGPoint = .zero
    public var minZoom = 1.0
    public var maxZoom = 3.0

    public init() {}

    /// The part of the container the keyboard leaves visible.
    public var visible: CGRect {
        guard let k = keyboardTop, k < container.maxY else { return container }
        let bottom = max(container.minY, min(container.maxY, k))
        return CGRect(x: container.minX, y: container.minY, width: container.width, height: bottom - container.minY)
    }

    /// The picture at zoom 1: the content's aspect fitted into the container.
    public var fitSize: CGSize {
        guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else { return container.size }
        let aspect = content.width / content.height
        if container.width / container.height > aspect { return CGSize(width: container.height * aspect, height: container.height) }
        return CGSize(width: container.width, height: container.width / aspect)
    }

    /// Where the picture is drawn (view points).
    public var pictureRect: CGRect {
        let f = fitSize
        let o = overscroll
        return CGRect(x: origin.x + o.x, y: origin.y + o.y, width: f.width * zoom, height: f.height * zoom)
    }

    /// Zoom at which one host display pixel is one device pixel: `hostPixelWidth` is the host display's native width
    /// in pixels, `screenScale` the device's pixels per point.
    public func oneToOneZoom(hostPixelWidth: Double, screenScale: Double) -> Double {
        let w = Double(fitSize.width) * screenScale
        return w > 0 && hostPixelWidth > 0 ? hostPixelWidth / w : 1
    }

    /// The zoom range for a host: from fit to 1:1 host pixels and half as far again, at least 3×.
    public mutating func setZoomRange(oneToOne: Double) {
        maxZoom = max(3, oneToOne * 1.5)
        if zoom > maxZoom { setZoom(maxZoom, about: CGPoint(x: visible.midX, y: visible.midY)) }
    }

    // MARK: Layout

    /// New container, keyboard or content size. A container or content change (rotation, a new stream) keeps the zoom and
    /// the picture point at the centre of the visible area; a keyboard change keeps the picture where it is, clamped.
    public mutating func setLayout(container c: CGRect, keyboardTop k: Double?, content s: CGSize) {
        let reanchor = c != container || s != content
        let had = pictureRect.width > 0 && pictureRect.height > 0 && content.width > 0
        let mid = CGPoint(x: visible.midX, y: visible.midY)
        let anchor = had ? normalized(mid) : CGPoint(x: 0.5, y: 0.5)
        container = c; keyboardTop = k; content = s
        if reanchor {
            let p = pictureRect.size, v = visible
            origin = CGPoint(x: v.midX - anchor.x * p.width, y: v.midY - anchor.y * p.height)
        }
        clamp()
    }

    /// Keeps the picture within the rules above.
    public mutating func clamp() {
        let p = pictureRect.size, v = visible, c = container
        origin.x = Self.clampAxis(origin.x, size: p.width, lo: v.minX, hi: v.maxX, centre: c.midX)
        origin.y = Self.clampAxis(origin.y, size: p.height, lo: v.minY, hi: v.maxY, centre: c.midY)
    }

    static func clampAxis(_ o: Double, size p: Double, lo: Double, hi: Double, centre: Double) -> Double {
        if p <= hi - lo + 0.5 { return min(max(centre - p / 2, lo), hi - p) }   // fits: centred, inside the visible span
        return min(max(o, hi - p), lo)                                         // larger: its edges stop at the span's
    }

    // MARK: Mapping

    /// A view point as a picture position (0…1 on both axes inside the picture).
    public func normalized(_ p: CGPoint) -> CGPoint {
        let r = pictureRect
        guard r.width > 0, r.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)
    }
    /// A picture position (0…1) as a view point.
    public func viewPoint(_ n: CGPoint) -> CGPoint {
        let r = pictureRect
        return CGPoint(x: r.minX + n.x * r.width, y: r.minY + n.y * r.height)
    }
    /// A rect in picture pixels (`content` units) as view points.
    public func viewRect(contentRect q: CGRect) -> CGRect {
        let r = pictureRect
        guard content.width > 0, content.height > 0 else { return .zero }
        let kx = r.width / content.width, ky = r.height / content.height
        return CGRect(x: r.minX + q.minX * kx, y: r.minY + q.minY * ky, width: q.width * kx, height: q.height * ky)
    }

    // MARK: Gestures

    /// Zooms to `z` (clamped to the range) keeping the picture point under `anchor` where it is.
    public mutating func setZoom(_ z: Double, about anchor: CGPoint) {
        let n = normalized(anchor)
        pull = .zero
        zoom = min(maxZoom, max(minZoom, z))
        let p = pictureRect.size
        origin = CGPoint(x: anchor.x - n.x * p.width, y: anchor.y - n.y * p.height)
        clamp()
    }

    /// Moves the picture by a finger's travel.
    public mutating func pan(by d: CGPoint) {
        origin.x += d.x; origin.y += d.y
        clamp()
    }

    /// A direct-touch swipe's travel beyond where the picture can go (view points): shown as a small rubber-band offset
    /// (`overscroll`, at most `rubberLimit`) that springs back once the finger lifts (`relax`). Presentation only.
    public private(set) var pull: CGPoint = .zero
    public static let rubberLimit = 24.0
    public var overscroll: CGPoint { CGPoint(x: Self.rubber(pull.x), y: Self.rubber(pull.y)) }
    static func rubber(_ x: Double) -> Double {
        let l = rubberLimit
        return (x < 0 ? -1 : 1) * l * (1 - exp(-abs(x) / l))
    }

    /// Moves the picture by a finger's travel, clamped as `pan(by:)`; what the clamp holds back stretches the rubber band
    /// (and travel back the other way relaxes it first). At fit nothing moves: the picture only gives a little and returns.
    public mutating func pan(by d: CGPoint, rubberBand: Bool) {
        guard rubberBand else { pan(by: d); return }
        // Travel back toward the edge undoes the stretch first.
        func unstretch(_ d: Double, _ pull: Double) -> (rest: Double, pull: Double) {
            guard pull != 0, d != 0, (d < 0) != (pull < 0) else { return (d, pull) }
            let take = abs(d) >= abs(pull) ? -pull : d
            return (d - take, pull + take)
        }
        let ux = unstretch(d.x, pull.x), uy = unstretch(d.y, pull.y)
        let before = origin
        pan(by: CGPoint(x: ux.rest, y: uy.rest))
        pull = CGPoint(x: ux.pull + ux.rest - (origin.x - before.x), y: uy.pull + uy.rest - (origin.y - before.y))
    }

    /// One frame of the rubber band springing back (time constant `tau`). Returns true while it is still stretched.
    @discardableResult
    public mutating func relax(dt: Double, tau: Double = 0.08) -> Bool {
        guard pull != .zero else { return false }
        let k = exp(-max(0, dt) / tau)
        pull = CGPoint(x: pull.x * k, y: pull.y * k)
        if abs(pull.x) < 0.3, abs(pull.y) < 0.3 { pull = .zero }
        return pull != .zero
    }

    /// Sets zoom and origin outright (an animation's frame), clamped.
    public mutating func set(zoom z: Double, origin o: CGPoint) {
        zoom = min(maxZoom, max(minZoom, z)); origin = o
        clamp()
    }

    /// Two-finger double tap: back to fit when zoomed, else to 1:1 host pixels (2× where 1:1 is not larger than fit).
    public func toggleTarget(oneToOne: Double) -> Double {
        if zoom > minZoom + 0.01 { return minZoom }
        return min(maxZoom, oneToOne > 1.05 ? oneToOne : 2)
    }

    // MARK: Following

    /// Pointer follow: when the pointer (view point `p`) comes within `margin` of the visible area's edge on an axis where
    /// the picture is larger than that area, the picture moves so the pointer stays `margin` inside (it pushes the view).
    public mutating func follow(_ p: CGPoint, margin: Double = 40) {
        let v = visible
        let mx = min(margin, v.width / 4), my = min(margin, v.height / 4)
        var d = CGPoint.zero
        if p.x < v.minX + mx { d.x = v.minX + mx - p.x } else if p.x > v.maxX - mx { d.x = v.maxX - mx - p.x }
        if p.y < v.minY + my { d.y = v.minY + my - p.y } else if p.y > v.maxY - my { d.y = v.maxY - my - p.y }
        if d != .zero { pan(by: d) }
    }

    /// The zoom from which typing keeps the caret in view.
    public static let caretFollowZoom = 1.5

    /// Caret follow: the origin that brings the caret (view rect) `margin` inside the visible area with the least travel,
    /// or nil when it is already there, the zoom is below `caretFollowZoom`, or the picture cannot move that way.
    public func caretTarget(_ caret: CGRect, margin: Double = 24) -> CGPoint? {
        guard zoom >= Self.caretFollowZoom - 1e-9 else { return nil }
        let v = visible
        func shift(_ lo: Double, _ hi: Double, _ a: Double, _ b: Double, _ m: Double) -> Double {
            let m = min(m, max(0, (hi - lo - (b - a)) / 2))
            if b - a > hi - lo { return (lo + hi) / 2 - (a + b) / 2 }   // larger than the area: centre it
            if a < lo + m { return lo + m - a }
            if b > hi - m { return hi - m - b }
            return 0
        }
        let d = CGPoint(x: shift(v.minX, v.maxX, caret.minX, caret.maxX, margin), y: shift(v.minY, v.maxY, caret.minY, caret.maxY, margin))
        guard abs(d.x) > 0.5 || abs(d.y) > 0.5 else { return nil }
        var t = self
        t.pan(by: d)
        let moved = abs(t.origin.x - origin.x) > 0.5 || abs(t.origin.y - origin.y) > 0.5
        return moved ? t.origin : nil
    }

    /// One frame of a gentle pan toward `target` (exponential, time constant `tau` seconds). Returns true once there.
    @discardableResult
    public mutating func glide(toward target: CGPoint, dt: Double, tau: Double = 0.12) -> Bool {
        let k = 1 - exp(-max(0, dt) / tau)
        var o = CGPoint(x: origin.x + (target.x - origin.x) * k, y: origin.y + (target.y - origin.y) * k)
        let arrived = abs(target.x - o.x) < 0.5 && abs(target.y - o.y) < 0.5
        if arrived { o = target }
        origin = o
        clamp()
        return arrived
    }
}
