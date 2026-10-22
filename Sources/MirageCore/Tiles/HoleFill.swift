import Foundation

/// Hole filling for pictures with unknown parts (the warm snapshot with its windows cut out; TRUTH's reveal fill).
public enum HoleFill {
    /// Fills `holes` in a BGRA image from what surrounds them: a mask-aware push-pull (pull: 2x2 averages of the known
    /// pixels down a pyramid, carrying coverage; push: each level's unknown part from the coarser level). A smooth,
    /// colour-true continuation of the desktop around a window, never a copy of the window.
    public static func fill(_ px: inout [UInt8], width w: Int, height h: Int, holes: [PixelRect]) {
        guard !holes.isEmpty, w > 1, h > 1 else { return }
        var cov = [Float](repeating: 1, count: w * h)
        for r in holes {
            let x0 = max(0, r.x), x1 = min(w, r.maxX), y0 = max(0, r.y), y1 = min(h, r.maxY)
            guard x1 > x0, y1 > y0 else { continue }
            for y in y0..<y1 { for x in x0..<x1 { cov[y * w + x] = 0 } }
        }
        // Level 0: premultiplied by coverage.
        var levels: [(w: Int, h: Int, c: [Float], a: [Float])] = []
        var c0 = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { let m = cov[i]; c0[i * 3] = Float(px[i * 4]) * m; c0[i * 3 + 1] = Float(px[i * 4 + 1]) * m; c0[i * 3 + 2] = Float(px[i * 4 + 2]) * m }
        levels.append((w, h, c0, cov))
        while let top = levels.last, top.w > 1 || top.h > 1 {
            let nw = max(1, (top.w + 1) / 2), nh = max(1, (top.h + 1) / 2)
            var c = [Float](repeating: 0, count: nw * nh * 3), a = [Float](repeating: 0, count: nw * nh)
            for y in 0..<top.h { for x in 0..<top.w {
                let s = y * top.w + x, d = (y / 2) * nw + x / 2
                a[d] += top.a[s] * 0.25; c[d * 3] += top.c[s * 3] * 0.25; c[d * 3 + 1] += top.c[s * 3 + 1] * 0.25; c[d * 3 + 2] += top.c[s * 3 + 2] * 0.25
            } }
            levels.append((nw, nh, c, a))
        }
        // Push: normalise the coarsest, then fill each finer level's uncovered part from the one above.
        for li in stride(from: levels.count - 2, through: 0, by: -1) {
            let up = levels[li + 1]
            var cur = levels[li]
            for y in 0..<cur.h { for x in 0..<cur.w {
                let i = y * cur.w + x, u = (y / 2) * up.w + x / 2
                let ua = max(up.a[u], 1e-6)
                let miss = 1 - min(1, cur.a[i])
                for ch in 0..<3 { cur.c[i * 3 + ch] += up.c[u * 3 + ch] / ua * miss }
                cur.a[i] = 1
            } }
            levels[li] = cur
        }
        let f = levels[0]
        for i in 0..<(w * h) where cov[i] < 1 {
            px[i * 4] = UInt8(max(0, min(255, f.c[i * 3]))); px[i * 4 + 1] = UInt8(max(0, min(255, f.c[i * 3 + 1]))); px[i * 4 + 2] = UInt8(max(0, min(255, f.c[i * 3 + 2]))); px[i * 4 + 3] = 255
        }
    }
}
