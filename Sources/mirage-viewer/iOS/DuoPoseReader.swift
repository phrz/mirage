import SwiftUI
import UIKit
import MirageCore

/// Reads an iPhone Duo's pose (DESIGN §3.11) from SwiftUI: the `.division` reserved region (iOS 27.1) and the
/// horizontal size class, never the orientation. Before iOS 27.1 there is no division, so the pose is closed or open flat
/// from the size class alone, and every screen lays out as it always has.
///
/// `view.onDuoPoseChange { pose = $0 }` reports the pose in the coordinate space of the view it is attached to, at once
/// and on every change. Attach it to a view that covers what the rects should be measured against (a full-screen
/// `Color.clear.ignoresSafeArea()` background gives screen coordinates, the same as a full-screen UIView's).
///
/// Test hook: `-duoPose laptop` (or `book`, `openFlat`, `closed`) as a launch argument fakes that pose with a 12 pt hinge
/// across the middle and 6 pt margins, since the Simulator folds only from Xcode's Device Hub.
extension View {
    func onDuoPoseChange(_ action: @escaping (DuoPose) -> Void) -> some View {
        modifier(DuoPoseReader(action: action))
    }
}

private struct DuoPoseReader: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let action: (DuoPose) -> Void

    func body(content: Content) -> some View {
        let compact = sizeClass == .compact
        content.onGeometryChange(for: DuoPose.self) { DuoPose.read($0, compactWidth: compact) } action: { action($0) }
    }
}

extension DuoPose {
    /// The pose of the view `proxy` measures, in its own coordinate space (fixed left-to-right, as UIKit lays out). The
    /// bounds include the safe area the proxy still reports, so they can start above or left of zero: a view that ignores
    /// the safe area is measured without it (on iOS 27.2, 34 pt short at the bottom of the inner display, 82 pt at the top
    /// of the outer one) while its UIView, and the division, span the whole of it. Measure against `bounds`, not zero.
    static func read(_ proxy: GeometryProxy, compactWidth: Bool) -> DuoPose {
        let s = proxy.safeAreaInsets
        let bounds = CGRect(x: -s.leading, y: -s.top, width: proxy.size.width + s.leading + s.trailing, height: proxy.size.height + s.top + s.bottom)
        if let faked = fakedDivisions(in: bounds) { return classify(bounds: bounds, compactWidth: compactWidth, divisions: faked) }
        guard #available(iOS 27.1, *) else { return classify(bounds: bounds, compactWidth: compactWidth, divisions: []) }
        let divisions = proxy.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed).map { r in
            let f = r.frame, m = r.margins
            let hinge = CGRect(x: f.minX + m.leading, y: f.minY + m.top, width: max(0, f.width - m.leading - m.trailing), height: max(0, f.height - m.top - m.bottom))
            return Division(frame: f, hinge: hinge, isActive: r.isActive)
        }
        return classify(bounds: bounds, compactWidth: compactWidth, divisions: divisions)
    }

    /// `-duoPose`: a fake fold for the Simulator (see above); nil when the argument is absent.
    private static func fakedDivisions(in b: CGRect) -> [Division]? {
        guard let name = UserDefaults.standard.string(forKey: "duoPose"), let kind = Kind(rawValue: name) else { return nil }
        switch kind {
        case .closed, .openFlat:
            return []
        case .laptop:
            let hinge = CGRect(x: b.minX, y: (b.midY - 6).rounded(), width: b.width, height: 12)
            return [Division(frame: hinge.insetBy(dx: 0, dy: -6), hinge: hinge)]
        case .book:
            let hinge = CGRect(x: (b.midX - 6).rounded(), y: b.minY, width: 12, height: b.height)
            return [Division(frame: hinge.insetBy(dx: -6, dy: 0), hinge: hinge)]
        }
    }
}
