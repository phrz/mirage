import XCTest
import AppKit
import CoreImage
@testable import MirageHost

/// The curtain draws the blurred picture it is given (phrz saw only the plain gray: the test shot ran before the picture
/// landed, and nothing forced a redraw after setPicture).
final class CurtainRenderTests: XCTestCase {
    private func render(_ v: NSView) -> (px: [UInt8], w: Int, h: Int)? {
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let cg = rep.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { b in
            CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (px, w, h)
    }
    /// Luminance variance and the share of pixels at the curtain's 0.25 gray, over the top-left quarter (away from the block).
    private func stats(_ r: (px: [UInt8], w: Int, h: Int)) -> (variance: Double, gray: Double) {
        var sum = 0.0, sq = 0.0, gray = 0, n = 0
        for y in 0..<(r.h / 2) { for x in 0..<(r.w / 2) {
            let o = (y * r.w + x) * 4
            let l = (Double(r.px[o]) + Double(r.px[o + 1]) + Double(r.px[o + 2])) / 765
            sum += l; sq += l * l; n += 1
            if abs(Int(r.px[o]) - 64) < 4 && abs(Int(r.px[o + 1]) - 64) < 4 && abs(Int(r.px[o + 2]) - 64) < 4 { gray += 1 }
        } }
        let m = sum / Double(n); return (sq / Double(n) - m * m, Double(gray) / Double(n))
    }
    private func syntheticPicture(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1), CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1)] as CFArray, locations: nil)!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        for i in 0..<12 { ctx.setFillColor(CGColor(gray: i % 2 == 0 ? 0.95 : 0.05, alpha: 1)); ctx.fill(CGRect(x: i * w / 12, y: 0, width: w / 24, height: h / 2)) }
        return ctx.makeImage()!
    }

    func testTheCurtainDrawsTheBlurredPictureNotTheGray() throws {
        let v = CurtainView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        let before = try XCTUnwrap(render(v))
        XCTAssertGreaterThan(stats(before).gray, 0.9, "no picture: the plain gray")
        v.setPicture(syntheticPicture(1600, 900))
        let after = try XCTUnwrap(render(v))
        let s = stats(after)
        XCTAssertLessThan(s.gray, 0.05, "the picture replaced the gray")
        XCTAssertGreaterThan(s.variance, 0.0005, "a picture (blurred), not a flat fill")
        // Close to the blurred source itself (top-left quarter, away from the block): mean difference under 12 levels.
        let blurred = try XCTUnwrap(CurtainView.blur(syntheticPicture(1600, 900)))
        let ref = try XCTUnwrap(render({ let iv = NSImageView(frame: v.bounds); iv.imageScaling = .scaleAxesIndependently; iv.image = NSImage(cgImage: blurred, size: v.bounds.size); return iv }()))
        var d = 0.0, n = 0
        for y in 0..<(after.h / 2) { for x in 0..<(after.w / 2) { let o = (y * after.w + x) * 4; d += Double(abs(Int(after.px[o]) - Int(ref.px[o])) + abs(Int(after.px[o + 1]) - Int(ref.px[o + 1])) + abs(Int(after.px[o + 2]) - Int(ref.px[o + 2]))) / 3; n += 1 } }
        XCTAssertLessThan(d / Double(n), 12, "the curtain shows the blurred picture")
    }

    /// In a window (as on the host, where no display cycle may come): after apply nothing waits for one. (Neither this nor the
    /// render above reads the window server's pixels; the live check is the test shot on the host.)
    func testApplyDrawsTheWindowNow() throws {
        let frame = NSRect(x: -10_000, y: -10_000, width: 800, height: 450)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let v = CurtainView(frame: NSRect(origin: .zero, size: frame.size)); w.contentView = v
        w.display()
        XCTAssertTrue(v.drawn, "settled")
        v.apply(syntheticPicture(800, 450))
        XCTAssertTrue(v.drawn, "apply: nothing left for a display cycle")

        let r = try XCTUnwrap(render(v)); XCTAssertLessThan(stats(r).gray, 0.05)
    }

    /// MIRAGE_CURTAIN_PREVIEW=<file.png>: the curtain over a stock macOS wallpaper, rendered offscreen (nothing on screen),
    /// for a person to judge the look.
    func testPreviewOverAStockWallpaper() throws {
        guard let out = ProcessInfo.processInfo.environment["MIRAGE_CURTAIN_PREVIEW"] else { throw XCTSkip("set MIRAGE_CURTAIN_PREVIEW=<png> for the preview") }
        let src = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIRAGE_CURTAIN_PREVIEW_WALLPAPER"] ?? "/System/Library/Desktop Pictures/Sonoma.heic")
        let ci = try XCTUnwrap(CIImage(contentsOf: src))
        let k = max(3200 / ci.extent.width, 1800 / ci.extent.height)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let crop = CGRect(x: scaled.extent.midX - 1600, y: scaled.extent.midY - 900, width: 3200, height: 1800)
        let picture = try XCTUnwrap(CIContext().createCGImage(scaled, from: crop))
        // Mirage's icon, as on the host (the test runner's own icon is a generic folder).
        let app = ["/Applications/Mirage.app", NSHomeDirectory() + "/Applications/Mirage.app"].first { FileManager.default.fileExists(atPath: $0) }
        let v = CurtainView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900), icon: app.map { NSWorkspace.shared.icon(forFile: $0) })
        v.setPicture(picture)
        v.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out))
    }
}
