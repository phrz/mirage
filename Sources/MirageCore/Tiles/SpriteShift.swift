import Foundation

/// A small sprite moved vertically in the overlay (a bouncing Dock icon: a pure translation of one icon). The viewer already
/// holds the icon, so a bounce is one copy-rect per frame plus the few blocks the copy leaves wrong (the icon's rows over the
/// Dock's glass, the uncovered strip): a few hundred bytes, at full frame rate (phrz, 2026-10-23: 3 fps half-size lossy
/// tiles made it a stutter). The scroll detector's thresholds (128-px regions, 12 changed tiles) are for whole windows.
public enum SpriteShift {
    public struct Result: Equatable {
        /// Source rect (destination = rect.offset(0, dy)).
        public var rect: PixelRect
        public var dy: Int
        /// Blocks where the viewer, after the copy, would not hold the new frame's bytes: sent exact.
        public var residual: [PixelRect]
    }
    /// The vertical shift of `region`'s content from `old` to `new`, by exact row matches (row hashes over the region's
    /// columns); rows of one colour are no evidence. Nil unless one shift explains at least `minRows` changed rows and at
    /// least half of them, and clearly beats the runner-up.
    public static func detect(old: ShiftDetector.Frame, new: ShiftDetector.Frame, region: PixelRect, minRows: Int = 16, block: Int = 16) -> Result? {
        let bounds = PixelRect(x: 0, y: 0, width: min(old.width, new.width), height: min(old.height, new.height))
        let r = region.intersection(bounds)
        guard r.width >= 16, r.height >= 32 else { return nil }
        func rowHash(_ f: ShiftDetector.Frame, _ y: Int) -> (UInt64, Bool) {
            let p = f.base.advanced(by: y * f.stride + r.x * 4).assumingMemoryBound(to: UInt32.self)
            var h: UInt64 = 1469598103934665603
            let first = p[0]; var flat = true
            for i in 0..<r.width { let v = p[i]; if v != first { flat = false }; h = (h ^ UInt64(v)) &* 1099511628211 }
            return (h, flat)
        }
        let n = r.height
        var ho = [UInt64](repeating: 0, count: n), hn = [UInt64](repeating: 0, count: n), flatNew = [Bool](repeating: false, count: n)
        for i in 0..<n { ho[i] = rowHash(old, r.y + i).0; let (h, f) = rowHash(new, r.y + i); hn[i] = h; flatNew[i] = f }
        let changed = (0..<n).filter { !flatNew[$0] && hn[$0] != ho[$0] }
        guard changed.count >= minRows else { return nil }
        var best = (dy: 0, score: 0), second = 0
        for dy in -(n - 16)...(n - 16) where dy != 0 {
            var score = 0
            for i in changed { let j = i - dy; if j >= 0 && j < n && hn[i] == ho[j] { score += 1 } }
            if score > best.score { second = best.score; best = (dy, score) } else if score > second { second = score }
        }
        guard best.score >= minRows, best.score * 2 >= changed.count, Double(second) <= Double(best.score) * 0.7 else { return nil }
        let dy = best.dy
        // The icon's old place: the region rows that, shifted, stay in the region.
        let src = r.intersection(r.offset(0, -dy))
        guard src.height >= 16 else { return nil }
        let dst = src.offset(0, dy)
        // What the viewer holds after the copy, against the new frame, in blocks.
        var residual: [PixelRect] = []
        var by = r.y
        while by < r.maxY {
            let bh = min(block, r.maxY - by)
            var bx = r.x
            while bx < r.maxX {
                let bw = min(block, r.maxX - bx)
                var wrong = false
                for y in by..<(by + bh) {
                    let sy = (y >= dst.y && y < dst.maxY) ? y - dy : y
                    if memcmp(new.base.advanced(by: y * new.stride + bx * 4), old.base.advanced(by: sy * old.stride + bx * 4), bw * 4) != 0 { wrong = true; break }
                }
                if wrong {
                    // Merge with the block to the left on the same row.
                    if let last = residual.last, last.y == by, last.height == bh, last.maxX == bx { residual[residual.count - 1].width += bw }
                    else { residual.append(PixelRect(x: bx, y: by, width: bw, height: bh)) }
                }
                bx += bw
            }
            by += bh
        }
        return Result(rect: src, dy: dy, residual: residual)
    }
}
