import Foundation

/// The host's tolerant tile diff (DESIGN §3.3a), here so it can be tested. Every tile of a capture is a candidate,
/// the display's too: ScreenCaptureKit's dirty rects can leave a change out (macOS 27's Dock tooltips vanish without
/// one), and the next capture already holds the new pixels, so a change outside the reported rects would never be
/// found again (phrz's tile-aligned ghost tooltips, M3.2).
public enum TileDiff {
    /// Bounding box of the pixels that differ beyond the tolerance inside `r`, or nil if none do.
    /// Sparse updates (a typed glyph, a caret) are a fraction of their 64-px tile; sending the tight
    /// box instead of the tile halves typing's bytes. Alpha counts too (a window's rounded corners).
    public static func changedBox(_ a: ShiftDetector.Frame, _ b: ShiftDetector.Frame, _ r: PixelRect, tolerance: Int32, alphaLayer: Bool = false) -> PixelRect? {
        let n = r.width * 4
        var x0 = Int.max, x1 = -1, y0 = Int.max, y1 = -1
        let tol = tolerance
        for y in r.y..<r.maxY {
            let pa = a.base.advanced(by: y * a.stride + r.x * 4), pb = b.base.advanced(by: y * b.stride + r.x * 4)
            if memcmp(pa, pb, n) == 0 { continue }
            let ua = pa.assumingMemoryBound(to: UInt8.self), ub = pb.assumingMemoryBound(to: UInt8.self)
            var rowChanged = false
            for x in 0..<r.width {
                let o = x * 4
                var changed = abs(Int32(ua[o]) - Int32(ub[o])) > tol || abs(Int32(ua[o + 1]) - Int32(ub[o + 1])) > tol || abs(Int32(ua[o + 2]) - Int32(ub[o + 2])) > tol
                if alphaLayer {
                    // A window's rounded corners: the anti-aliased edge pixels re-render a little differently from
                    // frame to frame (measured: four 23×23 corner boxes "changing" on a still window, ±10 levels);
                    // semi-transparent pixels get a wide tolerance, fully transparent ones never count.
                    let aa = Int32(ua[o + 3]), ab = Int32(ub[o + 3])
                    if aa == 0 && ab == 0 { changed = false }
                    else if aa < 255 || ab < 255 { changed = abs(aa - ab) > 48 || abs(Int32(ua[o]) - Int32(ub[o])) > 48 || abs(Int32(ua[o + 1]) - Int32(ub[o + 1])) > 48 || abs(Int32(ua[o + 2]) - Int32(ub[o + 2])) > 48 }
                    else if abs(aa - ab) > tol { changed = true }
                }
                if changed {
                    rowChanged = true
                    if x < x0 { x0 = x }
                    if x > x1 { x1 = x }
                }
            }
            if rowChanged { if y < y0 { y0 = y }; y1 = y }
        }
        guard x1 >= 0 else { return nil }
        return PixelRect(x: r.x + x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    /// Tiles whose pixels changed between two frames (all tiles are candidates; `reported` only counts the ones
    /// ScreenCaptureKit did not report, for the log).
    public static func changedTiles(_ a: ShiftDetector.Frame, _ b: ShiftDetector.Frame, tracker: TileTracker, tolerance: Int32, alphaLayer: Bool = false, reported: Set<Int> = []) -> (tiles: [Int], unreported: Int) {
        let tiles = (0..<tracker.tileCount).filter { changedBox(a, b, tracker.rect(of: $0), tolerance: tolerance, alphaLayer: alphaLayer) != nil }
        return (tiles, tiles.filter { !reported.contains($0) }.count)
    }
}
