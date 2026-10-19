import Foundation

/// Finds a uniform translation of a rect's content between two BGRA frames (scroll, window drag).
/// Line profiles (sampled luma sums per row or column) are correlated by sum of absolute
/// differences over every candidate shift, then the winner is verified per 64-px tile with a
/// tolerance: SCK's GPU downscale and glyph rendering leave ±1–3 per channel of noise between a
/// moved pixel and its original (measured on a real scroll), so exact matching never fires.
public struct ShiftDetector {
    public struct Frame {
        public let base: UnsafeRawPointer
        public let stride: Int        // bytes per row
        public let width: Int, height: Int
        public init(base: UnsafeRawPointer, stride: Int, width: Int, height: Int) { self.base = base; self.stride = stride; self.width = width; self.height = height }
        @inline(__always) func luma(_ x: Int, _ y: Int) -> Int32 {
            let p = base.advanced(by: y * stride + x * 4)
            return Int32(p.load(fromByteOffset: 0, as: UInt8.self)) + 2 * Int32(p.load(fromByteOffset: 1, as: UInt8.self)) + Int32(p.load(fromByteOffset: 2, as: UInt8.self))
        }
    }

    public struct Result: Equatable {
        public var dx: Int, dy: Int
        /// Source rect that moved (destination = rect.offset(dx, dy)), already clipped so both lie inside the frame.
        public var rect: PixelRect
        /// 64-px tiles (frame-aligned) inside the destination that do NOT match the shifted source.
        public var mismatchedTiles: [PixelRect]
        /// Fraction of verified tiles that matched.
        public var confidence: Double
    }

    public var maxShift = 600
    public var minLines = 48
    /// The best shift's SAD must be below this fraction of the SAD at shift 0.
    public var maxRatioToZero = 0.4
    /// Tiles that fail verification are simply re-sent lossless, so the bar only guards against a
    /// wrong shift; the SAD search already chose it decisively. At a 1:1 native stream ~30 % of
    /// text tiles differ in glyph anti-aliasing after a real scroll (measured on mac-daddy).
    public var minTileConfidence = 0.55
    /// When the profile ratio test fails, the best few candidate shifts are verified tile by tile and accepted at this
    /// confidence: monospace output scrolled by one line has a line profile whose SAD at the true shift is *above* the SAD
    /// at zero (749 against 507), though the shift verifies at 0.91–0.93 (experiments/byterace finding 1: 0 copy-rects in
    /// 1168 frames of terminal output, 2405 kbps of lossless instead of 352).
    public var fallbackConfidence = 0.8
    public var fallbackCandidates = 3
    public var samplesPerLine = 32
    /// Per-channel tolerance when verifying; a tile matches if ≤ 1 % of its pixels exceed it.
    public var tolerance: Int32 = 16
    /// Diagnostics sink (MIRAGE_DEBUG_SHIFT on the host).
    public var debug: ((String) -> Void)?

    public init() {}

    /// Tries a vertical shift first, then horizontal, of `rect`'s content from `old` to `new`.
    public func detect(old: Frame, new: Frame, rect: PixelRect, tile: Int = 64) -> Result? {
        let r = rect.intersection(PixelRect(x: 0, y: 0, width: min(old.width, new.width), height: min(old.height, new.height)))
        guard r.width >= 32, r.height >= 32 else { return nil }
        if let v = detectAxis(old: old, new: new, rect: r, vertical: true, tile: tile) { return v }
        if let h = detectAxis(old: old, new: new, rect: r, vertical: false, tile: tile) { return h }
        return nil
    }

    /// Verifies a known shift (e.g. from a window frame change) instead of searching for one.
    public func verify(old: Frame, new: Frame, rect: PixelRect, dx: Int, dy: Int, tile: Int = 64) -> Result? {
        let bounds = PixelRect(x: 0, y: 0, width: min(old.width, new.width), height: min(old.height, new.height))
        let src = rect.intersection(bounds).intersection(bounds.offset(-dx, -dy))
        guard src.width >= 16, src.height >= 16 else { return nil }
        let (mismatch, conf) = verifyTiles(old: old, new: new, src: src, dx: dx, dy: dy, tile: tile)
        debug?("shift verify (\(dx),\(dy)) src \(src) conf \(conf) mismatched \(mismatch.count)")
        guard conf >= minTileConfidence else { return nil }
        return Result(dx: dx, dy: dy, rect: src, mismatchedTiles: mismatch, confidence: conf)
    }

    /// Refines an approximate 2-D offset (e.g. a window-list frame delta that is a few px off because
    /// the list was sampled after the pixels were composited): textured 16×16 patches of the old
    /// rect are searched in the new frame within ±`radius` of (dx, dy); the modal offset wins.
    public func refine(old: Frame, new: Frame, rect: PixelRect, dx: Int, dy: Int, radius: Int = 24) -> (dx: Int, dy: Int)? {
        let bounds = PixelRect(x: 0, y: 0, width: min(old.width, new.width), height: min(old.height, new.height))
        let r = rect.intersection(bounds)
        guard r.width >= 64, r.height >= 64 else { return nil }
        let p = 16
        var votes: [Int: Int] = [:]   // key = (ox + 1000) * 4096 + (oy + 1000)
        var textured = 0
        for gy in 0..<3 {
            for gx in 0..<4 {
                let px = r.x + 24 + (r.width - 48 - p) * gx / 3, py = r.y + 24 + (r.height - 48 - p) * gy / 2
                // Skip flat patches.
                var lo = Int32.max, hi = Int32.min
                for y in 0..<p { for x in 0..<p { let v = old.luma(px + x, py + y); lo = min(lo, v); hi = max(hi, v) } }
                guard hi - lo > 80 else { continue }
                textured += 1
                var best = (ox: 0, oy: 0, sad: Int64.max)
                for oy in -radius...radius {
                    for ox in -radius...radius {
                        let nx = px + dx + ox, ny = py + dy + oy
                        guard nx >= 0, ny >= 0, nx + p <= bounds.width, ny + p <= bounds.height else { continue }
                        var acc: Int64 = 0
                        for y in 0..<p { for x in 0..<p { acc += Int64(abs(new.luma(nx + x, ny + y) - old.luma(px + x, py + y))) } }
                        if acc < best.sad { best = (ox, oy, acc) }
                    }
                }
                if best.sad <= Int64(p * p) * 12 { votes[(best.ox + 1000) * 4096 + best.oy + 1000, default: 0] += 1 }
            }
        }
        guard textured >= 3, let (key, n) = votes.max(by: { $0.value < $1.value }), n >= 3, n * 2 >= textured else {
            debug?("shift refine around (\(dx),\(dy)): no consensus (textured \(textured), votes \(votes.values.sorted(by: >).prefix(3).map { $0 }))")
            return nil
        }
        debug?("shift refine around (\(dx),\(dy)) → (\(dx + key / 4096 - 1000),\(dy + key % 4096 - 1000)) with \(n)/\(textured) patches")
        return (dx + key / 4096 - 1000, dy + key % 4096 - 1000)
    }

    private func profile(_ f: Frame, rect: PixelRect, vertical: Bool) -> [Int32] {
        let lines = vertical ? rect.height : rect.width
        let across = vertical ? rect.width : rect.height
        let n = min(samplesPerLine, across)
        var out = [Int32](repeating: 0, count: lines)
        for l in 0..<lines {
            var acc: Int32 = 0
            for s in 0..<n {
                let a = across <= n ? s : s * (across - 1) / max(1, n - 1)
                acc &+= vertical ? f.luma(rect.x + a, rect.y + l) : f.luma(rect.x + l, rect.y + a)
            }
            out[l] = acc
        }
        return out
    }

    private func detectAxis(old: Frame, new: Frame, rect: PixelRect, vertical: Bool, tile: Int) -> Result? {
        let pOld = profile(old, rect: rect, vertical: vertical), pNew = profile(new, rect: rect, vertical: vertical)
        let lines = pNew.count
        guard lines >= minLines * 2 else { return nil }
        // Texture: a flat profile matches every shift equally; require some variation.
        let mean = pNew.reduce(0) { $0 + Int($1) } / lines
        let variation = pNew.reduce(0) { $0 + abs(Int($1) - mean) } / lines
        guard variation > 4 * Int(samplesPerLine) else { debug?("shift \(vertical ? "v" : "h") rect \(rect): flat profile"); return nil }
        let limit = min(maxShift, lines - minLines)
        var best = (shift: 0, sad: Double.infinity)
        var zero = Double.infinity
        var sads: [(shift: Int, sad: Double)] = []
        pOld.withUnsafeBufferPointer { po in pNew.withUnsafeBufferPointer { pn in
            for s in -limit...limit {
                // new[l] ≈ old[l - s]
                let l0 = max(0, s), l1 = min(lines, lines + s)
                guard l1 - l0 >= minLines else { continue }
                var acc: Int64 = 0
                var l = l0
                while l < l1 { acc &+= Int64(abs(pn[l] &- po[l - s])); l += 1 }
                let sad = Double(acc) / Double(l1 - l0)
                if s == 0 { zero = sad }
                if s != 0 && sad < best.sad { best = (s, sad) }
                if s != 0 { sads.append((s, sad)) }
            }
        } }
        debug?("shift \(vertical ? "v" : "h") rect \(rect) zero \(Int(zero)) best \(best.shift):\(Int(best.sad)) var \(variation)")
        guard best.sad < maxRatioToZero * zero else {
            // The ratio test failed: verify the best local minima of the profile SAD (distinct shifts, ±2 lines apart).
            var picked: [Int] = []
            for c in sads.sorted(by: { $0.sad < $1.sad }) where picked.count < fallbackCandidates && !picked.contains(where: { abs($0 - c.shift) <= 2 }) { picked.append(c.shift) }
            for shift in picked {
                let dx = vertical ? 0 : shift, dy = vertical ? shift : 0
                let bounds = PixelRect(x: 0, y: 0, width: min(old.width, new.width), height: min(old.height, new.height))
                let src = rect.intersection(bounds).intersection(bounds.offset(-dx, -dy)).intersection(rect.offset(-dx, -dy))
                guard src.width >= 16, src.height >= 16 else { continue }
                let (mismatch, conf) = verifyTiles(old: old, new: new, src: src, dx: dx, dy: dy, tile: tile)
                debug?("shift fallback verify (\(dx),\(dy)) conf \(conf)")
                if conf >= fallbackConfidence { return Result(dx: dx, dy: dy, rect: src, mismatchedTiles: mismatch, confidence: conf) }
            }
            return nil
        }
        let dx = vertical ? 0 : best.shift, dy = vertical ? best.shift : 0
        let bounds = PixelRect(x: 0, y: 0, width: min(old.width, new.width), height: min(old.height, new.height))
        let src = rect.intersection(bounds).intersection(bounds.offset(-dx, -dy)).intersection(rect.offset(-dx, -dy))
        guard src.width >= 16, src.height >= 16 else { return nil }
        let (mismatch, conf) = verifyTiles(old: old, new: new, src: src, dx: dx, dy: dy, tile: tile)
        debug?("shift verify (\(dx),\(dy)) src \(src) conf \(conf) mismatched \(mismatch.count)")
        guard conf >= minTileConfidence else { return nil }
        return Result(dx: dx, dy: dy, rect: src, mismatchedTiles: mismatch, confidence: conf)
    }

    /// Compares new[src + (dx,dy)] against old[src] per frame-aligned tile of the destination, with tolerance.
    private func verifyTiles(old: Frame, new: Frame, src: PixelRect, dx: Int, dy: Int, tile: Int) -> ([PixelRect], Double) {
        let dst = src.offset(dx, dy)
        var mismatched: [PixelRect] = []
        var total = 0, ok = 0
        let c0 = dst.x / tile, c1 = (dst.maxX - 1) / tile, r0 = dst.y / tile, r1 = (dst.maxY - 1) / tile
        let tol = tolerance
        for row in r0...r1 {
            for col in c0...c1 {
                let t = PixelRect(x: col * tile, y: row * tile, width: tile, height: tile).intersection(dst)
                guard !t.isEmpty else { continue }
                total += 1
                var bad = 0
                let allowed = max(1, t.area / 50)
                rows: for y in t.y..<t.maxY {
                    let a = new.base.advanced(by: y * new.stride + t.x * 4).assumingMemoryBound(to: UInt8.self)
                    let b = old.base.advanced(by: (y - dy) * old.stride + (t.x - dx) * 4).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<t.width {
                        let o = x * 4
                        if abs(Int32(a[o]) - Int32(b[o])) > tol || abs(Int32(a[o + 1]) - Int32(b[o + 1])) > tol || abs(Int32(a[o + 2]) - Int32(b[o + 2])) > tol {
                            bad += 1
                            if bad > allowed { break rows }
                        }
                    }
                }
                if bad <= allowed { ok += 1 } else { mismatched.append(t) }
            }
        }
        return (mismatched, total == 0 ? 0 : Double(ok) / Double(total))
    }
}
