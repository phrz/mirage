// tilebench: how many bytes does a 64x64 screen tile cost under candidate lossless codecs,
// by tile class, versus hardware HEVC intra for the whole frame? Informs Mirage M2.
import Foundation
import ImageIO
import CoreGraphics
import Compression
import VideoToolbox
import CoreMedia

let tile = Int(ProcessInfo.processInfo.environment["TILE"] ?? "64")!
let useCLI = ProcessInfo.processInfo.environment["NO_CLI"] == nil

struct Img { let w: Int, h: Int; let rgba: [UInt8]; let cg: CGImage }
func load(_ path: String) -> Img {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return Img(w: w, h: h, rgba: buf, cg: cg)
}

// Extract tile as tightly packed RGB (3 bytes/px).
func rgbTile(_ img: Img, _ tx: Int, _ ty: Int) -> [UInt8] {
    var out = [UInt8](); out.reserveCapacity(tile * tile * 3)
    for y in 0..<tile { for x in 0..<tile {
        let i = ((ty * tile + y) * img.w + (tx * tile + x)) * 4
        out.append(img.rgba[i]); out.append(img.rgba[i+1]); out.append(img.rgba[i+2])
    } }
    return out
}

func compress(_ data: [UInt8], _ algo: compression_algorithm) -> Int {
    let cap = data.count + 4096
    var dst = [UInt8](repeating: 0, count: cap)
    let n = data.withUnsafeBufferPointer { src in
        compression_encode_buffer(&dst, cap, src.baseAddress!, src.count, nil, algo)
    }
    return n == 0 ? data.count : n
}

// PNG "Sub" predictor: left-delta per channel.
func subPredict(_ rgb: [UInt8]) -> [UInt8] {
    var out = rgb
    for y in 0..<tile { for x in 1..<tile { for c in 0..<3 {
        let i = (y * tile + x) * 3 + c
        out[i] = rgb[i] &- rgb[i - 3]
    } } }
    return out
}
// Paeth predictor (PNG filter 4).
func paeth(_ rgb: [UInt8]) -> [UInt8] {
    var out = rgb
    func px(_ x: Int, _ y: Int, _ c: Int) -> Int { (x < 0 || y < 0) ? 0 : Int(rgb[(y * tile + x) * 3 + c]) }
    for y in 0..<tile { for x in 0..<tile { for c in 0..<3 {
        let a = px(x-1, y, c), b = px(x, y-1, c), cc = px(x-1, y-1, c)
        let p = a + b - cc
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - cc)
        let pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : cc)
        out[(y * tile + x) * 3 + c] = UInt8(truncatingIfNeeded: Int(rgb[(y * tile + x) * 3 + c]) - pred)
    } } }
    return out
}
// Palette: index stream (1 byte/px) + palette; returns nil when > 256 colours.
func palettize(_ rgb: [UInt8]) -> (indices: [UInt8], paletteBytes: Int)? {
    var map = [UInt32: UInt8](); var idx = [UInt8](); idx.reserveCapacity(tile * tile)
    for p in 0..<(tile * tile) {
        let k = UInt32(rgb[p*3]) << 16 | UInt32(rgb[p*3+1]) << 8 | UInt32(rgb[p*3+2])
        if let i = map[k] { idx.append(i) } else { if map.count == 256 { return nil }; map[k] = UInt8(map.count); idx.append(UInt8(map.count - 1)) }
    }
    return (idx, map.count * 3)
}
func uniqueColors(_ rgb: [UInt8]) -> Int {
    var s = Set<UInt32>()
    for p in 0..<(tile * tile) { s.insert(UInt32(rgb[p*3]) << 16 | UInt32(rgb[p*3+1]) << 8 | UInt32(rgb[p*3+2])); if s.count > 4096 { break } }
    return s.count
}

// External encoders via CLI (cwebp, zstd) on a temp PNG / raw stream.
func writePNG(_ img: Img, tx: Int, ty: Int, to url: URL) {
    let sub = img.cg.cropping(to: CGRect(x: tx * tile, y: ty * tile, width: tile, height: tile))!
    let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, sub, nil); CGImageDestinationFinalize(dst)
}
let spawnGate = DispatchSemaphore(value: 4)   // bound concurrent child processes (pipes = file descriptors)
func run(_ tool: String, _ args: [String], stdin: [UInt8]? = nil) -> Int {
    spawnGate.wait(); defer { spawnGate.signal() }
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    var inPipe: Pipe?
    if stdin != nil { inPipe = Pipe(); p.standardInput = inPipe } else { p.standardInput = FileHandle.nullDevice }
    do { try p.run() } catch { return -1 }
    if let stdin, let inPipe { inPipe.fileHandleForWriting.write(Data(stdin)); try? inPipe.fileHandleForWriting.close() }
    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return data.count
}
/// Runs an external encoder that writes an output file; returns bytes.
func externalEncode(_ img: Img, tx: Int, ty: Int, tool: String, args: (String, String) -> [String], ext: String) -> Int {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("tb-\(tx)-\(ty)-\(ext)")
    let inPNG = base.appendingPathExtension("png"), out = base.appendingPathExtension(ext)
    writePNG(img, tx: tx, ty: ty, to: inPNG)
    _ = run(tool, args(inPNG.path, out.path))
    let n = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? -1
    try? FileManager.default.removeItem(at: inPNG); try? FileManager.default.removeItem(at: out)
    return n
}

// QOI (Quite OK Image) lossless, in-process: the fastest credible lossless baseline.
func qoiEncode(_ rgb: [UInt8]) -> Int {
    var out = 14 + 8
    var index = [UInt32](repeating: 0xFFFFFFFF, count: 64)
    var prev: (UInt8, UInt8, UInt8) = (0, 0, 0)
    var runLen = 0
    let n = rgb.count / 3
    for i in 0..<n {
        let r = rgb[i*3], g = rgb[i*3+1], b = rgb[i*3+2]
        if (r, g, b) == prev { runLen += 1; if runLen == 62 || i == n - 1 { out += 1; runLen = 0 }; continue }
        if runLen > 0 { out += 1; runLen = 0 }
        let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        let h = Int((Int(r) * 3 + Int(g) * 5 + Int(b) * 7 + 255 * 11) % 64)
        if index[h] == key { out += 1 }
        else {
            index[h] = key
            let dr = Int(r) - Int(prev.0), dg = Int(g) - Int(prev.1), db = Int(b) - Int(prev.2)
            if (-2...1).contains(dr) && (-2...1).contains(dg) && (-2...1).contains(db) { out += 1 }
            else if (-32...31).contains(dg) && (-8...7).contains(dr - dg) && (-8...7).contains(db - dg) { out += 2 }
            else { out += 4 }
        }
        prev = (r, g, b)
    }
    return out
}

func webpLossless(_ img: Img, tx: Int, ty: Int, near: Int? = nil) -> Int {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tb-\(tx)-\(ty)-\(near ?? 0).png")
    writePNG(img, tx: tx, ty: ty, to: tmp)
    var args = ["-quiet", "-z", "6", tmp.path, "-o", "-"]
    if let near { args = ["-quiet", "-near_lossless", "\(near)", "-z", "6", tmp.path, "-o", "-"] } else { args.insert("-lossless", at: 0) }
    let n = run("/opt/homebrew/bin/cwebp", args)
    try? FileManager.default.removeItem(at: tmp)
    return n
}

// Whole-frame hardware HEVC intra at a fixed quality, and HW JPEG, for reference.
func vtFrame(_ img: Img, codec: CMVideoCodecType, quality: Float, qp: Int?) -> Int {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, img.w, img.h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pb!)
    for y in 0..<img.h { for x in 0..<img.w { let s = (y * img.w + x) * 4, d = y * stride + x * 4
        base[d] = img.rgba[s+2]; base[d+1] = img.rgba[s+1]; base[d+2] = img.rgba[s]; base[d+3] = 255 } }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    var session: VTCompressionSession?
    VTCompressionSessionCreate(allocator: nil, width: Int32(img.w), height: Int32(img.h), codecType: codec,
                               encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
                               imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard let session else { return -1 }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    if let qp { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: qp as CFNumber); VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MinAllowedFrameQP, value: qp as CFNumber) }
    else { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: quality as CFNumber) }
    VTCompressionSessionPrepareToEncodeFrames(session)
    var size = 0
    let sem = DispatchSemaphore(value: 0)
    VTCompressionSessionEncodeFrame(session, imageBuffer: pb!, presentationTimeStamp: CMTime(value: 0, timescale: 30), duration: .invalid, frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary, infoFlagsOut: nil) { _, _, sbuf in
        if let sbuf, let db = CMSampleBufferGetDataBuffer(sbuf) { size = CMBlockBufferGetDataLength(db) }
        sem.signal()
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    _ = sem.wait(timeout: .now() + 5)
    VTCompressionSessionInvalidate(session)
    return size
}

struct Acc { var n = 0; var sums = [String: Int](); mutating func add(_ k: String, _ v: Int) { sums[k, default: 0] += v } }
let codecs = ["raw", "zlib", "pal+lzfse", "qoi"] + (useCLI ? ["webp-ll", "webp-nl60", "jxl-ll-e3", "jxl-ll-e7", "jxl-d1", "avif-ll-s10", "avif-ll-s6", "heic-ll"] : [])

for path in CommandLine.arguments.dropFirst() {
    let img = load(path)
    let tx = img.w / tile, ty = img.h / tile
    var classes = ["uniform": Acc(), "flat≤16": Acc(), "text≤256": Acc(), "rich>256": Acc()]
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: tx * ty) { i in
        if useCLI && i % 4 != 0 { return }   // sample a quarter of the tiles when external encoders are involved
        let x = i % tx, y = i / tx
        let rgb = rgbTile(img, x, y)
        let uc = uniqueColors(rgb)
        let cls = uc == 1 ? "uniform" : uc <= 16 ? "flat≤16" : uc <= 256 ? "text≤256" : "rich>256"
        var r = [String: Int]()
        r["raw"] = rgb.count
        r["lz4"] = compress(rgb, COMPRESSION_LZ4)
        r["lzfse"] = compress(rgb, COMPRESSION_LZFSE)
        r["zlib"] = compress(rgb, COMPRESSION_ZLIB)
        r["sub+lzfse"] = compress(subPredict(rgb), COMPRESSION_LZFSE)
        r["paeth+lzfse"] = compress(paeth(rgb), COMPRESSION_LZFSE)
        if let p = palettize(rgb) { r["pal+lzfse"] = compress(p.indices, COMPRESSION_LZFSE) + p.paletteBytes } else { r["pal+lzfse"] = r["paeth+lzfse"]! }
        r["best-apple"] = min(r["lzfse"]!, r["sub+lzfse"]!, r["paeth+lzfse"]!, r["pal+lzfse"]!) + 1 // +1 byte selector
        r["qoi"] = qoiEncode(rgb)
        if useCLI {
            r["webp-ll"] = webpLossless(img, tx: x, ty: y)
            r["webp-nl60"] = webpLossless(img, tx: x, ty: y, near: 60)
            r["jxl-ll-e3"] = externalEncode(img, tx: x, ty: y, tool: "/opt/homebrew/bin/cjxl", args: { [$0, $1, "-d", "0", "-e", "3", "--quiet"] }, ext: "e3.jxl")
            r["jxl-ll-e7"] = externalEncode(img, tx: x, ty: y, tool: "/opt/homebrew/bin/cjxl", args: { [$0, $1, "-d", "0", "-e", "7", "--quiet"] }, ext: "e7.jxl")
            r["jxl-d1"] = externalEncode(img, tx: x, ty: y, tool: "/opt/homebrew/bin/cjxl", args: { [$0, $1, "-d", "1", "-e", "3", "--quiet"] }, ext: "d1.jxl")
            r["avif-ll-s10"] = externalEncode(img, tx: x, ty: y, tool: "/opt/homebrew/bin/avifenc", args: { ["-l", "-s", "10", "-j", "1", $0, $1] }, ext: "s10.avif")
            r["avif-ll-s6"] = externalEncode(img, tx: x, ty: y, tool: "/opt/homebrew/bin/avifenc", args: { ["-l", "-s", "6", "-j", "1", $0, $1] }, ext: "s6.avif")
            r["heic-ll"] = externalEncode(img, tx: x, ty: y, tool: "/opt/homebrew/bin/heif-enc", args: { ["-L", "-o", $1, $0] }, ext: "heic")
        }
        lock.lock(); classes[cls]!.n += 1; for (k, v) in r { classes[cls]!.add(k, v) }; lock.unlock()
    }
    let name = (path as NSString).lastPathComponent
    print("\n== \(name)  \(img.w)x\(img.h)  tiles \(tx)x\(ty)=\(tx*ty) @ \(tile)px  raw frame \(img.w*img.h*3/1024) KB")
    print(String(format: "%-10@ %5@ ", "class" as NSString, "tiles" as NSString) + codecs.map { String(format: "%9@", $0 as NSString) }.joined(separator: " "))
    var frameTotal = [String: Int]()
    for cls in ["uniform", "flat≤16", "text≤256", "rich>256"] {
        let a = classes[cls]!; guard a.n > 0 else { continue }
        var line = String(format: "%-10@ %5d ", cls as NSString, a.n)
        for c in codecs { let v = a.sums[c] ?? 0; frameTotal[c, default: 0] += v; line += String(format: "%9.0f ", Double(v) / Double(a.n)) }
        print(line + "  (mean bytes/tile)")
    }
    var line = String(format: "%-10@ %5d ", "FRAME KB" as NSString, tx * ty)
    for c in codecs { line += String(format: "%9.0f ", Double(frameTotal[c] ?? 0) / 1024) }
    print(line)
    let hevcQ = [(20, "qp20"), (26, "qp26"), (32, "qp32"), (38, "qp38")].map { "\($0.1)=\(vtFrame(img, codec: kCMVideoCodecType_HEVC, quality: 0, qp: $0.0) / 1024)KB" }
    let jpg = vtFrame(img, codec: kCMVideoCodecType_JPEG, quality: 0.75, qp: nil) / 1024
    print("HEVC HW intra whole frame: " + hevcQ.joined(separator: "  ") + "   JPEG HW q0.75=\(jpg)KB")
}
