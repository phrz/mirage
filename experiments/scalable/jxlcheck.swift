// Does ImageIO (macOS here; the iOS framework is the same code) decode JPEG XL, losslessly, and progressively?
// Usage: jxlcheck SOURCE.png FILE.jxl [FILE.jxl ...]
// For each file: full decode compared pixel for pixel with the PNG (both drawn through ImageIO into the same
// bitmap format and colour space), decode time, then incremental decode from 10 %, 20 % … of the bytes: whether
// ImageIO yields an image for a prefix, and how close it is.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func pixels(_ img: CGImage, space: CGColorSpace) -> [UInt8] {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { p in
        let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setBlendMode(.copy)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return buf
}

let ids = CGImageSourceCopyTypeIdentifiers() as! [String]
print("ImageIO decodable types include public.jpeg-xl:", ids.contains("public.jpeg-xl"))
let dst = CGImageDestinationCopyTypeIdentifiers() as! [String]
print("ImageIO can encode public.jpeg-xl:", dst.contains("public.jpeg-xl"))
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { exit(0) }
let srcImg = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: args[0]) as CFURL, nil)!, 0, nil)!
let space = srcImg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
let ref = pixels(srcImg, space: space)
for path in args.dropFirst() {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    let t0 = Date()
    guard let s = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
        print("\(path): ImageIO could not decode"); continue
    }
    let px = pixels(img, space: space)
    let ms = Date().timeIntervalSince(t0) * 1000
    var diff = 0, maxd = 0
    for i in 0..<min(px.count, ref.count) where i % 4 != 3 { let d = abs(Int(px[i]) - Int(ref[i])); if d > 0 { diff += 1; maxd = max(maxd, d) } }
    print("\(path): \(data.count) B, \(img.width)x\(img.height), type \(CGImageSourceGetType(s) ?? "?" as CFString), decode+draw \(String(format: "%.1f", ms)) ms, samples differing from PNG: \(diff) (max \(maxd))")
    var line = "  incremental:"
    for pct in stride(from: 10, through: 100, by: 10) {
        let inc = CGImageSourceCreateIncremental(nil)
        let n = data.count * pct / 100
        CGImageSourceUpdateData(inc, data.prefix(n) as CFData, pct == 100)
        let st = CGImageSourceGetStatusAtIndex(inc, 0)
        if let im = CGImageSourceCreateImageAtIndex(inc, 0, nil) {
            let p = pixels(im, space: space)
            var err = 0.0
            for i in stride(from: 0, to: min(p.count, ref.count), by: 4) { err += Double(abs(Int(p[i + 1]) - Int(ref[i + 1]))) }
            line += " \(pct)%:img(status \(st.rawValue), mean|dG| \(String(format: "%.1f", err / Double(ref.count / 4))))"
        } else { line += " \(pct)%:none(status \(st.rawValue))" }
    }
    print(line)
}
