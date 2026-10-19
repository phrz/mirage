// byterace: replays recorded window sequences (bytrec) through the host's tile pipeline and compares
// how a region's changes should travel: today's motion classifier, a per-episode byte race between
// lossless patching and hardware HEVC, and a hindsight oracle (README.md for the rules and results).
//
//   byterace run <seqdir> [--kbps 600,2000] [--out results.json]   all strategies, every layer of one sequence
//   byterace dump <file.frames> <index> <out.png>                    one frame as PNG (to look at a recording)
//
// The pipeline per layer and frame is the host's (DesktopStreamer.captured, M3.1 window layers): CPU diff
// with ±4 tolerance and tight changed boxes, copy-rect detection by ShiftDetector on the unexplained dirty
// box with the learned scroll rect, TileTracker for rate limits, pending tiles and refinement, WebP at the
// host's full effort (4) on merged rects shrunk to the changed boxes, solid tiles as 4 bytes, near-lossless
// above 4096 colours; video through a hardware HEVC low-latency session configured like HEVCEncoder, fed a
// per-layer canvas that only receives the tiles sent as video, with the tile mask. Added on top, the same in
// every strategy: a client tile cache (exact 64-px tile hashes; a tile already sent once costs a 20-byte
// reference). Not modelled: the link (no token pacing, no tier/fovea), loss (so LTR never matters), and
// the first picture of a layer (frame 0 is taken as already on the client, crisp).

import Foundation
import VideoToolbox
import CoreMedia
import Compression
import ImageIO
import UniformTypeIdentifiers
import MirageTiles

// MARK: Wire-cost constants (from Sources/MirageCore/Wire)

enum Wire {
    static let tileMessage = 9 + 24          // framing + header (layer, capture seq, input seq, nanos)
    static let tileRect = 12                 // rect + format + length per encoded rect
    static let copyRect = 9 + 24 + 12        // a copy-rect message
    static let cacheRef = 20                 // hash @ (x, y), DESIGN §3.3 tile cache
    static let fragHeader = 47               // VideoFragment.headerSize
    static let fragPayload = 1200 - 47       // per datagram
    /// Bytes on the wire for one video frame of `payload` bytes: fragment headers plus one XOR parity
    /// datagram per group of 8 on frames of two or more datagrams (DESIGN §3.3c).
    static func video(_ payload: Int) -> Int {
        let n = max(1, (payload + fragPayload - 1) / fragPayload)
        let parity = n >= 2 ? (n + 7) / 8 : 0
        return payload + n * fragHeader + parity * 1200
    }
}

// MARK: Sequence reader

final class SeqReader {
    let data: Data
    let width: Int, height: Int
    var offset = 12
    var cur: [UInt8]
    var xorBuf: [UInt8]
    var index = -1
    init(_ path: String) {
        data = try! Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        precondition(data.prefix(4) == Data("BRF1".utf8), "not a bytrec file")
        width = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
        height = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) })
        cur = [UInt8](repeating: 0, count: width * height * 4)
        xorBuf = cur
    }
    /// Advances to the next frame; `cur` holds its pixels (packed BGRA, stride width×4).
    func next() -> UInt64? {
        guard offset + 12 <= data.count else { return nil }
        let (nanos, len) = data.withUnsafeBytes { (UInt64($0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)), Int($0.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self))) }
        let n = xorBuf.withUnsafeMutableBufferPointer { dst in data.withUnsafeBytes { src in
            compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!.advanced(by: offset + 12).assumingMemoryBound(to: UInt8.self), len, nil, COMPRESSION_LZ4)
        } }
        precondition(n == xorBuf.count, "short frame")
        cur.withUnsafeMutableBufferPointer { c in xorBuf.withUnsafeBufferPointer { x in
            let k = c.count / 8
            c.baseAddress!.withMemoryRebound(to: UInt64.self, capacity: k) { ca in x.baseAddress!.withMemoryRebound(to: UInt64.self, capacity: k) { xa in for i in 0..<k { ca[i] ^= xa[i] } } }
        } }
        offset += 12 + len
        index += 1
        return nanos
    }
}

func frameView(_ px: [UInt8], _ w: Int, _ h: Int) -> ShiftDetector.Frame {
    px.withUnsafeBytes { ShiftDetector.Frame(base: $0.baseAddress!, stride: w * 4, width: w, height: h) }
}

func cpuNanos() -> UInt64 { UInt64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) }
func processCPUNanos() -> UInt64 {
    var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
    return UInt64(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1_000_000_000 + UInt64(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) * 1000
}
func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

// MARK: Pixels: diff, hashes, PSNR (copies of DesktopStreamer's private helpers where noted)

/// DesktopStreamer.tileChangedBox, alpha-layer branch included (window layers carry alpha).
func tileChangedBox(_ a: ShiftDetector.Frame, _ b: ShiftDetector.Frame, _ r: PixelRect) -> PixelRect? {
    let n = r.width * 4
    var x0 = Int.max, x1 = -1, y0 = Int.max, y1 = -1
    let tol: Int32 = 4
    for y in r.y..<r.maxY {
        let pa = a.base.advanced(by: y * a.stride + r.x * 4), pb = b.base.advanced(by: y * b.stride + r.x * 4)
        if memcmp(pa, pb, n) == 0 { continue }
        let ua = pa.assumingMemoryBound(to: UInt8.self), ub = pb.assumingMemoryBound(to: UInt8.self)
        var rowChanged = false
        for x in 0..<r.width {
            let o = x * 4
            var changed = abs(Int32(ua[o]) - Int32(ub[o])) > tol || abs(Int32(ua[o + 1]) - Int32(ub[o + 1])) > tol || abs(Int32(ua[o + 2]) - Int32(ub[o + 2])) > tol
            let aa = Int32(ua[o + 3]), ab = Int32(ub[o + 3])
            if aa == 0 && ab == 0 { changed = false }
            else if aa < 255 || ab < 255 { changed = abs(aa - ab) > 48 || abs(Int32(ua[o]) - Int32(ub[o])) > 48 || abs(Int32(ua[o + 1]) - Int32(ub[o + 1])) > 48 || abs(Int32(ua[o + 2]) - Int32(ub[o + 2])) > 48 }
            else if abs(aa - ab) > tol { changed = true }
            if changed { rowChanged = true; if x < x0 { x0 = x }; if x > x1 { x1 = x } }
        }
        if rowChanged { if y < y0 { y0 = y }; y1 = y }
    }
    guard x1 >= 0 else { return nil }
    return PixelRect(x: r.x + x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
}

func tileHash(_ f: ShiftDetector.Frame, _ r: PixelRect) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325 ^ UInt64(r.width << 16 | r.height)
    for y in r.y..<r.maxY {
        let p = f.base.advanced(by: y * f.stride + r.x * 4)
        let n = r.width / 2
        for i in 0..<n { h = (h ^ p.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) &* 0x100000001b3; h ^= h >> 29 }
        if r.width % 2 == 1 { h = (h ^ UInt64(p.loadUnaligned(fromByteOffset: (r.width - 1) * 4, as: UInt32.self))) &* 0x100000001b3 }
    }
    return h
}

/// Luma PSNR of `r` between two BGRA frames.
func psnr(_ a: ShiftDetector.Frame, _ b: ShiftDetector.Frame, _ r: PixelRect) -> (sse: Double, n: Int) {
    var sse = 0.0
    for y in r.y..<r.maxY {
        let pa = a.base.advanced(by: y * a.stride + r.x * 4).assumingMemoryBound(to: UInt8.self), pb = b.base.advanced(by: y * b.stride + r.x * 4).assumingMemoryBound(to: UInt8.self)
        for x in 0..<r.width {
            let o = x * 4
            let ya = 0.114 * Double(pa[o]) + 0.587 * Double(pa[o + 1]) + 0.299 * Double(pa[o + 2])
            let yb = 0.114 * Double(pb[o]) + 0.587 * Double(pb[o + 1]) + 0.299 * Double(pb[o + 2])
            sse += (ya - yb) * (ya - yb)
        }
    }
    return (sse, r.area)
}

// MARK: Lossless encode (DesktopStreamer.submitLossless + encodeAndSend's format choice)

struct LosslessCost { var bytes = 0; var rects = 0; var refs = 0; var cpu: UInt64 = 0 }

final class TileCache {
    var known = Set<UInt64>()
    func lookup(_ h: UInt64) -> Bool { known.contains(h) }
    func insert(_ h: UInt64) { known.insert(h) }
}

func encodeLossless(_ tiles: [Int], frame f: ShiftDetector.Frame, tracker: TileTracker, tight: [Int: PixelRect]?, cache: TileCache?, effort: Int = 4) -> LosslessCost {
    var cost = LosslessCost()
    guard !tiles.isEmpty else { return cost }
    let t0 = cpuNanos()
    var send = tiles
    if let cache {
        // A full tile the client already holds (same pixels seen before, anywhere in this layer) is a reference.
        var rest: [Int] = []
        for i in tiles {
            let r = tracker.rect(of: i)
            let h = tileHash(f, r)
            if r.width == TileTracker.tile, r.height == TileTracker.tile, cache.lookup(h) { cost.refs += 1; cost.bytes += Wire.cacheRef } else { rest.append(i); cache.insert(h) }
        }
        send = rest
    }
    var rects = tracker.mergedRects(send)
    if let tight {
        let set = Set(send)
        rects = rects.map { r in
            var u = PixelRect.zero
            for i in tracker.tiles(covering: [r]) where set.contains(i) {
                guard let b = tight[i] else { return r }
                u = u.union(b)
            }
            return u.isEmpty ? r : PixelRect(x: u.x - 2, y: u.y - 2, width: u.width + 4, height: u.height + 4).intersection(r)
        }
    }
    for r in rects where !r.isEmpty {
        let base = f.base.advanced(by: r.y * f.stride + r.x * 4)
        if TileCodec.solidColour(base: base, width: r.width, height: r.height, stride: f.stride) != nil { cost.bytes += 4 + Wire.tileRect; cost.rects += 1; continue }
        let rich = TileCodec.colourCount(base: base, width: r.width, height: r.height, stride: f.stride, limit: 4096) > 4096
        let d = TileCodec.encode(base: base, width: r.width, height: r.height, stride: f.stride, format: rich ? .nearLossless : .lossless, effort: effort, alpha: true)
        cost.bytes += (d?.count ?? r.area * 4) + Wire.tileRect
        cost.rects += 1
    }
    if !rects.isEmpty || cost.refs > 0 { cost.bytes += Wire.tileMessage }
    cost.cpu = cpuNanos() - t0
    return cost
}

// MARK: HEVC (HEVCEncoder's configuration) and decode

final class Encoder {
    let session: VTCompressionSession
    let width: Int, height: Int
    var first = true, coarse = false
    var decoder: VTDecompressionSession?
    let decode: Bool
    let maxQP: Int
    init(width: Int, height: Int, kbps: Int, decode: Bool, maxQP: Int = 51) {
        self.width = width; self.height = height; self.decode = decode; self.maxQP = maxQP
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!]
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        precondition(st == noErr, "VTCompressionSessionCreate \(st)")
        session = s!
        func set(_ k: CFString, _ v: CFTypeRef) { VTSessionSetProperty(session, key: k, value: v) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AllowTemporalCompression, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 1 << 20 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1 << 20 as CFNumber)
        set(kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_MaxAllowedFrameQP, maxQP as CFNumber)
        let bps = kbps * 1000
        set(kVTCompressionPropertyKey_AverageBitRate, bps as CFNumber)
        set(kVTCompressionPropertyKey_DataRateLimits, [bps / 8 * 3 / 2, 1.0] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, 30 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }
    deinit {
        VTCompressionSessionInvalidate(session)
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
    }
    struct Out { var bytes: Int; var keyframe: Bool; var decoded: CVPixelBuffer?; var wallNanos: UInt64; var cpuNanos: UInt64 }
    /// Encodes synchronously (and decodes, if asked). The first frame of a session is a keyframe with QP ≥ 40
    /// (HEVCEncoder.setCoarse), later frames have no QP floor.
    func encode(_ pb: CVPixelBuffer, nanos: UInt64) -> Out? {
        if first && maxQP < 40 {
            // The quality-matched shadow runs at constant QP (min = max): its bytes are what readable video costs.
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MinAllowedFrameQP, value: maxQP as CFNumber); first = false
        }
        if first { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MinAllowedFrameQP, value: 40 as CFNumber); coarse = true; first = false }
        else if coarse { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MinAllowedFrameQP, value: 0 as CFNumber); coarse = false }
        var result: CMSampleBuffer?
        let w0 = now(), c0 = processCPUNanos()
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: CMTime(value: CMTimeValue(nanos), timescale: 1_000_000_000), duration: .invalid,
                                        frameProperties: nil, infoFlagsOut: nil) { st, flags, sb in if st == noErr, !flags.contains(.frameDropped) { result = sb } }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let wall = now() - w0, cpu = processCPUNanos() - c0
        guard let sb = result, let bb = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var key = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]], let a = arr.first, let notSync = a[kCMSampleAttachmentKey_NotSync] as? Bool { key = !notSync }
        var bytes = CMBlockBufferGetDataLength(bb)
        if key, let fd = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count { var n = 0; CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: nil, parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil); bytes += n + 4 }
        }
        var decoded: CVPixelBuffer?
        if decode {
            if decoder == nil, let fd = CMSampleBufferGetFormatDescription(sb) {
                let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
                VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &decoder)
            }
            if let decoder {
                VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { _, _, pb, _, _ in decoded = pb }
                VTDecompressionSessionWaitForAsynchronousFrames(decoder)
            }
        }
        return Out(bytes: bytes, keyframe: key, decoded: decoded, wallNanos: wall, cpuNanos: cpu)
    }
}

func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    memset(CVPixelBufferGetBaseAddress(pb!)!, 0, CVPixelBufferGetBytesPerRow(pb!) * h)
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

func copyTiles(_ tiles: [Int], from f: ShiftDetector.Frame, into canvas: CVPixelBuffer, tracker: TileTracker) {
    CVPixelBufferLockBaseAddress(canvas, [])
    let dst = CVPixelBufferGetBaseAddress(canvas)!, ds = CVPixelBufferGetBytesPerRow(canvas)
    for i in tiles {
        let r = tracker.rect(of: i)
        for y in r.y..<r.maxY { memcpy(dst.advanced(by: y * ds + r.x * 4), f.base.advanced(by: y * f.stride + r.x * 4), r.width * 4) }
    }
    CVPixelBufferUnlockBaseAddress(canvas, [])
}

// MARK: Copy-rect fallback

/// ShiftDetector's line-profile search rejects a shift unless its SAD is below 0.4× the SAD at zero shift. On a
/// terminal (monospace lines of similar density) a one-line scroll scores *above* zero shift, so real scrolls are
/// rejected although the shift verifies tile by tile at ~0.92 (README, "host findings"). Fallback: verify the three
/// best non-zero vertical shifts of the same profile and take the best one that passes the host's own tile check.
func fallbackShift(_ d: ShiftDetector, _ old: ShiftDetector.Frame, _ new: ShiftDetector.Frame, _ rect: PixelRect) -> ShiftDetector.Result? {
    func profile(_ f: ShiftDetector.Frame) -> [Int32] {
        (0..<rect.height).map { l in
            var acc: Int32 = 0
            for sIdx in 0..<32 {
                let x = rect.x + sIdx * (rect.width - 1) / 31
                let p = f.base.advanced(by: (rect.y + l) * f.stride + x * 4).assumingMemoryBound(to: UInt8.self)
                acc &+= (Int32(p[0]) + 2 * Int32(p[1]) + Int32(p[2])) / 4
            }
            return acc
        }
    }
    let po = profile(old), pn = profile(new)
    let lines = rect.height
    let limit = min(d.maxShift, lines - d.minLines)
    guard limit > 0 else { return nil }
    var cands: [(Int, Double)] = []
    for s in -limit...limit where s != 0 {
        let l0 = max(0, s), l1 = min(lines, lines + s)
        guard l1 - l0 >= d.minLines else { continue }
        var acc = 0
        for l in l0..<l1 { acc += Int(abs(pn[l] - po[l - s])) }
        cands.append((s, Double(acc) / Double(l1 - l0)))
    }
    var best: ShiftDetector.Result?
    for (s, _) in cands.sorted(by: { $0.1 < $1.1 }).prefix(3) {
        if let r = d.verify(old: old, new: new, rect: rect, dx: 0, dy: s), r.confidence >= d.minTileConfidence, r.confidence > (best?.confidence ?? 0) { best = r }
    }
    return best
}

// MARK: Pass 0: what changed, per frame (identical for every strategy)

struct FrameInfo {
    var nanos: UInt64
    var dirty: [Int]                 // after copy-rects
    var tight: [Int: PixelRect]
    var copyRects: Int
    var copied: [Int]                // tiles explained by a copy-rect
    var shift: (dx: Int, dy: Int)?   // of the (last) copy-rect, for soft-tile bookkeeping
    var scrollShare = 0.0            // share of this frame's dirty tiles a copy-rect explained
}

struct Episode { var start: Int; var end: Int; var startNanos: UInt64; var endNanos: UInt64; var region: PixelRect; var tiles: Set<Int> }

final class Analysis {
    let path: String
    let width: Int, height: Int
    var frames: [FrameInfo] = []
    var episodes: [Episode] = []
    var diffCPU: UInt64 = 0, shiftCPU: UInt64 = 0
    var fallbacks = 0
    init(path: String, fallback: Bool) {
        self.path = path
        let rd = SeqReader(path)
        width = rd.width; height = rd.height
        var tracker = TileTracker(width: width, height: height)
        var detector = ShiftDetector()
        detector.maxShift = 900                  // HostEffort.full
        if ProcessInfo.processInfo.environment["SHIFT_DEBUG"] != nil { detector.debug = { print("  shift: \($0)") } }
        var prev: [UInt8] = []
        var learned: PixelRect?
        while let nanos = rd.next() {
            if prev.isEmpty { prev = rd.cur; frames.append(FrameInfo(nanos: nanos, dirty: [], tight: [:], copyRects: 0, copied: [], shift: nil)); continue }
            if let lim = ProcessInfo.processInfo.environment["SHIFT_DEBUG"].flatMap(Int.init), rd.index > lim { break }
            let t0 = cpuNanos()
            var dirty: [Int] = [], tight: [Int: PixelRect] = [:]
            prev.withUnsafeBytes { pa in rd.cur.withUnsafeBytes { ca in
                let old = ShiftDetector.Frame(base: pa.baseAddress!, stride: width * 4, width: width, height: height)
                let new = ShiftDetector.Frame(base: ca.baseAddress!, stride: width * 4, width: width, height: height)
                for i in 0..<tracker.tileCount { if let b = tileChangedBox(old, new, tracker.rect(of: i)) { dirty.append(i); tight[i] = b } }
            } }
            let t1 = cpuNanos()
            diffCPU += t1 - t0
            // Copy-rects: DesktopStreamer's window-layer branch (scroll detection on the unexplained dirty box).
            var explained = Set<Int>()
            var shift: (Int, Int)? = nil
            var n = 0
            let bb = tracker.boundingRect(dirty)
            if dirty.count >= 12, bb.height >= 128 || bb.width >= 128 {
                var region = (learned ?? bb).intersection(bb)
                if region.width < 64 || region.height < 64 { region = bb }
                if region.height >= 96 || region.width >= 96 {
                    prev.withUnsafeBytes { pa in rd.cur.withUnsafeBytes { ca in
                        let old = ShiftDetector.Frame(base: pa.baseAddress!, stride: width * 4, width: width, height: height)
                        let new = ShiftDetector.Frame(base: ca.baseAddress!, stride: width * 4, width: width, height: height)
                        var found = detector.detect(old: old, new: new, rect: region)
                        if found == nil, fallback, let r = fallbackShift(detector, old, new, region) {
                            // Only a shift that explains most of this frame's change counts (a smooth gradient verifies at
                            // small shifts without being a scroll).
                            let dest = Set(tracker.tiles(covering: [r.rect.offset(r.dx, r.dy)])).subtracting(tracker.tiles(covering: r.mismatchedTiles))
                            if r.confidence >= 0.8, Double(dirty.filter { dest.contains($0) }.count) >= 0.6 * Double(dirty.count) { found = r; fallbacks += 1 }
                        }
                        if let r = found {
                            let dest = tracker.tiles(covering: [r.rect.offset(r.dx, r.dy)])
                            let mismatched = Set(tracker.tiles(covering: r.mismatchedTiles))
                            explained.formUnion(dest.filter { !mismatched.contains($0) })
                            if learned == nil { learned = r.rect.union(r.rect.offset(r.dx, r.dy)) }
                            shift = (r.dx, r.dy); n += 1
                        }
                    } }
                }
            }
            shiftCPU += cpuNanos() - t1
            let rest = dirty.filter { !explained.contains($0) }
            frames.append(FrameInfo(nanos: nanos, dirty: rest, tight: tight, copyRects: n, copied: Array(explained), shift: shift,
                                    scrollShare: dirty.isEmpty ? 0 : Double(dirty.count - rest.count) / Double(dirty.count)))
            prev = rd.cur
            tracker.markCopied(Array(explained), now: nanos)
        }
        // Episodes: runs of change separated by at least 300 ms of calm (the host's settle time).
        var cur: Episode?
        for (k, f) in frames.enumerated() where !f.dirty.isEmpty || f.copyRects > 0 {
            if var e = cur, f.nanos - e.endNanos < 300_000_000 {
                e.end = k; e.endNanos = f.nanos; e.tiles.formUnion(f.dirty); cur = e
            } else {
                if let e = cur { episodes.append(e) }
                cur = Episode(start: k, end: k, startNanos: f.nanos, endNanos: f.nanos, region: .zero, tiles: Set(f.dirty))
            }
        }
        if let e = cur { episodes.append(e) }
        for k in episodes.indices { episodes[k].region = tracker.boundingRect(Array(episodes[k].tiles)) }
    }
    func episode(at frame: Int) -> Int? { episodes.firstIndex { frame >= $0.start && frame <= $0.end } }
}

// MARK: Strategies

let shadowMaxQP = Int(ProcessInfo.processInfo.environment["SHADOW_MAXQP"] ?? "") ?? 30

enum Strategy: Equatable {
    case classifier               // today: TileTracker.classify
    case lossless                 // never video
    case video                    // every episode through video (region refreshed at its start)
    case race                     // per-episode byte race with hysteresis
    case raceFast                 // the same with a 0.3 s hold
    case raceQ                    // race at equal quality: shadow capped at QP 30, two-tier entry (4× now, 1.5× for 1 s)
    case hybrid                   // classifier proposes, copy-rects and the byte race veto
    case veto                     // the recommendation: classifier entry, copy-rect gate, byte veto on staying in video
    case schedule([Bool])         // per-episode choice (the oracle's), true = video
    var name: String {
        switch self { case .classifier: return "classifier"; case .lossless: return "all-lossless"; case .video: return "all-video"; case .race: return "race"; case .raceFast: return "race-fast"; case .raceQ: return "race-q"; case .hybrid: return "hybrid"; case .veto: return "veto"; case .schedule: return "oracle" }
    }
}

struct Result {
    var strategy = ""
    var kbps = 0
    var seconds = 0.0
    var bytesLosslessDirect = 0, bytesRefinement = 0, bytesCopyRect = 0, bytesVideo = 0, bytesKeyframes = 0
    var cacheRefs = 0
    var videoFrames = 0, keyframes = 0, switchesToVideo = 0, switchesToLossless = 0
    var softTextTileSeconds = 0.0, textTileSecondsActive = 0.0
    var videoTextSSE = 0.0, videoTextPixels = 0
    var videoMediaSSE = 0.0, videoMediaPixels = 0
    var estLosslessCPUms = 0.0, estVideoCPUms = 0.0, estVideoWallms = 0.0, estFrames = 0
    var episodeBytes: [Int] = []
    var total: Int { bytesLosslessDirect + bytesRefinement + bytesCopyRect + bytesVideo }
    var kbpsAvg: Double { Double(total) * 8 / 1000 / max(seconds, 0.001) }
    var softFraction: Double { textTileSecondsActive > 0 ? softTextTileSeconds / textTileSecondsActive : 0 }
    var textPSNR: Double { videoTextPixels > 0 ? 10 * log10(255 * 255 / (videoTextSSE / Double(videoTextPixels))) : .nan }
    var mediaPSNR: Double { videoMediaPixels > 0 ? 10 * log10(255 * 255 / (videoMediaSSE / Double(videoMediaPixels))) : .nan }
}

struct RaceTuning {
    var ratio = 1.5           // go to video when lossless ≥ ratio × video estimate...
    var holdNanos: UInt64 = 1_000_000_000      // ...continuously for this long, over a 1 s window
    var windowNanos: UInt64 = 1_000_000_000
    var backRatio = 1.0       // back to lossless when lossless ≤ backRatio × video over 2 s, for 2 s
    var backHoldNanos: UInt64 = 2_000_000_000
    var calmNanos: UInt64 = 300_000_000        // or when the region has been still this long
    var minDwellNanos: UInt64 = 1_000_000_000
}

func replay(_ an: Analysis, strategy: Strategy, kbps: Int, media: [PixelRect], tuning baseTuning: RaceTuning = RaceTuning()) -> Result {
    var res = Result(); res.strategy = strategy.name; res.kbps = kbps
    var tuning = baseTuning
    if strategy == .raceFast { tuning.holdNanos = 300_000_000 }
    let racing = strategy == .race || strategy == .raceFast || strategy == .hybrid || strategy == .raceQ || strategy == .veto
    // Hybrid: today's classifier (its own tracker, default tuning) only proposes; the race and copy-rects decide.
    var proposer = TileTracker(width: an.width, height: an.height)
    var lastScroll: UInt64 = 0
    var vetoUntil: UInt64 = 0, lastVideoRate = 0
    let W = an.width, H = an.height
    var tracker = TileTracker(width: W, height: H)
    if strategy != .classifier {
        // Lossless bookkeeping only (rate limit, pending, refinement); the strategy decides video itself.
        tracker.tuning.motionTileCount = .max; tracker.tuning.sustainedClusterTiles = .max
    }
    let isMedia: [Bool] = (0..<tracker.tileCount).map { i in media.contains { $0.intersects(tracker.rect(of: i)) } }
    let cache = TileCache()
    var encoder: Encoder?
    var canvas: CVPixelBuffer?
    var shadow: Encoder?
    var shadowBuf: CVPixelBuffer?
    var pendingVideo = Set<Int>(), pendingRegion = PixelRect.zero
    var lastVideoSend: UInt64 = 0
    var lastMotion: UInt64 = 0
    var soft = [Bool](repeating: false, count: tracker.tileCount)
    var textActive = [Bool](repeating: false, count: tracker.tileCount)
    // Race state.
    var videoMode = false
    var region = PixelRect.zero
    var modeSince: UInt64 = 0
    var condSince: UInt64? = nil, backSince: UInt64? = nil
    var regionLastDirty: UInt64 = 0
    var hist: [(t: UInt64, l: Int, v: Int)] = []
    var recentDirty: [(t: UInt64, tiles: [Int])] = []
    // Per-episode attribution.
    var epIndex = 0
    res.episodeBytes = Array(repeating: 0, count: an.episodes.count)
    func charge(_ b: Int, at k: Int) {
        while epIndex + 1 < an.episodes.count && k >= an.episodes[epIndex + 1].start { epIndex += 1 }
        if !an.episodes.isEmpty { res.episodeBytes[epIndex] += b }
    }
    func enterVideo(_ r: PixelRect, _ f: ShiftDetector.Frame, _ t: UInt64) {
        videoMode = true; region = r; modeSince = t; condSince = nil; backSince = nil; regionLastDirty = t
        res.switchesToVideo += 1
        if canvas == nil { canvas = makeBuffer(W, H) }
        // Refresh the whole region: into the canvas and masked, so the reference under it is current.
        let tiles = tracker.tiles(covering: [r])
        copyTiles(tiles, from: f, into: canvas!, tracker: tracker)
        pendingVideo.formUnion(tiles); pendingRegion = pendingRegion.union(r)
        tracker.markVideo(tiles, now: t)
    }
    func leaveVideo(_ t: UInt64) { videoMode = false; modeSince = t; condSince = nil; backSince = nil; res.switchesToLossless += 1 }

    let rd = SeqReader(an.path)
    var prevNanos: UInt64 = 0
    while let nanos = rd.next() {
        let k = rd.index
        let fi = an.frames[k]
        let dt = k == 0 ? 0 : Double(nanos - prevNanos) / 1e9
        prevNanos = nanos
        if k == 0 { continue }
        res.seconds = Double(nanos - an.frames[0].nanos) / 1e9
        rd.cur.withUnsafeBytes { cb in
            let f = ShiftDetector.Frame(base: cb.baseAddress!, stride: W * 4, width: W, height: H)
            // Soft bookkeeping across copy-rects: a moved tile keeps the quality of where it came from.
            if let s = fi.shift, !fi.copied.isEmpty {
                let before = soft
                for i in fi.copied {
                    let src = tracker.rect(of: i).offset(-s.dx, -s.dy)
                    soft[i] = tracker.tiles(covering: [src]).contains { before[$0] }
                }
            }
            if fi.copyRects > 0 { res.bytesCopyRect += fi.copyRects * Wire.copyRect; charge(fi.copyRects * Wire.copyRect, at: k); lastMotion = nanos }
            if !fi.copied.isEmpty { tracker.markCopied(fi.copied, now: nanos) }
            for i in fi.dirty where !isMedia[i] { textActive[i] = true }

            var plan = tracker.classify(dirty: fi.dirty, now: nanos)
            var proposal: [Int] = [], proposalRegion = PixelRect.zero
            if strategy == .hybrid || strategy == .veto {
                if !fi.copied.isEmpty { proposer.markCopied(fi.copied, now: nanos) }
                let pp = proposer.classify(dirty: fi.dirty, now: nanos)
                proposal = pp.video; proposalRegion = pp.videoRegion
                if fi.scrollShare >= 0.5 { lastScroll = nanos }
            }
            var videoTiles: [Int] = plan.video
            var videoRegion = plan.videoRegion

            // Episode-driven strategies (all-video, oracle schedule).
            var forced: Bool? = nil
            if case .video = strategy { forced = true }
            if case .schedule(let s) = strategy, let e = an.episode(at: k) { forced = s[e] }
            if let want = forced {
                if let e = an.episode(at: k) {
                    if want && (!videoMode || region != an.episodes[e].region) { if videoMode { leaveVideo(nanos) }; enterVideo(an.episodes[e].region, f, nanos) }
                    if !want && videoMode { leaveVideo(nanos) }
                } else if videoMode, let prevEp = an.episodes.last(where: { $0.end < k }), nanos - prevEp.endNanos >= tuning.calmNanos { leaveVideo(nanos) }
            }

            // The race.
            if racing {
                if !fi.dirty.isEmpty { recentDirty.append((nanos, fi.dirty)) }
                recentDirty.removeAll { nanos - $0.t > tuning.windowNanos }
                // Video estimate: a shadow session fed the whole current frame whenever anything changed.
                var vEst = 0
                if strategy != .veto, !fi.dirty.isEmpty || fi.copyRects > 0 {
                    if shadow == nil {
                        // race-q: the estimate is what *readable* video would cost (QP ≤ 30, budget no constraint), not
                        // what the rate controller spends at the link's rate, which is cheap for sparse text only by being mush.
                        shadow = strategy == .raceQ ? Encoder(width: W, height: H, kbps: 20_000, decode: false, maxQP: shadowMaxQP) : Encoder(width: W, height: H, kbps: kbps, decode: false)
                        shadowBuf = makeBuffer(W, H)
                    }
                    // Fed in both modes so its reference never goes stale; its bytes are the estimate only while lossless.
                    copyTiles(Array(0..<tracker.tileCount), from: f, into: shadowBuf!, tracker: tracker)
                    if let o = shadow!.encode(shadowBuf!, nanos: nanos) {
                        if !o.keyframe && !videoMode { vEst = Wire.video(o.bytes) }    // the shadow's own first keyframe is not a cost estimate
                        res.estVideoCPUms += Double(o.cpuNanos) / 1e6; res.estVideoWallms += Double(o.wallNanos) / 1e6; res.estFrames += 1
                    }
                }
                // Lossless estimate in video mode: what the region's dirty tiles would cost as patches.
                var lEst = 0
                if videoMode {
                    let inside = fi.dirty.filter { tracker.rect(of: $0).intersects(region) }
                    if !inside.isEmpty && strategy == .veto {
                        // WebP at the host's effort on at most 16 sampled tiles, scaled to the count.
                        let step = max(1, inside.count / 16)
                        let sample = stride(from: 0, to: inside.count, by: step).map { inside[$0] }
                        var b = 0
                        for i in sample { let c = encodeLossless([i], frame: f, tracker: tracker, tight: fi.tight, cache: nil); b += c.bytes; res.estLosslessCPUms += Double(c.cpu) / 1e6 }
                        lEst = b * inside.count / sample.count
                        regionLastDirty = nanos
                    } else if !inside.isEmpty {
                        let c = encodeLossless(inside, frame: f, tracker: tracker, tight: fi.tight, cache: nil)
                        lEst = c.bytes; res.estLosslessCPUms += Double(c.cpu) / 1e6
                        regionLastDirty = nanos
                    }
                }
                // Lossless mode: lEst is filled in below from what was actually sent; video mode: vEst from what was sent.
                hist.append((nanos, lEst, vEst))
            }

            if videoMode {
                // Every dirty tile in the region rides video; outside, lossless as usual.
                let inside = Set(fi.dirty.filter { tracker.rect(of: $0).intersects(region) })
                plan.lossless.removeAll { inside.contains($0) }
                videoTiles = Array(inside); videoRegion = region
                tracker.markVideo(Array(inside), now: nanos)
            }

            // Lossless direct changes (interactive path; tight boxes).
            if !plan.lossless.isEmpty {
                let c = encodeLossless(plan.lossless, frame: f, tracker: tracker, tight: fi.tight, cache: cache)
                res.bytesLosslessDirect += c.bytes; res.cacheRefs += c.refs; charge(c.bytes, at: k)
                for i in plan.lossless { soft[i] = false }
                if racing, !videoMode, !hist.isEmpty { hist[hist.count - 1].l += c.bytes }
            }
            // Video.
            if !videoTiles.isEmpty {
                if canvas == nil { canvas = makeBuffer(W, H) }
                copyTiles(videoTiles, from: f, into: canvas!, tracker: tracker)
                pendingVideo.formUnion(videoTiles); pendingRegion = pendingRegion.union(videoRegion)
                lastMotion = nanos
            }
            if !pendingVideo.isEmpty {
                let fraction = Double(pendingRegion.area) / Double(W * H)
                let minInterval: UInt64 = fraction < 0.03 ? 66_666_666 : 33_333_333
                if nanos - lastVideoSend >= minInterval * 9 / 10 {
                    if encoder == nil { encoder = Encoder(width: W, height: H, kbps: kbps, decode: true) }
                    if let o = encoder!.encode(canvas!, nanos: nanos) {
                        let wire = Wire.video(o.bytes) + (pendingRegion.area / (64 * 64) + 7) / 8
                        res.bytesVideo += wire; res.videoFrames += 1; charge(wire, at: k)
                        if o.keyframe { res.keyframes += 1; res.bytesKeyframes += wire }
                        if racing, videoMode, !hist.isEmpty { hist[hist.count - 1].v += wire }
                        if let d = o.decoded {
                            CVPixelBufferLockBaseAddress(d, .readOnly)
                            let df = ShiftDetector.Frame(base: CVPixelBufferGetBaseAddress(d)!, stride: CVPixelBufferGetBytesPerRow(d), width: W, height: H)
                            for i in pendingVideo {
                                let p = psnr(df, f, tracker.rect(of: i))
                                if isMedia[i] { res.videoMediaSSE += p.sse; res.videoMediaPixels += p.n } else { res.videoTextSSE += p.sse; res.videoTextPixels += p.n }
                            }
                            CVPixelBufferUnlockBaseAddress(d, .readOnly)
                        }
                        for i in pendingVideo { soft[i] = true }
                    }
                    pendingVideo = []; pendingRegion = .zero; lastVideoSend = nanos
                }
            }

            // Race decisions, after this frame's costs are known.
            if racing {
                hist.removeAll { nanos - $0.t > max(tuning.windowNanos, 2_000_000_000) }
                let w1 = hist.filter { nanos - $0.t <= tuning.windowNanos }
                let l1 = w1.reduce(0) { $0 + $1.l }, v1 = w1.reduce(0) { $0 + $1.v }
                let l2 = hist.reduce(0) { $0 + $1.l }, v2 = hist.reduce(0) { $0 + $1.v }
                if !videoMode && strategy == .veto {
                    // Classifier entry, never within 300 ms of a real scroll, not while vetoed (unless lossless has
                    // since cost ≥ 1.5× the region's last measured video rate).
                    if nanos < vetoUntil, lastVideoRate > 0, Double(l1) >= tuning.ratio * Double(lastVideoRate) { vetoUntil = 0 }
                    if !proposal.isEmpty, nanos - lastScroll >= 300_000_000, nanos >= vetoUntil {
                        let r = tracker.boundingRect(recentDirty.flatMap { $0.tiles }).union(proposalRegion)
                        if !r.isEmpty { enterVideo(r, f, nanos) }
                    }
                } else if !videoMode && strategy == .hybrid {
                    // Enter only on the classifier's sustained-motion signal, never within 300 ms of a real scroll
                    // (copy-rects explaining at least half of a frame's change), and only if lossless has cost at least
                    // ratio × the shadow estimate over what history there is (≥ 200 ms).
                    let span = (w1.first.map { nanos - $0.t } ?? 0)
                    if !proposal.isEmpty, nanos - lastScroll >= 300_000_000, span >= 200_000_000, l1 > 0, v1 > 0, Double(l1) >= tuning.ratio * Double(v1), nanos - modeSince >= 300_000_000 {
                        let r = tracker.boundingRect(recentDirty.flatMap { $0.tiles }).union(proposalRegion)
                        if !r.isEmpty { enterVideo(r, f, nanos) }
                    }
                } else if !videoMode && strategy == .raceQ {
                    let w02 = hist.filter { nanos - $0.t <= 200_000_000 }
                    let l02 = w02.reduce(0) { $0 + $1.l }, v02 = w02.reduce(0) { $0 + $1.v }
                    let fast = w02.count >= 3 && l02 > 0 && v02 > 0 && Double(l02) >= 4 * Double(v02)
                    if l1 > 0, v1 > 0, Double(l1) >= tuning.ratio * Double(v1) { if condSince == nil { condSince = nanos } } else { condSince = nil }
                    if fast || (condSince.map { nanos - $0 >= tuning.holdNanos } ?? false), nanos - modeSince >= 300_000_000 {
                        let r = tracker.boundingRect(recentDirty.flatMap { $0.tiles })
                        if !r.isEmpty { enterVideo(r, f, nanos) }
                    }
                } else if !videoMode {
                    if l1 > 0, v1 > 0, Double(l1) >= tuning.ratio * Double(v1) {
                        if condSince == nil { condSince = nanos }
                        if nanos - condSince! >= tuning.holdNanos, nanos - modeSince >= tuning.minDwellNanos {
                            let r = tracker.boundingRect(recentDirty.flatMap { $0.tiles })
                            if !r.isEmpty { enterVideo(r, f, nanos) }
                        }
                    } else { condSince = nil }
                } else {
                    if strategy == .veto, nanos - modeSince >= tuning.minDwellNanos, v1 > 0, l1 <= v1 {
                        lastVideoRate = v1; vetoUntil = nanos + 10_000_000_000; leaveVideo(nanos)
                    } else if strategy == .veto, nanos - regionLastDirty >= tuning.calmNanos { leaveVideo(nanos) }
                    else if strategy != .veto, nanos - modeSince >= tuning.minDwellNanos {
                        if nanos - regionLastDirty >= tuning.calmNanos { leaveVideo(nanos) }
                        else if Double(l2) <= tuning.backRatio * Double(v2) {
                            if backSince == nil { backSince = nanos }
                            if nanos - backSince! >= tuning.backHoldNanos { leaveVideo(nanos) }
                        } else { backSince = nil }
                    }
                    if videoMode {
                        // The region follows the motion: grow it to this second's dirty box.
                        let r = tracker.boundingRect(recentDirty.flatMap { $0.tiles }).union(region)
                        if r != region { region = r }
                    }
                }
            }

            // Refinement and rate-limited tiles (DesktopStreamer.refine): direct changes whenever due; refinement
            // of video-shown tiles only once motion has stopped for 300 ms (the freeze).
            let due = tracker.due(now: nanos, limit: Int.max)
            if !due.isEmpty {
                let quiet = nanos - lastMotion >= 300_000_000
                let direct = due.filter { tracker.isDirectPending($0) && !(videoMode && tracker.rect(of: $0).intersects(region)) }
                let refine = quiet && !videoMode ? due.filter { !tracker.isDirectPending($0) } : []
                if !direct.isEmpty {
                    let c = encodeLossless(direct, frame: f, tracker: tracker, tight: nil, cache: cache)
                    res.bytesLosslessDirect += c.bytes; res.cacheRefs += c.refs; charge(c.bytes, at: k)
                    tracker.sent(lossless: direct, now: nanos); for i in direct { soft[i] = false }
                    if racing, !videoMode, !hist.isEmpty { hist[hist.count - 1].l += c.bytes }
                }
                if !refine.isEmpty {
                    let c = encodeLossless(refine, frame: f, tracker: tracker, tight: nil, cache: cache)
                    res.bytesRefinement += c.bytes; res.cacheRefs += c.refs; charge(c.bytes, at: k)
                    tracker.sent(lossless: refine, now: nanos); for i in refine { soft[i] = false }
                }
            }
            // Softness of text: tile-seconds of text tiles that have changed at least once and are shown via video.
            for i in 0..<soft.count where textActive[i] {
                res.textTileSecondsActive += dt
                if soft[i] { res.softTextTileSeconds += dt }
            }
        }
    }
    return res
}

// MARK: CLI

func writePNG(_ px: [UInt8], _ w: Int, _ h: Int, _ path: String) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    var data = px
    let ctx = data.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)! }
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
}

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

if args.count >= 5, args[1] == "dump" {
    let rd = SeqReader(args[2])
    let want = Int(args[3])!
    while rd.next() != nil { if rd.index == want { break } }
    writePNG(rd.cur, rd.width, rd.height, args[4]); exit(0)
}
guard args.count >= 3, args[1] == "run" else { print("usage: byterace run <seqdir> [--kbps 600,2000] [--out file.json] | byterace dump <file.frames> <index> <out.png>"); exit(2) }
let dir = URL(fileURLWithPath: args[2])
let kbpsList = (opt("--kbps") ?? "600,2000").split(separator: ",").compactMap { Int($0) }
let only = opt("--only")?.split(separator: ",").map(String.init)
let metaData = try! Data(contentsOf: dir.appendingPathComponent("meta.json"))
let meta = try! JSONSerialization.jsonObject(with: metaData) as! [String: Any]
let layers = meta["layers"] as! [[String: Any]]
var report: [String: Any] = ["scene": meta["scene"]!]
var layerReports: [[String: Any]] = []
for l in layers {
    let name = l["name"] as! String
    let media = ((l["media"] as? [[Int]]) ?? []).map { PixelRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
    let t0 = now()
    let an = Analysis(path: dir.appendingPathComponent("\(name).frames").path, fallback: ProcessInfo.processInfo.environment["HOST_DETECTOR"] == nil)
    let nf = an.frames.count
    let dirtyMean = Double(an.frames.reduce(0) { $0 + $1.dirty.count }) / Double(max(1, nf - 1))
    print(String(format: "%@/%@: %d frames %dx%d, %.1f dirty tiles/frame after copy-rects, %d copy-rects (%d by the fallback), %d episodes; diff %.2f ms/frame, copy-rect search %.2f ms/frame (analysis %.1f s)",
                 meta["scene"] as! String, name, nf, an.width, an.height, dirtyMean, an.frames.reduce(0) { $0 + $1.copyRects }, an.fallbacks, an.episodes.count,
                 Double(an.diffCPU) / 1e6 / Double(nf), Double(an.shiftCPU) / 1e6 / Double(nf), Double(now() - t0) / 1e9))
    var runs: [[String: Any]] = []
    for kbps in kbpsList {
        var results: [String: Result] = [:]
        for s in [Strategy.classifier, .lossless, .video, .race, .raceFast, .raceQ, .hybrid, .veto] where only == nil || only!.contains(s.name) {
            let t = now()
            let r = replay(an, strategy: s, kbps: kbps, media: media)
            results[s.name] = r
            print(String(format: "  %5d kbps %-12@ %8d B  %7.1f kbps  (direct %d, refine %d, copy %d, video %d of which key %d; refs %d)  vframes %d key %d  switches %d/%d  text soft %.1f%%  PSNR text %.1f media %.1f  [%.1f s]",
                         kbps, s.name, r.total, r.kbpsAvg, r.bytesLosslessDirect, r.bytesRefinement, r.bytesCopyRect, r.bytesVideo, r.bytesKeyframes, r.cacheRefs, r.videoFrames, r.keyframes,
                         r.switchesToVideo, r.switchesToLossless, r.softFraction * 100, r.textPSNR, r.mediaPSNR, Double(now() - t) / 1e9))
            if r.estFrames > 0 {
                print(String(format: "        race estimates: video (shadow session) %.2f ms CPU, %.2f ms wall per estimated frame (%d); lossless-in-video %.2f ms CPU total/frame",
                             r.estVideoCPUms / Double(r.estFrames), r.estVideoWallms / Double(r.estFrames), r.estFrames, r.estLosslessCPUms / Double(max(1, nf))))
            }
        }
        if let L = results["all-lossless"], let V = results["all-video"] {
            let choice = zip(L.episodeBytes, V.episodeBytes).map { $0.1 < $0.0 }
            let r = replay(an, strategy: .schedule(choice), kbps: kbps, media: media)
            results["oracle"] = r
            print(String(format: "  %5d kbps %-12@ %8d B  %7.1f kbps  (direct %d, refine %d, copy %d, video %d of which key %d)  vframes %d  switches %d/%d  text soft %.1f%%  PSNR text %.1f media %.1f  [%d of %d episodes video]",
                         kbps, "oracle", r.total, r.kbpsAvg, r.bytesLosslessDirect, r.bytesRefinement, r.bytesCopyRect, r.bytesVideo, r.bytesKeyframes, r.videoFrames,
                         r.switchesToVideo, r.switchesToLossless, r.softFraction * 100, r.textPSNR, r.mediaPSNR, choice.filter { $0 }.count, choice.count))
        }
        var rr: [String: Any] = ["kbps": kbps]
        for (k, r) in results {
            rr[k] = ["total": r.total, "kbpsAvg": r.kbpsAvg, "direct": r.bytesLosslessDirect, "refinement": r.bytesRefinement, "copyRect": r.bytesCopyRect, "video": r.bytesVideo,
                     "keyframes": r.bytesKeyframes, "videoFrames": r.videoFrames, "keyframeCount": r.keyframes, "toVideo": r.switchesToVideo, "toLossless": r.switchesToLossless,
                     "softFraction": r.softFraction, "softTextTileSeconds": r.softTextTileSeconds, "textPSNR": r.textPSNR.isNaN ? -1 : r.textPSNR, "mediaPSNR": r.mediaPSNR.isNaN ? -1 : r.mediaPSNR,
                     "cacheRefs": r.cacheRefs, "seconds": r.seconds,
                     "estVideoCPUmsPerFrame": r.estFrames > 0 ? r.estVideoCPUms / Double(r.estFrames) : 0, "estVideoWallmsPerFrame": r.estFrames > 0 ? r.estVideoWallms / Double(r.estFrames) : 0,
                     "estLosslessCPUmsPerFrame": r.estLosslessCPUms / Double(max(1, nf))] as [String: Any]
        }
        runs.append(rr)
    }
    layerReports.append(["name": name, "frames": nf, "width": an.width, "height": an.height, "dirtyTilesPerFrame": dirtyMean, "episodes": an.episodes.count, "copyRects": an.frames.reduce(0) { $0 + $1.copyRects }, "fallbackCopyRects": an.fallbacks, "hostDetectorOnly": ProcessInfo.processInfo.environment["HOST_DETECTOR"] != nil,
                         "diffMsPerFrame": Double(an.diffCPU) / 1e6 / Double(nf), "copyRectMsPerFrame": Double(an.shiftCPU) / 1e6 / Double(nf), "runs": runs])
}
report["layers"] = layerReports
if let out = opt("--out") {
    try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
}
