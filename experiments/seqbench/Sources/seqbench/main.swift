// seqbench: per-frame HEVC hardware low-latency cost and quality for synthetic desktop
// interactions (static, typing, scrolling, window drag) at a given bitrate target.
// Decodes every frame and reports PSNR of the dirty region, so bytes and quality are seen together.
import Foundation
import ImageIO
import CoreGraphics
import VideoToolbox
import CoreMedia
import CoreVideo

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: seqbench image.png [kbps=800] [scenario=all] [lowlat=1]"); exit(1) }
let kbps = Int(args.count > 2 ? args[2] : "800")!
let scenarioArg = args.count > 3 ? args[3] : "all"
let lowLat = (args.count > 4 ? args[4] : "1") == "1"
let fps = 30

// Load image as BGRA.
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!
let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let W = cg.width & ~1, H = cg.height & ~1
var base = [UInt8](repeating: 0, count: W * H * 4)
let ctx = CGContext(data: &base, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))

func pixelBuffer(_ px: [UInt8]) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let dst = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pb!)
    px.withUnsafeBufferPointer { p in for y in 0..<H { memcpy(dst + y * stride, p.baseAddress! + y * W * 4, W * 4) } }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

// Scenarios produce frame N from the base image.
struct Rect { var x: Int, y: Int, w: Int, h: Int }
func frame(_ scenario: String, _ n: Int) -> ([UInt8], Rect) {
    var px = base
    switch scenario {
    case "static":
        return (px, Rect(x: 0, y: 0, w: 0, h: 0))
    case "typing":
        // One 64x64 tile changes per frame: copy a text tile from elsewhere into a line.
        let r = Rect(x: 200 + (n % 12) * 64, y: 400, w: 64, h: 64)
        let sx = 200 + ((n + 5) % 12) * 64, sy = 464
        for y in 0..<64 { for x in 0..<64 { for c in 0..<4 { px[((r.y + y) * W + r.x + x) * 4 + c] = base[((sy + y) * W + sx + x) * 4 + c] } } }
        return (px, r)
    case "scroll":
        // A 1200x900 window region scrolls up 40 px per frame; new rows come from further down the image.
        let r = Rect(x: 100, y: 100, w: min(1200, W - 100), h: min(900, H - 200))
        let dy = (n * 40) % max(1, H - r.y - r.h)
        for y in 0..<r.h { let sy = r.y + y + dy; memcpy(&px[((r.y + y) * W + r.x) * 4], Array(base[((sy * W + r.x) * 4)..<((sy * W + r.x + r.w) * 4)]), r.w * 4) }
        return (px, r)
    case "drag":
        // A 900x600 window moves 24 px right and 12 px down per frame over the desktop.
        let r = Rect(x: 100 + n * 24, y: 150 + n * 12, w: 900, h: 600)
        guard r.x + r.w < W, r.y + r.h < H else { return (px, Rect(x: 0, y: 0, w: 0, h: 0)) }
        for y in 0..<r.h { memcpy(&px[((r.y + y) * W + r.x) * 4], Array(base[(((150 + y) * W + 100) * 4)..<(((150 + y) * W + 100 + r.w) * 4)]), r.w * 4) }
        return (px, Rect(x: 100, y: 150, w: r.w + n * 24, h: r.h + n * 12))
    default: fatalError("unknown scenario")
    }
}

// Encoder.
var session: VTCompressionSession?
var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
if lowLat { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H), codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
guard let session else { print("no encoder"); exit(1) }
func set(_ k: CFString, _ v: Any) { VTSessionSetProperty(session, key: k, value: v as CFTypeRef) }
set(kVTCompressionPropertyKey_RealTime, true)
set(kVTCompressionPropertyKey_AllowFrameReordering, false)
set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
set(kVTCompressionPropertyKey_AverageBitRate, kbps * 1000)
set(kVTCompressionPropertyKey_DataRateLimits, [kbps * 1000 / 8, 1] as [Any])
set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 3000)
set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
if !lowLat { set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0) }
VTCompressionSessionPrepareToEncodeFrames(session)

// Decoder, created from the first keyframe's format description.
var decoder: VTDecompressionSession?
func decode(_ sbuf: CMSampleBuffer) -> CVPixelBuffer? {
    if decoder == nil {
        let fmt = CMSampleBufferGetFormatDescription(sbuf)!
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil, imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &decoder)
    }
    var out: CVPixelBuffer?
    let sem = DispatchSemaphore(value: 0)
    VTDecompressionSessionDecodeFrame(decoder!, sampleBuffer: sbuf, flags: [], infoFlagsOut: nil) { _, _, pb, _, _ in out = pb; sem.signal() }
    _ = sem.wait(timeout: .now() + 2)
    return out
}
func psnr(_ pb: CVPixelBuffer, _ ref: [UInt8], _ r: Rect) -> Double {
    guard r.w > 0 else { return 0 }
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    var se = 0.0; var n = 0.0
    for y in r.y..<(r.y + r.h) { for x in r.x..<(r.x + r.w) { for c in 0..<3 {
        let d = Double(p[y * stride + x * 4 + c]) - Double(ref[(y * W + x) * 4 + c]); se += d * d; n += 1 } } }
    let mse = se / n
    return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
}

let scenarios = scenarioArg == "all" ? ["static", "typing", "scroll", "drag"] : [scenarioArg]
print("seqbench \(W)x\(H) HEVC HW \(lowLat ? "low-latency" : "normal") target \(kbps) kbps, \(fps) fps nominal\n")
var pts: Int64 = 0
for sc in scenarios {
    var sizes = [Int](); var psnrs = [Double]()
    var encodeMs = [Double]()
    for n in 0..<40 {
        let (px, r) = frame(sc, n)
        let pb = pixelBuffer(px)
        let sem = DispatchSemaphore(value: 0)
        var size = 0; var key = false; var sample: CMSampleBuffer?
        let t0 = Date()
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: CMTime(value: pts, timescale: Int32(fps)), duration: CMTime(value: 1, timescale: Int32(fps)), frameProperties: nil, infoFlagsOut: nil) { _, _, sbuf in
            if let sbuf, let db = CMSampleBufferGetDataBuffer(sbuf) {
                size = CMBlockBufferGetDataLength(db); sample = sbuf
                if let a = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]], let f = a.first { key = !(f[kCMSampleAttachmentKey_NotSync] as? Bool ?? false) }
            }
            sem.signal()
        }
        pts += 1
        _ = sem.wait(timeout: .now() + 2)
        encodeMs.append(Date().timeIntervalSince(t0) * 1000)
        sizes.append(size)
        if let sample, let dec = decode(sample) { psnrs.append(psnr(dec, px, r)) } else { psnrs.append(0) }
        if n == 0 { print("  \(sc): first frame \(key ? "KEY" : "P") \(size / 1024) KB") }
    }
    let p = Array(sizes.dropFirst(5)), q = Array(psnrs.dropFirst(5))
    let mean = Double(p.reduce(0, +)) / Double(p.count)
    let maxv = p.max()!
    let qm = q.reduce(0, +) / Double(q.count)
    let serialMs = mean * 8 / Double(kbps)
    print(String(format: "  %-8@ P-frames: mean %6.0f B  max %6.0f B  ≈ %5.1f ms on the wire at %d kbps  | dirty-region PSNR %4.1f dB  | encode %4.1f ms", sc as NSString, mean, Double(maxv), serialMs, kbps, qm, encodeMs.dropFirst(5).reduce(0, +) / Double(encodeMs.count - 5)))
}
