import Foundation

/// Unified mode on a phone or tablet fits a host window to the pane showing it for as long as it is shown
/// (`WindowCommand.temporary`). The frame each window had before its first such resize (global points, top-left origin) is
/// kept here and put back on a temporary `.restore`, when the viewer leaves Unified mode and when the session ends.
public struct TemporaryFrames: Equatable {
    public private(set) var original: [UInt32: CGRect] = [:]

    public init() {}

    public var isEmpty: Bool { original.isEmpty }

    /// Before a temporary resize: the window's frame now, unless one from an earlier temporary resize is kept already.
    public mutating func willResize(_ id: UInt32, current: CGRect) {
        if original[id] == nil { original[id] = current }
    }

    /// The frame to put back, forgotten.
    public mutating func take(_ id: UInt32) -> CGRect? { original.removeValue(forKey: id) }

    /// Every frame to put back, forgotten.
    public mutating func takeAll() -> [UInt32: CGRect] {
        defer { original = [:] }
        return original
    }

    /// A window that went away: its frame is dropped.
    public mutating func forget(_ id: UInt32) { original[id] = nil }

    /// The frame a temporary resize applies: `size` clamped to the visible area (menu bar and Dock left out) of the display
    /// the window is on (the one holding most of it), and an origin that keeps all of it there. The origin asked for (or else
    /// the window's current top-left) is kept where the window fits from it; otherwise moved just far enough.
    /// `visibleAreas`: each display's visible area, global points, top-left origin.
    public static func fit(size: CGSize, origin: CGPoint?, current: CGRect, visibleAreas: [CGRect]) -> CGRect {
        let want = CGRect(origin: origin ?? current.origin, size: size)
        guard let area = visibleAreas.max(by: { overlap($0, current) < overlap($1, current) }).flatMap({ overlap($0, current) > 0 ? $0 : nil })
                ?? visibleAreas.max(by: { overlap($0, want) < overlap($1, want) }) else { return want }
        let w = min(size.width, area.width), h = min(size.height, area.height)
        let x = min(max(want.minX, area.minX), area.maxX - w)
        let y = min(max(want.minY, area.minY), area.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }
}
