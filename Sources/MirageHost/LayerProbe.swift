import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import IOSurface
import ImageIO
import MirageCore

/// `miraged probe-layers`: feasibility and cost check for per-window capture (DESIGN §3.2 layered desktop).
/// Starts one `desktopIndependentWindow` SCStream per window whose title contains `match` (the test
/// bench, i.e. windows of our own), counts frames, reports the process CPU time and the alpha channel of
/// the captured pixels (corners, title bar), and optionally dumps the first window's last frame as PNG.
public final class LayerProbe: NSObject, SCStreamOutput, @unchecked Sendable {
    final class Target {
        let window: SCWindow
        var stream: SCStream?
        var frames = 0
        var dirtyTiles = 0
        var last: CVPixelBuffer?
        var firstFrameNanos: UInt64 = 0
        var lastSurface: IOSurfaceID = 0
        init(window: SCWindow) { self.window = window }
    }
    private var targets: [Target] = []
    private let queue = DispatchQueue(label: "mirage.probe.layers")
    private let startNanos = Clock.nowNanos()

    /// `--mode codec`: the desktop picture without any windows (desktop layer and icons), 2600 px wide, encoded
    /// as 320×320 blocks lossless / near-lossless / lossy q75–92; byte counts only, no pixels leave the process.
    public static func codec(log: @escaping (String) -> Void) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let d = content.displays[0]
    // The desktop picture and icons only: every other window left out (never named in an including filter, which
    // would badge it).
    let f = SCContentFilter(display: d, excludingWindows: content.windows.filter { $0.windowLayer >= 0 })
    let c = SCStreamConfiguration(); c.width = 2600; c.height = 1688; c.pixelFormat = kCVPixelFormatType_32BGRA; c.showsCursor = false
    let img = try await SCScreenshotManager.captureImage(contentFilter: f, configuration: c)
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var totals: [String: Int] = [:]; var photoBlocks = 0, blocks = 0
    px.withUnsafeBytes { p in
        for by in stride(from: 0, to: h - 320, by: 320) { for bx in stride(from: 0, to: w - 320, by: 320) {
            let base = p.baseAddress!.advanced(by: by * w * 4 + bx * 4)
            blocks += 1
            let colours = TileCodec.colourCount(base: base, width: 320, height: 320, stride: w * 4, limit: 4096)
            if colours > 4096 { photoBlocks += 1 }
            totals["lossless", default: 0] += TileCodec.encode(base: base, width: 320, height: 320, stride: w * 4, format: .lossless, effort: 4)!.count
            totals["near-lossless", default: 0] += TileCodec.encode(base: base, width: 320, height: 320, stride: w * 4, format: .nearLossless, effort: 4)!.count
            for q in [75, 85, 92] { totals["lossy q\(q)", default: 0] += TileCodec.encodeLossy(base: base, width: 320, height: 320, stride: w * 4, outWidth: 320, outHeight: 320, quality: Float(q), alpha: false)!.count }
        } }
    }
    let mpx = Double(blocks * 320 * 320) / 1e6
    log("blocks \(blocks), photographic (>4096 colours) \(photoBlocks)")
    for (k, v) in totals.sorted(by: { $0.value > $1.value }) { log(String(format: "%-14@ %8.0f KB per Mpx  (whole 2600x1688 desktop ≈ %5.0f KB)", k as NSString, Double(v) / 1000 / mpx, Double(v) / 1000 / mpx * 2600 * 1688 / 1e6)) }
    }

    /// `--mode badge`: per filter variant, one stream over the first matched window (sourceRect = its frame grown by
    /// 16 pt): whether macOS badges it (a `screencapture -l` of the window is written per variant to `dump` dir), the
    /// alpha around and inside it, frames delivered while it is static, and whether a window covering it shows.
    public static func badge(match: String, seconds: Int, dump: String?, log: @escaping (String) -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pick = ProcessInfo.processInfo.environment["MIRAGE_PROBE_WINDOW"].flatMap { UInt32($0) }
        guard let w = content.windows.first(where: { ($0.title ?? "").contains(match) && (pick == nil || $0.windowID == pick) }), let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) }) ?? content.displays.first else { log("no window matches"); return }
        let ppp = Double(NSScreen.screens.first?.backingScaleFactor ?? 2)
        let src = w.frame.insetBy(dx: -16, dy: -16).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let others = content.windows.filter { $0.windowID != w.windowID }
        let apps = content.applications
        let variants: [(String, SCContentFilter)] = [
            ("independent", SCContentFilter(desktopIndependentWindow: w)),
            ("exclude-windows", SCContentFilter(display: display, excludingWindows: others)),
            ("exclude-apps", SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [w])),
        ]
        for (name, filter) in variants {
            let probe = LayerProbe()
            let c = SCStreamConfiguration()
            let independent = name == "independent"
            if !independent { c.sourceRect = src }
            c.width = Int((independent ? w.frame.width : src.width) * ppp) & ~1; c.height = Int((independent ? w.frame.height : src.height) * ppp) & ~1
            c.pixelFormat = kCVPixelFormatType_32BGRA; c.showsCursor = false; c.queueDepth = 3; c.shouldBeOpaque = false
            c.minimumFrameInterval = CMTime(value: 1, timescale: 30); c.capturesAudio = false
            c.ignoreShadowsSingleWindow = true; c.includeChildWindows = true; c.ignoreShadowsDisplay = true
            let s = SCStream(filter: filter, configuration: c, delegate: nil)
            let t = Target(window: w)
            t.stream = s
            try s.addStreamOutput(probe, type: .screen, sampleHandlerQueue: probe.queue)
            probe.queue.sync { probe.targets.append(t) }
            var r0 = rusage(); getrusage(RUSAGE_SELF, &r0)
            try await s.startCapture()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let dump {
                let out = "\(dump)/badge-\(name).png"
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = ["-x", "-o", "-l\(w.windowID)", out]
                try? p.run(); p.waitUntilExit()
            }
            let f0 = probe.queue.sync { t.frames }
            try await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
            var r1 = rusage(); getrusage(RUSAGE_SELF, &r1)
            let (frames, last) = probe.queue.sync { (t.frames, t.last) }
            try? await s.stopCapture()
            var report = "\(name): \(c.width)x\(c.height), \(frames - f0) frames in \(seconds) s while static"
            if let pb = last {
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pb)
                let pw = CVPixelBufferGetWidth(pb), ph = CVPixelBufferGetHeight(pb)
                func px(_ x: Int, _ y: Int) -> String { let o = min(ph - 1, y) * stride + min(pw - 1, x) * 4; return "bgra(\(base[o]),\(base[o+1]),\(base[o+2]),\(base[o+3]))" }
                let m = Int(16 * ppp)
                let x0 = m, y0 = m, x1 = pw - m - 1, y1 = ph - m - 1
                report += "; edge alpha L \(base[(ph/2)*stride + x0*4+3]),\(base[(ph/2)*stride + (x0+1)*4+3]) R \(base[(ph/2)*stride + x1*4+3]),\(base[(ph/2)*stride + (x1-1)*4+3]) T \(base[y0*stride + (pw/2)*4+3]),\(base[(y0+1)*stride + (pw/2)*4+3]) B \(base[y1*stride + (pw/2)*4+3]),\(base[(y1-1)*stride + (pw/2)*4+3])"
                report += "; margin \(px(m / 2, ph / 2)) corner \(px(m + 2, m + 2)) centre \(px(pw / 2, ph / 2))"
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                if let dump, let img = CGImage.fromBGRA(pb) {
                    let url = URL(fileURLWithPath: "\(dump)/frame-\(name).png")
                    if let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d) }
                }
            } else { report += "; no frame" }
            let cpu = Double(r1.ru_utime.tv_sec - r0.ru_utime.tv_sec + r1.ru_stime.tv_sec - r0.ru_stime.tv_sec) + Double(r1.ru_utime.tv_usec - r0.ru_utime.tv_usec + r1.ru_stime.tv_usec - r0.ru_stime.tv_usec) / 1e6
            log(report + String(format: "; probe CPU %.0f ms", cpu * 1000))
        }
    }

    public static func run(match: String, seconds: Int, scale: Double, dump: String?, mode: String = "window", log: @escaping (String) -> Void) async throws {
        if mode == "codec" { try await codec(log: log); return }
        if mode == "badge" { try await badge(match: match, seconds: seconds, dump: dump, log: log); return }
        let probe = LayerProbe()
        hostLog = log
        // What the window list looks like: owner, level, size, alpha, per window (titles only for matched windows).
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] {
            var byLevel: [Int: Int] = [:]
            for w in list {
                let layer = w[kCGWindowLayer] as? Int ?? 0
                byLevel[layer, default: 0] += 1
            }
            log("on-screen windows by level: " + byLevel.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
            for w in list {
                let layer = w[kCGWindowLayer] as? Int ?? 0
                let owner = w[kCGWindowOwnerName] as? String ?? "?"
                let b = (w[kCGWindowBounds] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
                let title = (w[kCGWindowName] as? String) ?? ""
                let alpha = w[kCGWindowAlpha] as? Double ?? 1
                let shown = title.contains(match) ? title.prefix(40) : (owner == "Window Server" || owner == "Dock" ? Substring(title.prefix(30)) : "")
                let num = w[kCGWindowNumber] as? UInt32 ?? 0
                log(String(format: "  level %4d  %-22@ %5.0fx%-5.0f at %5.0f,%-5.0f alpha %.2f  id %u  %@", layer, owner as NSString, b.width, b.height, b.minX, b.minY, alpha, num, shown as NSString))
            }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if mode == "list" {
            // What ScreenCaptureKit lists for the matching app (CGWindow ids, sizes, layers), against CGWindowList.
            let pids = Set(content.windows.filter { ($0.title ?? "").contains(match) }.compactMap { $0.owningApplication?.processID })
            for w in content.windows where pids.contains(w.owningApplication?.processID ?? -1) {
                log(String(format: "  SCK window %u layer %d %.0fx%.0f on-screen %@ '%@'", w.windowID, w.windowLayer, w.frame.width, w.frame.height, w.isOnScreen ? "yes" : "no", String((w.title ?? "").prefix(30)) as NSString))
            }
            return
        }
        let wanted = content.windows.filter { ($0.title ?? "").contains(match) }
        guard !wanted.isEmpty else { log("no on-screen window whose title contains \"\(match)\""); return }
        log("\(wanted.count) matching windows; starting one SCStream each at scale \(scale)")
        var rusage0 = rusage(); getrusage(RUSAGE_SELF, &rusage0)
        if mode != "window" {
            // Display capture of the same scene, including or excluding the matched windows (the background stream of the layered design).
            guard let display = content.displays.first else { return }
            let t = Target(window: wanted[0])
            let c = SCStreamConfiguration()
            c.width = Int(Double(display.width) * scale) & ~1; c.height = Int(Double(display.height) * scale) & ~1
            c.pixelFormat = kCVPixelFormatType_32BGRA; c.showsCursor = false; c.queueDepth = 3
            c.minimumFrameInterval = CMTime(value: 1, timescale: 30); c.capturesAudio = false
            let filter = SCContentFilter(display: display, excludingWindows: mode == "exclude" ? wanted : [])
            let s = SCStream(filter: filter, configuration: c, delegate: nil)
            try s.addStreamOutput(probe, type: .screen, sampleHandlerQueue: probe.queue)
            try await s.startCapture()
            log("display stream \(c.width)x\(c.height) \(mode == "exclude" ? "excluding \(wanted.count) windows" : "whole") started")
            t.stream = s
            probe.queue.sync { probe.targets.append(t) }
        } else {
        for w in wanted {
            let t = Target(window: w)
            let c = SCStreamConfiguration()
            c.width = max(2, Int(w.frame.width * scale)) & ~1; c.height = max(2, Int(w.frame.height * scale)) & ~1
            c.pixelFormat = kCVPixelFormatType_32BGRA
            c.showsCursor = false
            c.queueDepth = 3
            c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(ProcessInfo.processInfo.environment["PROBE_FPS"].flatMap { Int($0) } ?? 30))
            c.ignoreShadowsSingleWindow = true
            c.ignoreGlobalClipSingleWindow = true
            c.shouldBeOpaque = false
            c.capturesAudio = false
            c.includeChildWindows = ProcessInfo.processInfo.environment["PROBE_NO_CHILDREN"] == nil
            let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: w), configuration: c, delegate: nil)
            try s.addStreamOutput(probe, type: .screen, sampleHandlerQueue: probe.queue)
            let t0 = Clock.nowNanos()
            try await s.startCapture()
            log(String(format: "  stream for window %u (%@) %dx%d started in %.0f ms", w.windowID, (w.title ?? "") .prefix(30) as NSString, c.width, c.height, Double(Clock.elapsed(since: t0, now: Clock.nowNanos())) / 1e6))
            t.stream = s
            probe.queue.sync { probe.targets.append(t) }
        }
        }
        try await Task.sleep(for: .seconds(seconds))
        var rusage1 = rusage(); getrusage(RUSAGE_SELF, &rusage1)
        let cpu = (Double(rusage1.ru_utime.tv_sec - rusage0.ru_utime.tv_sec) + Double(rusage1.ru_utime.tv_usec - rusage0.ru_utime.tv_usec) / 1e6)
            + (Double(rusage1.ru_stime.tv_sec - rusage0.ru_stime.tv_sec) + Double(rusage1.ru_stime.tv_usec - rusage0.ru_stime.tv_usec) / 1e6)
        log(String(format: "after %d s with %d streams: process CPU %.2f s (%.1f %% of one core)", seconds, wanted.count, cpu, cpu / Double(seconds) * 100))
        let targets = probe.queue.sync { probe.targets }
        for t in targets {
            log(String(format: "  window %u: %d frames (first after %.0f ms), %d dirty tiles", t.window.windowID, t.frames, t.firstFrameNanos > 0 ? Double(Clock.elapsed(since: probe.startNanos, now: t.firstFrameNanos)) / 1e6 : -1, t.dirtyTiles))
            if let pb = t.last {
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
                let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
                func px(_ x: Int, _ y: Int) -> String { let o = y * stride + x * 4; return "bgra(\(base[o]),\(base[o+1]),\(base[o+2]),\(base[o+3]))" }
                log("    \(w)x\(h): corner(0,0) \(px(0, 0))  corner(\(w-1),0) \(px(w-1, 0))  (5,5) \(px(5, 5))  title-bar mid \(px(w/2, 10))  centre \(px(w/2, h/2))  bottom-left \(px(0, h-1))")
                // Alpha histogram.
                var alphaBuckets = [Int](repeating: 0, count: 4)
                for y in Swift.stride(from: 0, to: h, by: 4) { for x in Swift.stride(from: 0, to: w, by: 4) { let a = Int(base[y * stride + x * 4 + 3]); alphaBuckets[a == 255 ? 3 : a == 0 ? 0 : a < 128 ? 1 : 2] += 1 } }
                log("    alpha: 0 → \(alphaBuckets[0]), 1–127 → \(alphaBuckets[1]), 128–254 → \(alphaBuckets[2]), 255 → \(alphaBuckets[3]) (sampled every 4 px)")
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                if let dump, t === targets.first {
                    let ci = CIImage(cvPixelBuffer: pb)
                    let ctx = CIContext()
                    if let cg = ctx.createCGImage(ci, from: ci.extent) {
                        let rep = NSBitmapImageRep(cgImage: cg)
                        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: dump)); log("    dumped to \(dump)") }
                    }
                }
            }
        }
        for t in targets { try? await t.stream?.stopCapture() }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        guard let t = targets.first(where: { $0.stream === stream }) else { return }
        t.frames += 1
        if t.firstFrameNanos == 0 { t.firstFrameNanos = Clock.nowNanos(); if let a = attachments.first { hostLog("    frame info: " + a.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " ").replacingOccurrences(of: "\n", with: " ")) } }
        let surf = CVPixelBufferGetIOSurface(pb).map { IOSurfaceGetID($0.takeUnretainedValue()) } ?? 0
        if t.frames <= 6 || t.frames % 50 == 0 {
            // Same IOSurface as last time = SCK did not render anything new (a free "unchanged" check), and a byte compare says whether the pixels differ.
            var same = -1
            if let prev = t.last {
                CVPixelBufferLockBaseAddress(pb, .readOnly); CVPixelBufferLockBaseAddress(prev, .readOnly)
                same = memcmp(CVPixelBufferGetBaseAddress(pb)!, CVPixelBufferGetBaseAddress(prev)!, CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb)) == 0 ? 1 : 0
                CVPixelBufferUnlockBaseAddress(prev, .readOnly); CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            }
            hostLog("    window \(t.window.windowID) frame \(t.frames): IOSurface \(surf) \(surf == t.lastSurface ? "(same as previous)" : "(new)") pixels identical to previous: \(same)")
        }
        t.lastSurface = surf
        t.last = pb
        if let rects = attachments.first?[.dirtyRects] as? [Any] {
            t.dirtyTiles += rects.count
            if t.frames <= 3 || t.frames % 100 == 0 { hostLog("    window \(t.window.windowID) frame \(t.frames): dirty \(rects.map { "\($0)".replacingOccurrences(of: "\n", with: " ") })") }
        } else if t.frames <= 3 { hostLog("    window \(t.window.windowID) frame \(t.frames): no dirtyRects attachment") }
        if t.frames == 1, let a = attachments.first {
            let keys = a.keys.map { $0.rawValue }.sorted().joined(separator: " ")
            hostLog("    first frame of window \(t.window.windowID): \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) attachments: \(keys) contentRect \(a[.contentRect] ?? "nil") scale \(a[.contentScale] ?? "nil") scaleFactor \(a[.scaleFactor] ?? "nil")")
        }
    }
}

extension CGImage {
    /// A BGRA pixel buffer as an image (probe dumps).
    static func fromBGRA(_ pb: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let data = Data(bytes: base, count: stride * h)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
