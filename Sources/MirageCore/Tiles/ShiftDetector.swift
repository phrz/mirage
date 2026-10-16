import Foundation

/// Finds a uniform translation of a rect's content between two BGRA frames (scroll, window drag),
/// cheaply: per-line signatures voted into a shift histogram, then a tile-level verification.
/// No FFT: UI content has long exact matches, so hashing rows beats phase correlation here.
public struct ShiftDetector {
    public struct Frame {
        public let base: UnsafeRawPointer
        public let stride: Int        // bytes per row
        public let width: Int, height: Int
        public init(base: UnsafeRawPointer, stride: Int, width: Int, height: Int) { self.base = base; self.stride = stride; self.width = width; self.height = height }
        @inline(__always) func pixel(_ x: Int, _ y: Int) -> UInt32 {
            base.advanced(by: y * stride + x * 4).loadUnaligned(as: UInt32.self) & 0x00FF_FFFF
        }
    }

    public struct Result: Equatable {
        public var dx: Int, dy: Int
        /// Source rect that moved (destination = rect.offset(dx, dy)), already clipped so both lie inside the frame.
        public var rect: PixelRect
        /// 64-px tiles (frame indices by `tile` grid) inside the destination that do NOT match the shifted source.
        public var mismatchedTiles: [PixelRect]
        /// Fraction of verified tiles that matched.
        public var confidence: Double
    }

    public var maxShift = 1200
    public var minMatchedLines = 12
    public var minLineScore = 0.6
    public var minTileConfidence = 0.80
    public var samplesPerLine = 24

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
        guard conf >= minTileConfidence else { return nil }
        return Result(dx: dx, dy: dy, rect: src, mismatchedTiles: mismatch, confidence: conf)
    }

    private func detectAxis(old: Frame, new: Frame, rect: PixelRect, vertical: Bool, tile: Int) -> Result? {
        let lines = vertical ? rect.height : rect.width
        let across = vertical ? rect.width : rect.height
        let n = min(samplesPerLine, across)
        // Signature per line: hash of n evenly spaced samples; flag uniform lines (they match anything).
        func signatures(_ f: Frame) -> ([UInt64], [Bool]) {
            var sig = [UInt64](repeating: 0, count: lines)
            var textured = [Bool](repeating: false, count: lines)
            for l in 0..<lines {
                var h: UInt64 = 0xcbf29ce484222325
                var first: UInt32 = 0, uniform = true
                for s in 0..<n {
                    let a = across <= n ? s : s * (across - 1) / max(1, n - 1)
                    let p = vertical ? f.pixel(rect.x + a, rect.y + l) : f.pixel(rect.x + l, rect.y + a)
                    if s == 0 { first = p } else if p != first { uniform = false }
                    h = (h ^ UInt64(p)) &* 0x100000001b3
                }
                sig[l] = h; textured[l] = !uniform
            }
            return (sig, textured)
        }
        let (sigOld, texOld) = signatures(old)
        let (sigNew, texNew) = signatures(new)
        var byHash: [UInt64: [Int]] = [:]
        for l in 0..<lines where texOld[l] { byHash[sigOld[l], default: []].append(l) }
        var votes: [Int: Int] = [:]
        var texturedNew = 0
        for l in 0..<lines where texNew[l] {
            texturedNew += 1
            guard let olds = byHash[sigNew[l]], olds.count <= 8 else { continue }   // repeated lines (rulers) vote ambiguously; skip
            for o in olds { let s = l - o; if abs(s) <= maxShift { votes[s, default: 0] += 1 } }
        }
        guard texturedNew >= minMatchedLines else { return nil }
        // Best non-zero shift; an in-place change (shift 0 dominant) is not a scroll.
        guard let (shift, count) = votes.filter({ $0.key != 0 }).max(by: { $0.value < $1.value }),
              count >= minMatchedLines, Double(count) >= minLineScore * Double(texturedNew - (votes[0] ?? 0)) else { return nil }
        let dx = vertical ? 0 : shift, dy = vertical ? shift : 0
        let bounds = PixelRect(x: 0, y: 0, width: min(old.width, new.width), height: min(old.height, new.height))
        let src = rect.intersection(bounds).intersection(bounds.offset(-dx, -dy)).intersection(rect.offset(-dx, -dy))
        guard src.width >= 16, src.height >= 16 else { return nil }
        let (mismatch, conf) = verifyTiles(old: old, new: new, src: src, dx: dx, dy: dy, tile: tile)
        guard conf >= minTileConfidence else { return nil }
        return Result(dx: dx, dy: dy, rect: src, mismatchedTiles: mismatch, confidence: conf)
    }

    /// Compares new[src + (dx,dy)] against old[src] per frame-aligned tile of the destination.
    private func verifyTiles(old: Frame, new: Frame, src: PixelRect, dx: Int, dy: Int, tile: Int) -> ([PixelRect], Double) {
        let dst = src.offset(dx, dy)
        var mismatched: [PixelRect] = []
        var total = 0, ok = 0
        let c0 = dst.x / tile, c1 = (dst.maxX - 1) / tile, r0 = dst.y / tile, r1 = (dst.maxY - 1) / tile
        for row in r0...r1 {
            for col in c0...c1 {
                let t = PixelRect(x: col * tile, y: row * tile, width: tile, height: tile).intersection(dst)
                guard !t.isEmpty else { continue }
                total += 1
                var same = true
                for y in t.y..<t.maxY where same {
                    let a = new.base.advanced(by: y * new.stride + t.x * 4)
                    let b = old.base.advanced(by: (y - dy) * old.stride + (t.x - dx) * 4)
                    // BGRA with alpha possibly differing: compare 24-bit colour per pixel.
                    for x in 0..<t.width {
                        if a.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self) & 0x00FF_FFFF != b.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self) & 0x00FF_FFFF { same = false; break }
                    }
                }
                if same { ok += 1 } else { mismatched.append(t) }
            }
        }
        return (mismatched, total == 0 ? 0 : Double(ok) / Double(total))
    }
}
