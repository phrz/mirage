import Foundation
import CoreGraphics

/// Presentation-only zoom and pan for a touch client: where the stream's picture is drawn in the view. Nothing here
/// reaches the host; the stream and what the host sends are the same at every zoom (DESIGN: the host never re-streams
/// for a pinch). All coordinates are view points; `content` is the picture's own size (stream pixels), used only for
/// its aspect and for mapping picture-pixel rects (the caret) into the view.
///
/// Rules, per axis: a picture that fits the visible area stays put (centred in the container, lifted above the
/// on-screen keyboard when that covers it); a picture larger than the visible area can be panned until its edges meet
/// the visible area's edges, never further (a scroll view's rubber band past them is presentation only, `scrolled(to:)`).
/// The visible area is what nothing covers: the safe area (the Dynamic Island, the home indicator and the rounded corners
/// in either orientation), below the control pill, above the keyboard. The container, where the picture is fitted at
/// zoom 1, can be larger (landscape fits the full height, under the pill and the home indicator), so there a fitted
/// picture still pans by what they cover.
public struct ZoomViewport: Equatable {
    /// Where the picture is fitted at zoom 1 (view points).
    public private(set) var container: CGRect = .zero
    /// What nothing covers but the keyboard (view points): the safe area below the control pill. Defaults to the container.
    public private(set) var unobstructed: CGRect = .zero
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

    /// The part of the view the picture can be seen in: the unobstructed area above the keyboard.
    public var visible: CGRect {
        let u = unobstructed
        guard let k = keyboardTop, k < u.maxY else { return u }
        let bottom = max(u.minY, min(u.maxY, k))
        return CGRect(x: u.minX, y: u.minY, width: u.width, height: bottom - u.minY)
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
        return CGRect(x: origin.x, y: origin.y, width: f.width * zoom, height: f.height * zoom)
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

    /// New container, unobstructed area, keyboard or content size. A container or content change (rotation, a new
    /// stream) keeps the zoom and the picture point at the centre of the visible area (at fit: the picture centred in
    /// the container); a keyboard or obstruction change keeps the picture where it is, clamped. No change: nothing moves
    /// (a scroll view's rubber band may hold the picture past its range meanwhile).
    public mutating func setLayout(container c: CGRect, unobstructed u: CGRect? = nil, keyboardTop k: Double?, content s: CGSize) {
        let u = u.map { let i = $0.intersection(c); return i.isNull || i.isEmpty ? c : i } ?? c
        guard c != container || u != unobstructed || k != keyboardTop || s != content else { return }
        let reanchor = c != container || s != content
        let had = pictureRect.width > 0 && pictureRect.height > 0 && content.width > 0
        let mid = CGPoint(x: visible.midX, y: visible.midY)
        let anchor = had ? normalized(mid) : CGPoint(x: 0.5, y: 0.5)
        container = c; unobstructed = u; keyboardTop = k; content = s
        if reanchor {
            let p = pictureRect.size, v = visible
            origin = zoom <= minZoom + 1e-9
                ? CGPoint(x: c.midX - p.width / 2, y: c.midY - p.height / 2)
                : CGPoint(x: v.midX - anchor.x * p.width, y: v.midY - anchor.y * p.height)
        }
        clamp()
    }

    /// Where the picture's origin may be, per axis: one point on an axis where it fits the visible area, else from its
    /// far edge meeting the visible area's far edge to its near edge meeting the near one.
    public var originRange: (x: ClosedRange<Double>, y: ClosedRange<Double>) {
        let p = pictureRect.size, v = visible, c = container
        return (Self.axisRange(size: p.width, lo: v.minX, hi: v.maxX, centre: c.midX),
                Self.axisRange(size: p.height, lo: v.minY, hi: v.maxY, centre: c.midY))
    }

    static func axisRange(size p: Double, lo: Double, hi: Double, centre: Double) -> ClosedRange<Double> {
        if p <= hi - lo + 0.5 { let o = min(max(centre - p / 2, lo), hi - p); return o...o }   // fits: centred, inside the span
        return (hi - p)...lo                                                                   // larger: edges stop at the span's
    }

    /// Keeps the picture within the rules above.
    public mutating func clamp() {
        let r = originRange
        origin.x = min(max(origin.x, r.x.lowerBound), r.x.upperBound)
        origin.y = min(max(origin.y, r.y.lowerBound), r.y.upperBound)
    }

    /// A scroll view's position, as is: its rubber band may hold the picture past `originRange` until it springs back.
    public mutating func scrolled(to o: CGPoint) { origin = o }

    /// Edge insets (view points), as UIKit's.
    public struct Insets: Equatable {
        public var top, left, bottom, right: Double
        public init(top: Double, left: Double, bottom: Double, right: Double) { self.top = top; self.left = left; self.bottom = bottom; self.right = right }
    }

    /// The content insets that give a scroll view filling a `size` view (its content the picture: contentSize =
    /// `pictureRect.size`, contentOffset = −origin) exactly `originRange` as its scrollable range: its offset runs from
    /// −left to contentSize + right − size, so its rubber band starts where the picture's edges meet the visible area's.
    public func scrollInsets(viewSize b: CGSize) -> Insets {
        let r = originRange, p = pictureRect.size
        return Insets(top: r.y.upperBound, left: r.x.upperBound,
                      bottom: Double(b.height) - Double(p.height) - r.y.lowerBound, right: Double(b.width) - Double(p.width) - r.x.lowerBound)
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
        zoom = min(maxZoom, max(minZoom, z))
        let p = pictureRect.size
        origin = CGPoint(x: anchor.x - n.x * p.width, y: anchor.y - n.y * p.height)
        clamp()
    }

    /// Moves the picture by a finger's travel (or a follow's push), clamped.
    public mutating func pan(by d: CGPoint) {
        origin.x += d.x; origin.y += d.y
        clamp()
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
