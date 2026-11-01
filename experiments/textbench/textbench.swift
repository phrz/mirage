// textbench: how far whole-display HEVC moves text from its source, in the gate's own measure.
// A 3200×1800 picture like the bench's (black monospaced text on white at the stream's scale, a purple caption band with
// white text, coloured text) goes through a hardware HEVC session set up as HEVCEncoder's (low-latency rate control,
// real time, no reordering, the QP ceiling under test), as a keyframe and then the same picture again as P-frames (the
// sharpening pass), and is decoded to BGRA. Reported: the 32×18 cell means the truth checker compares (cells over 15
// levels off, the largest difference), PSNR of luma, and bytes.
// Build and run: swiftc -O textbench.swift -o /tmp/textbench && /tmp/textbench
import Foundation
import CoreGraphics
import CoreText
import CoreMedia
import CoreVideo
import VideoToolbox

let W = 3200, H = 1800

func picture() -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    let p = pb!
    CVPixelBufferLockBaseAddress(p, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(p), width: W, height: H, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(p),
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.93, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    // The bench at 400,213 (top-left origin), 1833×1303; caption band 44 pt at 2× scaled to the stream (×0.833).
    let s = 2.0 * 3200 / 3840
    let bx = 400.0, by = 213.0, bw = 1833.0, bh = 1303.0
    let top = { (y: Double) in Double(H) - y }   // CG's origin is bottom-left
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: bx, y: top(by + bh), width: bw, height: bh))
    let cap = 44 * s
    ctx.setFillColor(CGColor(srgbRed: 0.42, green: 0.2, blue: 0.75, alpha: 1)); ctx.fill(CGRect(x: bx, y: top(by + cap), width: bw, height: cap))
    func text(_ str: String, x: Double, y: Double, size: Double, mono: Bool, color: CGColor) {
        let font = mono ? CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)! : CTFontCreateUIFontForLanguage(.system, size, nil)!
        let a = NSAttributedString(string: str, attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: color])
        ctx.textPosition = CGPoint(x: x, y: top(y)); CTLineDraw(CTLineCreateWithAttributedString(a), ctx)
    }
    text("Mirage M2 measurement bench (started by Claude) — a script scrolls, types into and drags this window", x: bx + 12 * s, y: by + 28 * s, size: 13 * s, mono: false, color: CGColor(gray: 1, alpha: 1))
    let line = "func encode(_ pixelBuffer: CVPixelBuffer, captureNanos: UInt64) { let t0 = Clock.nowNanos(); return }"
    var y = by + cap + 80
    for i in 0..<34 {
        let colour: CGColor = i % 9 == 4 ? CGColor(srgbRed: 0.75, green: 0.1, blue: 0.1, alpha: 1) : i % 9 == 7 ? CGColor(srgbRed: 0.1, green: 0.3, blue: 0.85, alpha: 1) : CGColor(gray: 0, alpha: 1)
        text(String(line.dropFirst(i % 7)), x: bx + 20, y: y, size: 14 * s, mono: true, color: colour)
        y += 14 * s * 1.25
    }
    CVPixelBufferUnlockBaseAddress(p, [])
    return p
}

struct Planes { var luma: [Double]; var px: [UInt8] }
func read(_ p: CVPixelBuffer) -> Planes {
    CVPixelBufferLockBaseAddress(p, .readOnly); defer { CVPixelBufferUnlockBaseAddress(p, .readOnly) }
    let b = CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to: UInt8.self), st = CVPixelBufferGetBytesPerRow(p)
    var px = [UInt8](repeating: 0, count: W * H * 4), l = [Double](repeating: 0, count: W * H)
    for y in 0..<H { for x in 0..<W {
        let o = y * st + x * 4, d = (y * W + x) * 4
        px[d] = b[o]; px[d + 1] = b[o + 1]; px[d + 2] = b[o + 2]
        l[y * W + x] = 0.114 * Double(b[o]) + 0.587 * Double(b[o + 1]) + 0.299 * Double(b[o + 2])   // the checker's luminance
    } }
    return Planes(luma: l, px: px)
}
func cells(_ l: [Double]) -> [Double] {
    var c = [Double](repeating: 0, count: 576); let cw = W / 32, ch = H / 18
    for cy in 0..<18 { for cx in 0..<32 {
        var s = 0.0; for y in cy * ch..<(cy + 1) * ch { for x in cx * cw..<(cx + 1) * cw { s += l[y * W + x] } }
        c[cy * 32 + cx] = s / Double(cw * ch)
    } }
    return c
}

final class Box: @unchecked Sendable { var samples: [CMSampleBuffer] = []; let lock = NSLock() }
/// `coarseFirst`: as the host's stream starts, the first frame (the session's IDR) under MinAllowedFrameQP 40, then the
/// floor lifted and the ceiling `maxQP` for the rest (the sharpening pass on the unchanged picture). Every frame reported.
func run(_ name: String, profile: CFString, maxQP: Int?, frames: Int, src: CVPixelBuffer, ref: Planes, coarseFirst: Bool = false) {
    var s: VTCompressionSession?
    let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!] as CFDictionary
    guard VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H), codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec,
                                     imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr,
          let s else { print("\(name): no session"); return }
    func set(_ k: CFString, _ v: CFTypeRef) { let r = VTSessionSetProperty(s, key: k, value: v); if r != noErr { print("  \(name): \(k) rejected (\(r))") } }
    set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
    set(kVTCompressionPropertyKey_ProfileLevel, profile)
    set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
    set(kVTCompressionPropertyKey_AverageBitRate, 50_000_000 as CFNumber)
    set(kVTCompressionPropertyKey_DataRateLimits, [50_000_000 / 8 * 3 / 2, 1.0] as CFArray)
    set(kVTCompressionPropertyKey_ExpectedFrameRate, 30 as CFNumber)
    if let q = maxQP, !coarseFirst { set(kVTCompressionPropertyKey_MaxAllowedFrameQP, q as CFNumber) }
    if coarseFirst { set(kVTCompressionPropertyKey_MinAllowedFrameQP, 40 as CFNumber) }
    VTCompressionSessionPrepareToEncodeFrames(s)
    let box = Box()
    for i in 0..<frames {
        if coarseFirst && i == 1 {
            set(kVTCompressionPropertyKey_MinAllowedFrameQP, 0 as CFNumber)
            if let q = maxQP { set(kVTCompressionPropertyKey_MaxAllowedFrameQP, q as CFNumber) }
        }
        VTCompressionSessionEncodeFrame(s, imageBuffer: src, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 30), duration: .invalid,
                                        frameProperties: nil, infoFlagsOut: nil) { st, _, sb in
            guard st == noErr, let sb else { return }; box.lock.lock(); box.samples.append(sb); box.lock.unlock()
        }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 30))
    }
    VTCompressionSessionInvalidate(s)
    guard let fd = box.samples.first.flatMap({ CMSampleBufferGetFormatDescription($0) }) else { print("\(name): nothing encoded"); return }
    var d: VTDecompressionSession?
    let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
    guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil, imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &d) == noErr, let d else { print("\(name): no decoder"); return }
    var line = "\(name):"
    for (i, sb) in box.samples.enumerated() {
        var out: CVPixelBuffer?
        VTDecompressionSessionDecodeFrame(d, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { _, _, ib, _, _ in out = ib }
        VTDecompressionSessionWaitForAsynchronousFrames(d)
        guard let out, coarseFirst || i == 0 || i == box.samples.count - 1 else { continue }
        let got = read(out)
        let a = cells(ref.luma), b = cells(got.luma)
        let diffs = zip(a, b).map { abs($0 - $1) }
        var se = 0.0; for k in 0..<(W * H) { let e = got.luma[k] - ref.luma[k]; se += e * e }
        let psnr = 10 * log10(255 * 255 / max(1e-9, se / Double(W * H)))
        // Inside the bench's text (cells 5–21, rows 4–15): the largest per-pixel colour error's mean, by channel.
        var ce = 0.0, n = 0.0
        for y in stride(from: 450, to: 1500, by: 2) { for x in stride(from: 500, to: 2100, by: 2) {
            let o = (y * W + x) * 4; for c in 0..<3 { ce += abs(Double(got.px[o + c]) - Double(ref.px[o + c])) }; n += 3
        } }
        line += String(format: "\n   [%@ %6.1f KB] cells >15: %3d, max %4.1f, PSNR %5.2f dB, text mean |RGB err| %4.2f", i == 0 ? "key" : "P\(i)",
                       Double(CMSampleBufferGetTotalSampleSize(sb)) / 1000, diffs.filter { $0 > 15 }.count, diffs.max()!, psnr, ce / n)
    }
    print(line)
    VTDecompressionSessionInvalidate(d)
}

let src = picture(), ref = read(src)
let rounds = 4
run("Main 4:2:0, no ceiling", profile: kVTProfileLevel_HEVC_Main_AutoLevel, maxQP: nil, frames: rounds, src: src, ref: ref)
run("Main 4:2:0, QP<=30 (LAN budget)", profile: kVTProfileLevel_HEVC_Main_AutoLevel, maxQP: 30, frames: rounds, src: src, ref: ref)
run("Main 4:2:0, QP<=20 (sharpening)", profile: kVTProfileLevel_HEVC_Main_AutoLevel, maxQP: 20, frames: rounds, src: src, ref: ref)
run("Main 4:2:0, QP<=10", profile: kVTProfileLevel_HEVC_Main_AutoLevel, maxQP: 10, frames: rounds, src: src, ref: ref)
run("Main 4:2:0, coarse IDR (QP>=40), then QP<=30", profile: kVTProfileLevel_HEVC_Main_AutoLevel, maxQP: 30, frames: 8, src: src, ref: ref, coarseFirst: true)
run("Main 4:2:0, coarse IDR (QP>=40), then QP<=20", profile: kVTProfileLevel_HEVC_Main_AutoLevel, maxQP: 20, frames: 8, src: src, ref: ref, coarseFirst: true)
