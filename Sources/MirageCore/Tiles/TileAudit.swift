import Foundation

/// Picture audit (M3.2): what the viewer shows of the desktop is checked against what the host believes it shows.
/// Every few seconds the host fingerprints desktop tiles it considers delivered (crisp, visible, unchanged for a while)
/// and the viewer fingerprints the same tiles of its canvas; tiles that differ are asked for again. A fingerprint is the
/// mean luma of each 16×16 block of a 64-px tile (16 bytes): tolerant of the lossy and near-lossless formats and of the
/// capture's ±4 noise, but not of a stale label or a window fragment. Whatever loses a write (phrz's Dock tooltip
/// fragments that never cleared, causes not pinned down), the picture heals within one audit period.
public enum TileAudit {
    public static let blocks = 4   // per side
    public static let tolerance: UInt8 = 10

    /// Fingerprint of `rect` in a BGRA frame (rect inside the frame).
    public static func fingerprint(_ f: ShiftDetector.Frame, _ rect: PixelRect) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: blocks * blocks)
        let bw = max(1, rect.width / blocks), bh = max(1, rect.height / blocks)
        for by in 0..<blocks {
            for bx in 0..<blocks {
                let x0 = rect.x + bx * bw, y0 = rect.y + by * bh
                let x1 = bx == blocks - 1 ? rect.maxX : x0 + bw, y1 = by == blocks - 1 ? rect.maxY : y0 + bh
                var acc = 0, n = 0
                var y = y0
                while y < y1 {   // every other row and column: plenty for a mean
                    let row = f.base.advanced(by: y * f.stride).assumingMemoryBound(to: UInt8.self)
                    var x = x0
                    while x < x1 { let o = x * 4; acc += Int(row[o]) + 2 * Int(row[o + 1]) + Int(row[o + 2]); n += 4; x += 2 }
                    y += 2
                }
                out[by * blocks + bx] = UInt8(min(255, n == 0 ? 0 : acc / n))
            }
        }
        return out
    }

    public static func differs(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>, tolerance: UInt8 = tolerance) -> Bool {
        guard a.count == b.count else { return true }
        for (x, y) in zip(a, b) where (x > y ? x - y : y - x) > tolerance { return true }
        return false
    }
}
