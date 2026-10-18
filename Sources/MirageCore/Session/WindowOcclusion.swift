import Foundation

/// How much of a window the host shows (nothing in front of it, on the display), from the window
/// list alone: the host sends no pixels of a layer the viewer cannot see until they are uncovered.
public enum WindowTrackerOcclusion {
    /// The visible fraction of `w` (0…1 of its whole frame) and the rects of the windows in front
    /// of it (display coordinates). Only windows with a lower z count; coverage is sampled on a 16×16
    /// grid of the on-screen part (an exact union area is not worth it).
    public static func occlusion(of w: ControlMessage.WindowInfo, in list: [ControlMessage.WindowInfo], display: PixelRect) -> (visibleFraction: Double, covering: [PixelRect]) {
        let onScreen = w.frame.intersection(display)
        guard !onScreen.isEmpty else { return (0, []) }
        var covering: [PixelRect] = []
        for o in list where o.z < w.z && o.id != w.id {
            let i = o.frame.intersection(onScreen)
            if !i.isEmpty { covering.append(i) }
        }
        let onScreenShare = Double(onScreen.area) / Double(max(1, w.frame.area))
        if covering.isEmpty { return (onScreenShare, []) }
        var uncovered = 0, total = 0
        for gy in 0..<16 { for gx in 0..<16 {
            let px = onScreen.x + onScreen.width * (2 * gx + 1) / 32, py = onScreen.y + onScreen.height * (2 * gy + 1) / 32
            total += 1
            if !covering.contains(where: { $0.contains(px, py) }) { uncovered += 1 }
        } }
        return (Double(uncovered) / Double(total) * onScreenShare, covering)
    }
}
