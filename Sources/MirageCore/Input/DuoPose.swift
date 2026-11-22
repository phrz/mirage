import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// How a foldable (iPhone Duo) is being held, from geometry only (DESIGN §3.11): the view's size, its size class and the
/// fold's `.division` reserved region. Never from orientation: the inner display ignores supported orientations.
///
/// - closed: the outer display (compact width), no active division;
/// - open flat: the inner display (regular width), no active division (an iPad lands here too);
/// - book: partly folded with the hinge running top to bottom;
/// - laptop: partly folded with the hinge running side to side. Laptop and tent (propped on its edges) look the same
///   to the geometry; whether a keyboard is up tells them apart, and that is the screen's business, not the pose's.
///
/// All rects are in the coordinate space of the view the division was read in.
public struct DuoPose: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable { case closed, openFlat, book, laptop }

    /// One `.division` reserved region as the platform reports it.
    public struct Division: Equatable, Sendable {
        /// The region's frame, including the margins interactive content keeps from the hinge.
        public var frame: CGRect
        /// The hinge itself: `frame` without those margins.
        public var hinge: CGRect
        public var isActive: Bool
        public init(frame: CGRect, hinge: CGRect? = nil, isActive: Bool = true) {
            self.frame = frame; self.hinge = hinge ?? frame; self.isActive = isActive
        }
    }

    public var kind: Kind
    /// The view's bounds the pose was classified in.
    public var bounds: CGRect
    /// The active division (book and laptop only).
    public var division: Division?

    public init(kind: Kind, bounds: CGRect, division: Division? = nil) {
        self.kind = kind; self.bounds = bounds; self.division = division
    }

    /// Classifies a pose. `compactWidth` is the horizontal size class; `divisions` every `.division` region reported
    /// (inactive ones are ignored).
    public static func classify(bounds: CGRect, compactWidth: Bool, divisions: [Division]) -> DuoPose {
        if let d = divisions.first(where: { $0.isActive && !$0.frame.intersection(bounds).isNull }) {
            return DuoPose(kind: hingeIsVertical(d, in: bounds) ? .book : .laptop, bounds: bounds, division: d)
        }
        return DuoPose(kind: compactWidth ? .closed : .openFlat, bounds: bounds)
    }

    /// The hinge runs along the region's long side; a degenerate region (a point, or a square) runs across the view's
    /// long side, as a fold splits a display into two halves.
    static func hingeIsVertical(_ d: Division, in bounds: CGRect) -> Bool {
        let r = d.hinge.width > 0 || d.hinge.height > 0 ? d.hinge : d.frame
        if r.height != r.width { return r.height > r.width }
        return bounds.width >= bounds.height
    }

    /// Partly folded, either way.
    public var isFolded: Bool { kind == .book || kind == .laptop }

    /// Laptop: everything above the hinge, where the picture goes. Every other pose: the whole bounds (the picture is a
    /// canvas and may cross a vertical hinge).
    public var upperRegion: CGRect {
        guard kind == .laptop, let d = division else { return bounds }
        let bottom = min(max(d.hinge.minY, bounds.minY), bounds.maxY)
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bottom - bounds.minY)
    }

    /// Laptop: everything below the division's band (its margins included), where the bar and the keyboard deck go.
    public var lowerRegion: CGRect? {
        guard kind == .laptop, let d = division else { return nil }
        let top = min(max(d.frame.maxY, bounds.minY), bounds.maxY)
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.maxY - top)
    }

    /// Book: the half on the left of the division's band (its margins included).
    public var leftRegion: CGRect? {
        guard kind == .book, let d = division else { return nil }
        let right = min(max(d.frame.minX, bounds.minX), bounds.maxX)
        return CGRect(x: bounds.minX, y: bounds.minY, width: right - bounds.minX, height: bounds.height)
    }

    /// Book: the half on the right of the division's band (its margins included).
    public var rightRegion: CGRect? {
        guard kind == .book, let d = division else { return nil }
        let left = min(max(d.frame.maxX, bounds.minX), bounds.maxX)
        return CGRect(x: left, y: bounds.minY, width: bounds.maxX - left, height: bounds.height)
    }

    /// How far the picture keeps from each edge of `bounds` so it is never fitted, panned or caret-scrolled under the
    /// hinge: laptop reserves the hinge and everything below it. A vertical hinge reserves nothing (the canvas crosses
    /// it). Returned as (top, left, bottom, right) so it maps onto any platform's insets type.
    public var pictureInsets: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        let u = upperRegion
        return (u.minY - bounds.minY, u.minX - bounds.minX, bounds.maxY - u.maxY, bounds.maxX - u.maxX)
    }
}
