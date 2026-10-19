// bytrec: records short, realistic sequences of window content for the byte-race replay.
//
// Every scene is content this process generates itself, in its own windows (no input injection, no
// Apple Events, nothing of anyone else's screen): typing into a text view, terminal output, a scrolled
// document, a spinner, flat and shaded animations, a video clip, and a mixed set of three windows. Each
// window is captured as its own layer with ScreenCaptureKit (desktop-independent window filter, native
// backing scale, 30 fps, like the host captures a frontmost window layer since M3.1) and written as
// `<out>/<scene>/<layer>.frames`: header "BRF1" w h, then per delivered frame [u64 ns since start]
// [u32 length][LZ4(frame XOR previous frame)]. The windows never become key (accessory app, ordered
// front without activating), so nothing typed elsewhere can reach them.
//
// Usage: bytrec <scene> <seconds> <outdir> [--clip path.mp4]
// Scenes: typing terminal scroll spinner anim anim-rich video mixed

import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import Compression

// MARK: Deterministic randomness (scenes are reproducible)

struct RNG {
    var s: UInt64
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; var x = s; x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33; return x }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * uniform() }
    mutating func int(_ a: Int, _ b: Int) -> Int { a + Int(next() % UInt64(b - a + 1)) }
    mutating func chance(_ p: Double) -> Bool { uniform() < p }
}

// MARK: Frame writer

final class FrameWriter {
    let url: URL
    let handle: FileHandle
    let q: DispatchQueue
    var prev: [UInt8] = []
    var w = 0, h = 0
    var frames = 0, bytes = 0, rawBytes = 0
    let t0: UInt64
    var scratch: [UInt8] = []

    init(url: URL, t0: UInt64) {
        self.url = url; self.t0 = t0
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try! FileHandle(forWritingTo: url)
        q = DispatchQueue(label: "writer.\(url.lastPathComponent)")
    }

    func add(_ px: [UInt8], width: Int, height: Int, nanos: UInt64) {
        q.async { [self] in
            if w == 0 {
                w = width; h = height
                var hdr = Data("BRF1".utf8)
                var a = UInt32(w), b = UInt32(h)
                hdr.append(Data(bytes: &a, count: 4)); hdr.append(Data(bytes: &b, count: 4))
                handle.write(hdr)
                prev = [UInt8](repeating: 0, count: w * h * 4)
                scratch = [UInt8](repeating: 0, count: w * h * 4 + 65536)
            }
            guard width == w, height == h else { return }   // a resize would be a new layer; scenes never resize
            var x = px
            x.withUnsafeMutableBufferPointer { xb in prev.withUnsafeBufferPointer { pb in
                let n = xb.count / 8
                xb.baseAddress!.withMemoryRebound(to: UInt64.self, capacity: n) { xa in pb.baseAddress!.withMemoryRebound(to: UInt64.self, capacity: n) { pa in
                    for i in 0..<n { xa[i] ^= pa[i] }
                } }
            } }
            let len = scratch.withUnsafeMutableBufferPointer { s in x.withUnsafeBufferPointer { src in
                compression_encode_buffer(s.baseAddress!, s.count, src.baseAddress!, src.count, nil, COMPRESSION_LZ4)
            } }
            precondition(len > 0, "LZ4 failed")
            var rec = Data()
            var t = nanos &- t0, l = UInt32(len)
            rec.append(Data(bytes: &t, count: 8)); rec.append(Data(bytes: &l, count: 4))
            rec.append(scratch.withUnsafeBufferPointer { Data(buffer: UnsafeBufferPointer(rebasing: $0[0..<len])) })
            handle.write(rec)
            prev = px
            frames += 1; bytes += rec.count; rawBytes += px.count
        }
    }

    func finish() -> (frames: Int, bytes: Int) { q.sync { try? handle.close(); return (frames, bytes) } }
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: FrameWriter
    var stream: SCStream?
    var complete = 0, idle = 0
    init(writer: FrameWriter) { self.writer = writer }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        guard let info = atts?.first, let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        guard status == .complete, let pb = CMSampleBufferGetImageBuffer(sb) else { idle += 1; return }
        complete += 1
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let nanos = UInt64(max(0, CMTimeGetSeconds(pts)) * 1e9)
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { d in for y in 0..<h { memcpy(d.baseAddress! + y * w * 4, base + y * stride, w * 4) } }
        writer.add(px, width: w, height: h, nanos: nanos)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { FileHandle.standardError.write("stream stopped: \(error)\n".data(using: .utf8)!) }
}

// MARK: Scenes

protocol Driver: AnyObject { func tick(_ t: Double) }

/// Views whose pixels are media (animation, spinner, video), per window: the replay counts every other tile as text/UI.
var mediaViews: [ObjectIdentifier: [NSView]] = [:]
func markMedia(_ v: NSView, in w: NSWindow) { mediaViews[ObjectIdentifier(w), default: []].append(v) }
/// A view's rect in captured pixels: the capture covers the window frame (title bar included), top-left origin.
func pixelRect(_ v: NSView, _ w: NSWindow) -> [Int] {
    let r = v.convert(v.bounds, to: nil), s = w.backingScaleFactor, fh = w.frame.height
    return [Int(r.minX * s), Int((fh - r.maxY) * s), Int(r.width * s), Int(r.height * s)]
}

let bodyFont = NSFont.systemFont(ofSize: 13)
let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

func makeWindow(_ title: String, _ rect: NSRect) -> NSWindow {
    let w = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    w.title = title
    w.isReleasedWhenClosed = false
    return w
}

func scrolledTextView(_ frame: NSRect, font: NSFont, fg: NSColor, bg: NSColor) -> (NSScrollView, NSTextView) {
    let sv = NSScrollView(frame: frame)
    sv.hasVerticalScroller = true
    sv.autoresizingMask = [.width, .height]
    sv.drawsBackground = true
    sv.backgroundColor = bg
    let tv = NSTextView(frame: NSRect(origin: .zero, size: sv.contentSize))
    tv.minSize = NSSize(width: 0, height: sv.contentSize.height)
    tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.autoresizingMask = [.width]
    tv.textContainer?.widthTracksTextView = true
    tv.textContainerInset = NSSize(width: 12, height: 10)
    tv.font = font; tv.textColor = fg; tv.backgroundColor = bg; tv.drawsBackground = true
    tv.isRichText = true
    tv.isEditable = true
    sv.documentView = tv
    return (sv, tv)
}

let prose = """
The link from the hotel to the studio is slow and far away, so every byte has to earn its place. A keystroke should come back as the few pixels it changed, sharp, one round trip later. Scrolling should move what is already there and fetch only the new line at the bottom. Video belongs to things that genuinely move: a clip, a game, an animation that never settles. Everything else is text, and text has to be exact, because a soft seven looks like a one and a soft comma looks like a period. The question is not whether video is efficient; it is whether it is efficient for this region, now, compared with simply sending the pixels that changed.
"""

let words = "region frame tile video lossless motion budget latency pixel window scroll cache hash encoder decoder reference keyframe refresh switch policy estimate bytes quality text glyph caret terminal document spinner animation clip episode oracle classifier hysteresis calm sustained intra predict stream layer canvas mask sharp soft exact".split(separator: " ").map(String.init)

func paragraph(_ r: inout RNG, sentences: Int) -> String {
    var out: [String] = []
    for _ in 0..<sentences {
        var s: [String] = []
        for i in 0..<r.int(7, 18) { var w = words[r.int(0, words.count - 1)]; if i == 0 { w = w.prefix(1).uppercased() + w.dropFirst() }; s.append(w) }
        out.append(s.joined(separator: r.chance(0.1) ? ", " : " ") + ".")
    }
    return out.joined(separator: " ")
}

/// A blinking caret drawn by hand: the windows never become key, so NSTextView draws none.
final class Caret: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.textColor.setFill(); bounds.fill() }
}

final class TypingDriver: Driver {
    let tv: NSTextView
    let caret = Caret()
    var r = RNG(s: 42)
    var nextKey = 0.8
    var lastKey = 0.0
    let text: [Character]
    var pos = 0
    var backspaces = 0
    var retype: [Character] = []
    init(window: NSWindow, seed: UInt64 = 42) {
        r = RNG(s: seed)
        let (sv, tv) = scrolledTextView(window.contentView!.bounds, font: bodyFont, fg: .textColor, bg: .textBackgroundColor)
        self.tv = tv
        var pr = RNG(s: seed &+ 7)
        tv.string = "Notes — link budget\n\n" + paragraph(&pr, sentences: 5) + "\n\n" + paragraph(&pr, sentences: 4) + "\n\n"
        window.contentView!.addSubview(sv)
        tv.addSubview(caret)
        text = Array(prose + " " + prose)
        place()
    }
    func place() {
        let n = tv.string.utf16.count
        tv.setSelectedRange(NSRange(location: n, length: 0))
        tv.scrollRangeToVisible(NSRange(location: n, length: 0))
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        var rect: NSRect
        if n > 0 {
            let g = lm.glyphIndexForCharacter(at: n - 1)
            rect = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
            if tv.string.hasSuffix("\n") { rect = NSRect(x: 0, y: rect.maxY, width: 0, height: rect.height) }
            else { rect.origin.x = rect.maxX }
        } else { rect = NSRect(x: 0, y: 0, width: 0, height: 16) }
        let o = tv.textContainerOrigin
        caret.frame = NSRect(x: o.x + rect.minX, y: o.y + rect.minY, width: 1.5, height: rect.height)
    }
    func tick(_ t: Double) {
        // Blink 0.5 s on / 0.5 s off, solid for 0.5 s after each key (as AppKit does).
        let since = t - lastKey
        caret.isHidden = since > 0.5 && Int((since - 0.5) / 0.5) % 2 == 0
        guard t >= nextKey else { return }
        let ts = tv.textStorage!
        let attrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.textColor]
        var delay = r.range(0.07, 0.26)
        if backspaces > 0 {
            ts.deleteCharacters(in: NSRange(location: ts.length - 1, length: 1)); backspaces -= 1; delay = r.range(0.06, 0.12)
        } else if !retype.isEmpty {
            ts.append(NSAttributedString(string: String(retype.removeFirst()), attributes: attrs))
        } else {
            let c = text[pos % text.count]; pos += 1
            ts.append(NSAttributedString(string: String(c), attributes: attrs))
            if c == " " { delay += r.range(0.0, 0.15) }
            if c == "." || c == "," { delay += c == "." ? r.range(0.6, 1.8) : r.range(0.2, 0.5) }
            if c != " ", r.chance(0.025) {   // a typo: a few characters back out and are typed again
                let k = r.int(1, 4)
                backspaces = k
                retype = Array(ts.string.suffix(k))
            }
        }
        lastKey = t; nextKey = t + delay
        place()
    }
}

final class TerminalDriver: Driver {
    let tv: NSTextView
    var r = RNG(s: 7)
    var phaseEnd = 0.0
    var mode = 0            // 0 pause, 1 burst of lines, 2 progress bar
    var rate = 0.0, carry = 0.0, progress = 0.0
    var lineNo = 0
    let attrs: [NSAttributedString.Key: Any]
    init(window: NSWindow, seed: UInt64 = 7) {
        r = RNG(s: seed)
        let bg = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1), fg = NSColor(srgbRed: 0.85, green: 0.86, blue: 0.84, alpha: 1)
        let (sv, tv) = scrolledTextView(window.contentView!.bounds, font: monoFont, fg: fg, bg: bg)
        sv.hasVerticalScroller = false
        self.tv = tv
        attrs = [.font: monoFont, .foregroundColor: fg]
        window.contentView!.addSubview(sv)
        for _ in 0..<60 { append(line()) }
    }
    func line() -> String {
        lineNo += 1
        let files = ["TileTracker", "ShiftDetector", "RateController", "Compositor", "DesktopStreamer", "HEVCEncoder", "FrameAssembler", "ViewerSession", "UnifiedLayout", "NativeChrome"]
        let f = files[r.int(0, files.count - 1)]
        switch r.int(0, 9) {
        case 0: return "warning: \(f).swift:\(r.int(10, 900)):\(r.int(1, 80)): variable 'x\(r.int(0, 99))' was never mutated; consider changing to 'let'"
        case 1: return "[\(lineNo)/2311] Linking \(f).o"
        case 2: return "test \(f)Tests.test\(words[r.int(0, words.count - 1)].capitalized)() passed (\(String(format: "%.3f", r.range(0.001, 0.4))) seconds)"
        default: return "[\(lineNo)/2311] Compiling MirageCore \(f).swift"
        }
    }
    func append(_ s: String) { tv.textStorage!.append(NSAttributedString(string: s + "\n", attributes: attrs)) }
    func tick(_ t: Double) {
        if t >= phaseEnd {
            let k = r.uniform()
            if mode != 0 { mode = 0; phaseEnd = t + r.range(1.0, 4.0) }
            else if k < 0.7 { mode = 1; rate = r.range(15, 80); phaseEnd = t + r.range(0.5, 3.0) }
            else { mode = 2; progress = 0; phaseEnd = t + r.range(2.0, 4.0); append("Fetching https://github.com/apple/swift-argument-parser.git"); append("") }
        }
        switch mode {
        case 1:
            carry += rate / 60
            var n = 0
            while carry >= 1 { carry -= 1; append(line()); n += 1 }
            if n > 0 { tv.scrollToEndOfDocument(nil) }
        case 2:
            progress = min(1, progress + r.range(0.0, 0.02))
            let bars = Int(progress * 40)
            let s = "Downloading [" + String(repeating: "#", count: bars) + String(repeating: " ", count: 40 - bars) + "] " + String(format: "%3d%% %5.1f MB/s", Int(progress * 100), r.range(2, 9))
            let ts = tv.textStorage!
            // Rewrite the last line in place (a carriage-return progress bar).
            let str = ts.string as NSString
            let end = str.length - 1
            let start = str.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: max(0, end))).location + 1
            ts.replaceCharacters(in: NSRange(location: start, length: end - start), with: NSAttributedString(string: s, attributes: attrs))
            tv.scrollToEndOfDocument(nil)
        default: break
        }
    }
}

final class ScrollDriver: Driver {
    let sv: NSScrollView
    var r = RNG(s: 3)
    var y = 0.0, v = 0.0
    var phaseEnd = 0.6
    var mode = 0            // 0 reading, 1 flick (momentum), 2 slow drag
    var lastT = 0.0
    init(window: NSWindow) {
        let (sv, tv) = scrolledTextView(window.contentView!.bounds, font: bodyFont, fg: .textColor, bg: .textBackgroundColor)
        self.sv = sv
        var pr = RNG(s: 11)
        let doc = NSMutableAttributedString()
        let h1: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.textColor]
        let h2: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.textColor]
        let body: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.textColor]
        let code: [NSAttributedString.Key: Any] = [.font: monoFont, .foregroundColor: NSColor.systemPurple]
        doc.append(NSAttributedString(string: "Remote desktop over bad links\n\n", attributes: h1))
        for s in 0..<40 {
            doc.append(NSAttributedString(string: "\(s + 1). " + paragraph(&pr, sentences: 1).dropLast().capitalized + "\n\n", attributes: h2))
            for _ in 0..<pr.int(2, 3) { doc.append(NSAttributedString(string: paragraph(&pr, sentences: pr.int(3, 6)) + "\n\n", attributes: body)) }
            if pr.chance(0.4) { doc.append(NSAttributedString(string: "    let bytes = race(lossless: tiles, video: estimate)\n    if bytes.video * 1.5 < bytes.lossless { switchToVideo(region) }\n\n", attributes: code)) }
        }
        tv.textStorage!.setAttributedString(doc)
        window.contentView!.addSubview(sv)
    }
    func tick(_ t: Double) {
        let dt = max(0, t - lastT); lastT = t
        if t >= phaseEnd || (mode == 1 && abs(v) < 15) {
            if mode != 0 { mode = 0; v = 0; phaseEnd = t + r.range(1.2, 3.0) }
            else if r.chance(0.75) { mode = 1; v = r.range(1200, 3600) * (r.chance(0.2) ? -1 : 1); phaseEnd = t + 4 }
            else { mode = 2; v = r.range(120, 320) * (r.chance(0.3) ? -1 : 1); phaseEnd = t + r.range(0.6, 1.4) }
        }
        if mode == 1 { v *= exp(-dt / 0.33) }
        if mode != 0 {
            let maxY = Double((sv.documentView?.frame.height ?? 0) - sv.contentSize.height)
            y = min(max(0, y + v * dt), maxY)
            if y <= 0 || y >= maxY { v = -v * 0.2 }
            let snapped = (y * 2).rounded() / 2   // whole device pixels at 2x
            sv.contentView.scroll(to: NSPoint(x: 0, y: snapped))
            sv.reflectScrolledClipView(sv.contentView)
        }
    }
}

func staticPage(_ view: NSView, title: String, seed: UInt64, avoiding hole: NSRect) {
    var pr = RNG(s: seed)
    let b = view.bounds
    let t = NSTextField(labelWithString: title)
    t.font = NSFont.boldSystemFont(ofSize: 18)
    t.frame = NSRect(x: 20, y: b.height - 44, width: b.width - 40, height: 26)
    view.addSubview(t)
    // Text in the columns left of and below the hole.
    let left = NSRect(x: 20, y: hole.minY, width: max(0, hole.minX - 40), height: hole.height)
    let below = NSRect(x: 20, y: 16, width: b.width - 40, height: max(0, hole.minY - 30))
    for r in [left, below] where r.width > 60 && r.height > 40 {
        let f = NSTextField(wrappingLabelWithString: paragraph(&pr, sentences: 8))
        f.font = bodyFont
        f.frame = r
        view.addSubview(f)
    }
}

final class SpinnerDriver: Driver {
    init(window: NSWindow) {
        let v = window.contentView!
        let b = v.bounds
        var pr = RNG(s: 5)
        let title = NSTextField(labelWithString: "Account settings"); title.font = .boldSystemFont(ofSize: 18)
        title.frame = NSRect(x: 24, y: b.height - 48, width: 400, height: 26); v.addSubview(title)
        let labels = ["Name", "Email", "Host", "Port", "Device", "Region"]
        for (i, l) in labels.enumerated() {
            let y = b.height - 100 - CGFloat(i) * 40
            let lab = NSTextField(labelWithString: l + ":"); lab.alignment = .right; lab.frame = NSRect(x: 24, y: y, width: 90, height: 22); v.addSubview(lab)
            let f = NSTextField(string: words[pr.int(0, words.count - 1)] + "." + words[pr.int(0, words.count - 1)]); f.frame = NSRect(x: 124, y: y, width: 260, height: 24); v.addSubview(f)
        }
        for i in 0..<4 {
            let c = NSButton(checkboxWithTitle: "Enable " + words[pr.int(0, words.count - 1)] + " " + words[pr.int(0, words.count - 1)], target: nil, action: nil)
            c.state = i % 2 == 0 ? .on : .off
            c.frame = NSRect(x: 430, y: b.height - 100 - CGFloat(i) * 32, width: 300, height: 22); v.addSubview(c)
        }
        let p = NSProgressIndicator(frame: NSRect(x: 430, y: b.height - 270, width: 32, height: 32))
        p.style = .spinning; p.controlSize = .regular; p.isIndeterminate = true
        v.addSubview(p); p.startAnimation(nil); markMedia(p, in: window)
        let s = NSTextField(labelWithString: "Syncing with server…"); s.frame = NSRect(x: 472, y: b.height - 264, width: 200, height: 20); v.addSubview(s)
        let f = NSTextField(wrappingLabelWithString: paragraph(&pr, sentences: 6)); f.font = bodyFont
        f.frame = NSRect(x: 24, y: 20, width: b.width - 48, height: 120); v.addSubview(f)
    }
    func tick(_ t: Double) {}
}

/// A small animation drawn every tick: flat vector shapes (`rich` false) or gradients and soft shadows (true).
final class AnimView: NSView {
    var t = 0.0
    var rich = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let cx = b.midX, cy = b.midY
        let ctx = NSGraphicsContext.current!.cgContext
        if rich {
            let g = NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.12, blue: 0.30, alpha: 1), NSColor(srgbRed: 0.45, green: 0.15, blue: 0.40, alpha: 1)])!
            g.draw(in: b, angle: CGFloat(t * 40).truncatingRemainder(dividingBy: 360))
        } else {
            NSColor(srgbRed: 0.96, green: 0.96, blue: 0.98, alpha: 1).setFill(); b.fill()
        }
        let colors: [NSColor] = [.systemBlue, .systemPink, .systemOrange, .systemGreen, .systemPurple]
        for i in 0..<5 {
            let a = t * 1.6 + Double(i) * 2 * .pi / 5
            let rad = b.width * 0.30
            let x = cx + CGFloat(cos(a)) * rad, y = cy + CGFloat(sin(a)) * rad
            let s = b.width * 0.16
            ctx.saveGState()
            ctx.translateBy(x: x, y: y); ctx.rotate(by: CGFloat(a * 1.5))
            let r = NSRect(x: -s / 2, y: -s / 2, width: s, height: s)
            let path = NSBezierPath(roundedRect: r, xRadius: s * 0.25, yRadius: s * 0.25)
            if rich {
                ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 10, color: NSColor.black.withAlphaComponent(0.5).cgColor)
                NSGradient(colors: [colors[i].highlight(withLevel: 0.5)!, colors[i].shadow(withLevel: 0.4)!])!.draw(in: path, angle: 60)
            } else { colors[i].setFill(); path.fill() }
            ctx.restoreGState()
        }
        let pulse = 0.5 + 0.5 * sin(t * 3)
        let d = b.width * CGFloat(0.12 + 0.06 * pulse)
        let c = NSBezierPath(ovalIn: NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
        if rich { NSGradient(colors: [.white, .systemTeal])!.draw(in: c, relativeCenterPosition: NSPoint(x: -0.3, y: -0.3)) }
        else { NSColor.systemTeal.setFill(); c.fill() }
    }
}

final class AnimDriver: Driver {
    let view = AnimView()
    init(window: NSWindow, rich: Bool, size: CGFloat = 240, page: Bool = true) {
        let v = window.contentView!
        let b = v.bounds
        view.rich = rich
        view.frame = NSRect(x: b.width - size - 24, y: b.height - size - 60, width: size, height: size)
        if page { staticPage(v, title: rich ? "Shaded animation" : "Flat animation", seed: 9, avoiding: view.frame) }
        v.addSubview(view); markMedia(view, in: window)
    }
    func tick(_ t: Double) { view.t = t; view.needsDisplay = true }
}

final class VideoDriver: Driver {
    let player: AVPlayer
    init(window: NSWindow, clip: URL) {
        let v = window.contentView!
        let b = v.bounds
        player = AVPlayer(url: clip)
        player.isMuted = true
        let pv = NSView(frame: NSRect(x: (b.width - 640) / 2, y: b.height - 360 - 56, width: 640, height: 360))
        pv.wantsLayer = true
        let pl = AVPlayerLayer(player: player)
        pl.frame = pv.bounds; pl.videoGravity = .resizeAspect
        pv.layer!.addSublayer(pl)
        staticPage(v, title: "Clip: a generated test sequence", seed: 13, avoiding: pv.frame)
        v.addSubview(pv); markMedia(pv, in: window)
    }
    var started = false
    func tick(_ t: Double) { if !started { started = true; player.play() } }
}

// MARK: Main

let args = CommandLine.arguments
guard args.count >= 4, let seconds = Double(args[2]) else {
    print("usage: bytrec <typing|terminal|scroll|spinner|anim|anim-rich|video|mixed> <seconds> <outdir> [--clip file]"); exit(2)
}
let scene = args[1]
let outDir = URL(fileURLWithPath: args[3]).appendingPathComponent(scene)
let clip = args.firstIndex(of: "--clip").map { URL(fileURLWithPath: args[$0 + 1]) }
precondition(seconds <= 60, "sequences are at most 60 s")
try? FileManager.default.removeItem(at: outDir)
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let screen = NSScreen.main!.visibleFrame
var windows: [(name: String, window: NSWindow)] = []
var drivers: [Driver] = []
func place(_ w: CGFloat, _ h: CGFloat, slot: Int = 0) -> NSRect {
    // Bottom-right of the screen, side by side for the mixed scene.
    NSRect(x: screen.maxX - (w + 12) * CGFloat(slot + 1), y: screen.minY + 12, width: w, height: h)
}
switch scene {
case "typing":
    let w = makeWindow("Notes", place(800, 560)); drivers.append(TypingDriver(window: w)); windows.append(("editor", w))
case "terminal":
    let w = makeWindow("zsh — swift build", place(800, 560)); drivers.append(TerminalDriver(window: w)); windows.append(("terminal", w))
case "scroll":
    let w = makeWindow("Document", place(800, 560)); drivers.append(ScrollDriver(window: w)); windows.append(("document", w))
case "spinner":
    let w = makeWindow("Settings", place(800, 560)); drivers.append(SpinnerDriver(window: w)); windows.append(("settings", w))
case "anim", "anim-rich":
    let w = makeWindow("Page", place(800, 560)); drivers.append(AnimDriver(window: w, rich: scene == "anim-rich")); windows.append(("page", w))
case "video":
    guard let clip else { print("video needs --clip"); exit(2) }
    let w = makeWindow("Player", place(800, 560)); drivers.append(VideoDriver(window: w, clip: clip)); windows.append(("player", w))
case "mixed":
    let a = makeWindow("Notes", place(520, 380, slot: 0)); drivers.append(TypingDriver(window: a, seed: 99)); windows.append(("editor", a))
    let b = makeWindow("zsh", place(520, 380, slot: 1)); drivers.append(TerminalDriver(window: b, seed: 17)); windows.append(("terminal", b))
    let c = makeWindow("Status", place(420, 380, slot: 2))
    drivers.append(AnimDriver(window: c, rich: false, size: 150))
    let p = NSProgressIndicator(frame: NSRect(x: 24, y: 300, width: 32, height: 32)); p.style = .spinning; p.isIndeterminate = true
    c.contentView!.addSubview(p); p.startAnimation(nil); markMedia(p, in: c)
    windows.append(("status", c))
default:
    print("unknown scene \(scene)"); exit(2)
}
for (_, w) in windows { w.orderFrontRegardless() }

var captures: [Capture] = []
var t0Nanos: UInt64 = 0

func log(_ s: String) { print(s); fflush(stdout) }

@MainActor func start() async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    t0Nanos = UInt64(CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1e9)
    for (name, w) in windows {
        guard let scw = content.windows.first(where: { $0.windowID == CGWindowID(w.windowNumber) }) else { throw NSError(domain: "bytrec", code: 1, userInfo: [NSLocalizedDescriptionKey: "window \(name) not shareable"]) }
        let scale = w.backingScaleFactor
        let cfg = SCStreamConfiguration()
        cfg.width = Int(w.frame.width * scale); cfg.height = Int(w.frame.height * scale)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.queueDepth = 8
        let cap = Capture(writer: FrameWriter(url: outDir.appendingPathComponent("\(name).frames"), t0: t0Nanos))
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: scw), configuration: cfg, delegate: cap)
        try s.addStreamOutput(cap, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap.\(name)"))
        try await s.startCapture()
        cap.stream = s
        captures.append(cap)
        log("capturing \(name): \(cfg.width)x\(cfg.height) @\(scale)x")
    }
}

@MainActor func stop() async {
    for c in captures { try? await c.stream?.stopCapture() }
    var meta: [String: Any] = ["scene": scene, "seconds": seconds, "recorded": ISO8601DateFormatter().string(from: Date())]
    var layers: [[String: Any]] = []
    for (i, c) in captures.enumerated() {
        let (n, bytes) = c.writer.finish()
        let w = windows[i].window
        layers.append(["media": (mediaViews[ObjectIdentifier(w)] ?? []).map { pixelRect($0, w) }, "name": windows[i].name, "frames": n, "fileBytes": bytes, "idleCallbacks": c.idle, "width": c.writer.w, "height": c.writer.h])
        log("\(windows[i].name): \(n) frames, \(bytes / 1024) KB on disk (\(c.idle) idle callbacks)")
    }
    meta["layers"] = layers
    let d = try! JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
    try! d.write(to: outDir.appendingPathComponent("meta.json"))
}

var startT = 0.0
DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
    Task { @MainActor in
        do { try await start() } catch { log("capture failed: \(error)"); for (_, w) in windows { w.close() }; exit(1) }
        startT = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { tm in
            let t = CACurrentMediaTime() - startT
            for d in drivers { d.tick(t) }
            if t >= seconds {
                tm.invalidate()
                Task { @MainActor in await stop(); for (_, w) in windows { w.close() }; exit(0) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
// Hard stop no matter what.
DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 20) { log("watchdog: exiting"); exit(3) }
app.run()
