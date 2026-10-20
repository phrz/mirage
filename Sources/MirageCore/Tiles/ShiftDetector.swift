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

    /// The copy-rect without its leading and trailing tile rows and columns that mostly do not match: what a scroll area
    /// under a translucent toolbar or status bar carries (Finder's scroll view extends under its Liquid Glass toolbar, so the
    /// copy stacked the toolbar on the viewer until corrections landed a round trip later). Nil when too little is left.
    public static func trimmed(_ r: Result, tile: Int = 64) -> Result? {
        var dst = r.rect.offset(r.dx, r.dy)
        let bad = r.mismatchedTiles
        func mostlyBad(_ strip: PixelRect) -> Bool {
            guard strip.area > 0 else { return false }
            return bad.reduce(0) { $0 + $1.intersection(strip).area } * 2 >= strip.area
        }
        while dst.height > tile {   // top rows
            let end = min(dst.maxY, (dst.y / tile + 1) * tile)
            guard mostlyBad(PixelRect(x: dst.x, y: dst.y, width: dst.width, height: end - dst.y)) else { break }
            dst = PixelRect(x: dst.x, y: end, width: dst.width, height: dst.maxY - end)
        }
        while dst.height > tile {   // bottom rows
            let start = max(dst.y, ((dst.maxY - 1) / tile) * tile)
            guard mostlyBad(PixelRect(x: dst.x, y: start, width: dst.width, height: dst.maxY - start)) else { break }
            dst = PixelRect(x: dst.x, y: dst.y, width: dst.width, height: start - dst.y)
        }
        while dst.width > tile {    // left columns
            let end = min(dst.maxX, (dst.x / tile + 1) * tile)
            guard mostlyBad(PixelRect(x: dst.x, y: dst.y, width: end - dst.x, height: dst.height)) else { break }
            dst = PixelRect(x: end, y: dst.y, width: dst.maxX - end, height: dst.height)
        }
        while dst.width > tile {    // right columns
            let start = max(dst.x, ((dst.maxX - 1) / tile) * tile)
            guard mostlyBad(PixelRect(x: start, y: dst.y, width: dst.maxX - start, height: dst.height)) else { break }
            dst = PixelRect(x: dst.x, y: dst.y, width: start - dst.x, height: dst.height)
        }
        guard dst.width >= tile, dst.height >= tile else { return nil }
        var out = r
        out.rect = dst.offset(-r.dx, -r.dy)
        out.mismatchedTiles = bad.map { $0.intersection(dst) }.filter { !$0.isEmpty }
        return out
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
    /// The fallback's shift must be at least this many pixels (a 1-px "shift" of mostly flat content verifies trivially) and
    /// must explain this share of the tiles that changed between the frames.
    public var fallbackMinShift = 8
    public var fallbackExplained = 0.6
    public var samplesPerLine = 32
    /// Per-channel tolerance when verifying a photographic tile (others must be byte-exact); it matches if ≤ 2 % of its pixels
    /// exceed it.
    public var tolerance: Int32 = 16
    /// Diagnostics sink (MIRAGE_DEBUG_SHIFT on the host).
    public var debug: ((String) -> Void)?

    public init() {}

    /// Tries a vertical shift first, then horizontal, of `rect`'s content from `old` to `new`.
    /// `hint`: the shift the input suggests (the wheel delta in pixels along the axis), a tie-breaker between candidates that
    /// verify equally well (periodic content: an icon grid repeats at its row pitch); exact verification decides first.
    public func detect(old: Frame, new: Frame, rect: PixelRect, tile: Int = 64, hint: (dx: Int, dy: Int)? = nil) -> Result? {
        let r = rect.intersection(PixelRect(x: 0, y: 0, width: min(old.width, new.width), height: min(old.height, new.height)))
        guard r.width >= 32, r.height >= 32 else { return nil }
        if let v = detectAxis(old: old, new: new, rect: r, vertical: true, tile: tile, hint: hint?.dy) { return v }
        if let h = detectAxis(old: old, new: new, rect: r, vertical: false, tile: tile, hint: hint?.dx) { return h }
        return nil
    }
    /// Profile-SAD candidates within this factor of the best are all verified (periodic content ties at several shifts).
    public var tieMargin = 1.15
    public var tieCandidates = 3

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

    private func detectAxis(old: Frame, new: Frame, rect: PixelRect, vertical: Bool, tile: Int, hint: Int? = nil) -> Result? {
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
            for shift in picked where abs(shift) >= fallbackMinShift {
                let dx = vertical ? 0 : shift, dy = vertical ? shift : 0
                let bounds = PixelRect(x: 0, y: 0, width: min(old.width, new.width), height: min(old.height, new.height))
                let src = rect.intersection(bounds).intersection(bounds.offset(-dx, -dy)).intersection(rect.offset(-dx, -dy))
                guard src.width >= 16, src.height >= 16 else { continue }
                let (mismatch, conf) = verifyTiles(old: old, new: new, src: src, dx: dx, dy: dy, tile: tile)
                // Flat tiles verify at any shift; what counts is the tiles that changed: the shift must explain most of them.
                let (changed, explained) = explainedChange(old: old, new: new, src: src, dx: dx, dy: dy, mismatched: mismatch, tile: tile)
                debug?("shift fallback verify (\(dx),\(dy)) conf \(conf) explains \(explained)/\(changed) changed tiles")
                if conf >= fallbackConfidence, changed >= 2, Double(explained) >= fallbackExplained * Double(changed) {
                    return Result(dx: dx, dy: dy, rect: src, mismatchedTiles: mismatch, confidence: conf)
                }
            }
            return nil
        }
        // Near-ties (periodic content: Finder's icon grid matches at every multiple of its row pitch): verify each, keep the one
        // with the most exact tiles; the input's delta breaks a tie. Exact verification makes a wrong period harmless for
        // correctness (only byte-identical tiles count as explained), so this choice only decides how much is corrected.
        var candidates = [best.shift]
        for c in sads.sorted(by: { $0.sad < $1.sad }) where candidates.count < tieCandidates && c.sad <= best.sad * tieMargin && !candidates.contains(where: { abs($0 - c.shift) <= 2 }) { candidates.append(c.shift) }
        let bounds = PixelRect(x: 0, y: 0, width: min(old.width, new.width), height: min(old.height, new.height))
        var chosen: Result? = nil
        for shift in candidates {
            let dx = vertical ? 0 : shift, dy = vertical ? shift : 0
            let src = rect.intersection(bounds).intersection(bounds.offset(-dx, -dy)).intersection(rect.offset(-dx, -dy))
            guard src.width >= 16, src.height >= 16 else { continue }
            let (mismatch, conf) = verifyTiles(old: old, new: new, src: src, dx: dx, dy: dy, tile: tile)
            debug?("shift verify (\(dx),\(dy)) src \(src) conf \(conf) mismatched \(mismatch.count)\(candidates.count > 1 ? " (one of \(candidates.count) near-ties)" : "")")
            guard conf >= minTileConfidence else { continue }
            let r = Result(dx: dx, dy: dy, rect: src, mismatchedTiles: mismatch, confidence: conf)
            if let c = chosen {
                // Most exact area first (byte-identical copies from a period away are correct but cover less); then the input's delta.
                let area = Double(src.area) * conf, cArea = Double(c.rect.area) * c.confidence
                let better = area > cArea * 1.02
                let tie = abs(area - cArea) <= cArea * 0.02
                let closer = hint.map { abs(abs(shift) - abs($0)) < abs(abs(vertical ? c.dy : c.dx) - abs($0)) } ?? false   // magnitude only
                if better || tie && closer { chosen = r }
            } else { chosen = r }
        }
        return chosen
    }

    /// Destination tiles that changed in place (new ≠ old at the same position), and how many of those the shift explains
    /// (they match the shifted source).
    private func explainedChange(old: Frame, new: Frame, src: PixelRect, dx: Int, dy: Int, mismatched: [PixelRect], tile: Int) -> (changed: Int, explained: Int) {
        let dst = src.offset(dx, dy)
        let bad = Set(mismatched.map { $0.y / tile * 100_000 + $0.x / tile })
        var changed = 0, explained = 0
        for row in (dst.y / tile)...((dst.maxY - 1) / tile) {
            for col in (dst.x / tile)...((dst.maxX - 1) / tile) {
                let t = PixelRect(x: col * tile, y: row * tile, width: tile, height: tile).intersection(dst)
                guard !t.isEmpty else { continue }
                var differs = false
                rows: for y in t.y..<t.maxY {
                    if memcmp(new.base.advanced(by: y * new.stride + t.x * 4), old.base.advanced(by: y * old.stride + t.x * 4), t.width * 4) != 0 { differs = true; break rows }
                }
                guard differs else { continue }
                changed += 1
                if !bad.contains(row * 100_000 + col) { explained += 1 }
            }
        }
        return (changed, explained)
    }

    /// Diagnostics for a destination tile that failed verification: the share of its pixels that differ from the shifted source,
    /// their mean and largest channel difference, and the same share for the shift ±1 px along the axis (a fractional scroll
    /// offset re-rasterises everything a little: small differences everywhere, and a neighbouring shift no better).
    public static func diffStats(old: Frame, new: Frame, tile t: PixelRect, dx: Int, dy: Int) -> (fraction: Double, mean: Double, max: Int, fractionMinus: Double, fractionPlus: Double) {
        func stats(_ ox: Int, _ oy: Int) -> (Double, Double, Int) {
            var n = 0, d = 0, sum = 0, mx = 0
            for y in t.y..<t.maxY {
                let sy = y - oy
                guard sy >= 0, sy < old.height else { continue }
                let a = new.base.advanced(by: y * new.stride).assumingMemoryBound(to: UInt8.self)
                let b = old.base.advanced(by: sy * old.stride).assumingMemoryBound(to: UInt8.self)
                for x in t.x..<t.maxX {
                    let sx = x - ox
                    guard sx >= 0, sx < old.width else { continue }
                    n += 1
                    var m = 0
                    for c in 0..<3 { m = Swift.max(m, abs(Int(a[x * 4 + c]) - Int(b[sx * 4 + c]))) }
                    if m > 0 { d += 1; sum += m; mx = Swift.max(mx, m) }
                }
            }
            return (n == 0 ? 0 : Double(d) / Double(n), d == 0 ? 0 : Double(sum) / Double(d), mx)
        }
        let (f, mean, mx) = stats(dx, dy)
        let vertical = dx == 0
        let (fm, _, _) = stats(vertical ? dx : dx - 1, vertical ? dy - 1 : dy)
        let (fp, _, _) = stats(vertical ? dx : dx + 1, vertical ? dy + 1 : dy)
        return (f, mean, mx, fm, fp)
    }

    /// Whether a tile must verify byte-exact: anything but photographic content (more than 1024 colours in a 64-px tile;
    /// anti-aliased text and UI stay far below).
    private func exactRequired(_ f: Frame, _ t: PixelRect) -> Bool {
        TileCodec.colourCount(base: f.base.advanced(by: t.y * f.stride + t.x * 4), width: t.width, height: t.height, stride: f.stride, limit: 1024) <= 1024
    }

    /// Compares new[src + (dx,dy)] against old[src] per frame-aligned tile of the destination: byte-exact for UI and text,
    /// with tolerance for photographic tiles.
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
                // Byte-exact first (memcmp per row); only a photographic tile may then pass within the tolerance. At native scale
                // scrolled UI pixels are bit-identical, and a tolerance let a wrong-period copy of a near-identical label row pass
                // (phrz's repeated Finder rows).
                var exact = true
                for y in t.y..<t.maxY where memcmp(new.base.advanced(by: y * new.stride + t.x * 4), old.base.advanced(by: (y - dy) * old.stride + (t.x - dx) * 4), t.width * 4) != 0 { exact = false; break }
                if exact { ok += 1; continue }
                if exactRequired(new, t) { mismatched.append(t); continue }
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
