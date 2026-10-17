// boxcache: does alignment-free reuse of "content boxes" (text lines / UI runs found by
// background projection) beat grid-tile hashing for scroll and typing? Renders real AppKit
// (NSTextView) and WebKit text at successive scroll offsets and keystrokes, 2x Retina, then
// measures how much of each frame's change is covered by copy-rect, by exact box matches
// from history, by grid-tile hash hits (control), and what residual still needs encoding.
import AppKit
import WebKit
import CryptoKit

let W = 1200, H = 800, SCALE = 2   // points; pixels are 2x
let PW = W * SCALE, PH = H * SCALE
let TILE = 64

struct Frame { let px: [UInt8] }   // RGBA8, PW*PH
func pixels(of image: NSImage) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: PW * PH * 4)
    let ctx = CGContext(data: &buf, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let g = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
    image.draw(in: CGRect(x: 0, y: 0, width: PW, height: PH), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return buf
}
func snapshot(_ view: NSView) -> [UInt8] {
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    let img = NSImage(size: view.bounds.size); img.addRepresentation(rep)
    return pixels(of: img)
}

// Text corpus: realistic mixed prose + code.
let prose = (1...400).map { "\($0). The quick brown fox jumps over the lazy dog while func encode(tile: Tile) -> Data { return webp(tile, lossless: true) } // paragraph \($0) of a scrolling column with mixed text, numbers 0123456789 and code." }.joined(separator: "\n\n")

// MARK: AppKit sequences
func appKitSequences() -> (scroll: [[UInt8]], typing: [[UInt8]]) {
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H), styleMask: [.titled], backing: .buffered, defer: false)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: W, height: H))
    let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: W, height: H))
    tv.isRichText = false; tv.font = NSFont.systemFont(ofSize: 13); tv.string = prose
    tv.minSize = NSSize(width: 0, height: H); tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    tv.isVerticallyResizable = true; tv.textContainer?.widthTracksTextView = true
    scroll.documentView = tv; scroll.hasVerticalScroller = false
    win.contentView = scroll
    win.setFrame(win.frame, display: true)
    scroll.layoutSubtreeIfNeeded(); tv.layoutManager?.ensureLayout(for: tv.textContainer!)
    var frames: [[UInt8]] = []
    for step in 0..<20 {   // 20 frames of 37 pt/frame scrolling (not a line multiple on purpose)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 37))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.layoutSubtreeIfNeeded()
        frames.append(snapshot(scroll))
    }
    // typing: append characters at the end of a visible line
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
    var typing: [[UInt8]] = []
    let typed = "Hello from Japan, this is being typed one character at a time."
    tv.setSelectedRange(NSRange(location: 60, length: 0))
    typing.append(snapshot(scroll))
    for ch in typed {
        tv.insertText(String(ch), replacementRange: tv.selectedRange())
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        typing.append(snapshot(scroll))
    }
    return (frames, typing)
}

// MARK: WebKit sequence (real browser text rendering, scrolled by JS)
func webKitScroll(done: @escaping ([[UInt8]]) -> Void) {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: W, height: H))
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H), styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView = web
    win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()   // must be "on screen" for WebKit to render
    let html = "<html><body style='font: 15px -apple-system; margin:24px; line-height:1.5'>" + prose.split(separator: "\n\n").map { "<p>\($0)</p>" }.joined() + "</body></html>"
    var frames: [[UInt8]] = []
    var step = 0
    func next() {
        if step == 20 { done(frames); return }
        web.evaluateJavaScript("window.scrollTo(0, \(step * 37));") { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                web.takeSnapshot(with: nil) { img, _ in
                    if let img { frames.append(pixels(of: img)) }
                    step += 1; next()
                }
            }
        }
    }
    web.navigationDelegate = NavDelegate { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } }
    web.loadHTMLString(html, baseURL: nil)
    _ = win
    webHold = web
}
var webHold: WKWebView?
final class NavDelegate: NSObject, WKNavigationDelegate {
    let onLoad: () -> Void
    init(_ f: @escaping () -> Void) { onLoad = f }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoad() }
}

// MARK: Analysis
struct Box: Hashable { var x: Int, y: Int, w: Int, h: Int }
func changedMask(_ a: [UInt8], _ b: [UInt8]) -> [Bool] {
    var m = [Bool](repeating: false, count: PW * PH)
    a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in
        for i in 0..<(PW * PH) { let j = i * 4; if pa[j] != pb[j] || pa[j+1] != pb[j+1] || pa[j+2] != pb[j+2] { m[i] = true } } } }
    return m
}
/// Content boxes: within the changed region, split on rows that are entirely "background"
/// (equal to the frame's dominant colour), then within each band split on background columns
/// wider than `gap`. Boxes are the bounding rects of the remaining runs.
func contentBoxes(_ px: [UInt8], region: Box, bg: (UInt8, UInt8, UInt8), gap: Int = 6) -> [Box] {
    func isBG(_ x: Int, _ y: Int) -> Bool { let i = (y * PW + x) * 4; return px[i] == bg.0 && px[i+1] == bg.1 && px[i+2] == bg.2 }
    var boxes: [Box] = []
    var y = region.y
    while y < region.y + region.h {
        // skip background rows
        while y < region.y + region.h && (region.x..<(region.x + region.w)).allSatisfy({ isBG($0, y) }) { y += 1 }
        if y >= region.y + region.h { break }
        var y2 = y
        while y2 < region.y + region.h && !(region.x..<(region.x + region.w)).allSatisfy({ isBG($0, y2) }) { y2 += 1 }
        // band y..<y2: split by background columns
        var x = region.x
        while x < region.x + region.w {
            while x < region.x + region.w && (y..<y2).allSatisfy({ isBG(x, $0) }) { x += 1 }
            if x >= region.x + region.w { break }
            var x2 = x, run = 0
            while x2 < region.x + region.w {
                if (y..<y2).allSatisfy({ isBG(x2, $0) }) { run += 1; if run >= gap { break } } else { run = 0 }
                x2 += 1
            }
            let xe = x2 - run
            boxes.append(Box(x: x, y: y, w: xe - x, h: y2 - y))
            x = x2
        }
        y = y2
    }
    return boxes
}
func hash(_ px: [UInt8], _ b: Box) -> Data {
    var h = SHA256()
    for yy in b.y..<(b.y + b.h) { px.withUnsafeBufferPointer { p in h.update(bufferPointer: UnsafeRawBufferPointer(start: p.baseAddress! + (yy * PW + b.x) * 4, count: b.w * 4)) } }
    return Data(h.finalize())
}
func dominant(_ px: [UInt8]) -> (UInt8, UInt8, UInt8) {
    var counts = [UInt32: Int]()
    var i = 0; while i < PW * PH * 4 { counts[UInt32(px[i]) << 16 | UInt32(px[i+1]) << 8 | UInt32(px[i+2]), default: 0] += 1; i += 4 * 37 }
    let k = counts.max { $0.value < $1.value }!.key
    return (UInt8(k >> 16), UInt8((k >> 8) & 255), UInt8(k & 255))
}
/// Best vertical copy-rect: the dy in [-300, 300] that explains the most changed pixels.
func bestCopyShift(_ prev: [UInt8], _ cur: [UInt8], mask: [Bool]) -> (dy: Int, covered: Int) {
    var best = (0, 0)
    let sample = stride(from: 0, to: PW * PH, by: 7).filter { mask[$0] }   // subsample changed pixels
    guard !sample.isEmpty else { return best }
    for dy in -300...300 where dy != 0 {
        var ok = 0
        for i in sample { let y = i / PW, x = i % PW; let sy = y + dy; if sy >= 0 && sy < PH { let a = (sy * PW + x) * 4, b = i * 4; if prev[a] == cur[b] && prev[a+1] == cur[b+1] && prev[a+2] == cur[b+2] { ok += 1 } } }
        if ok > best.1 { best = (dy, ok) }
    }
    return (best.0, best.1 * 7)
}

func analyze(_ name: String, _ frames: [[UInt8]]) {
    guard frames.count > 1 else { print("\(name): no frames"); return }
    let bg = dominant(frames[0])
    var boxCache = Set<Data>(), tileCache = Set<Data>()
    var boxPixels: [Int: [[UInt8]]] = [:]   // (w<<16|h) -> stored boxes, for tolerant matching
    func boxBytes(_ px: [UInt8], _ b: Box) -> [UInt8] { var o = [UInt8](); o.reserveCapacity(b.w * b.h * 3); for yy in b.y..<(b.y + b.h) { for xx in b.x..<(b.x + b.w) { let i = (yy * PW + xx) * 4; o.append(px[i]); o.append(px[i+1]); o.append(px[i+2]) } }; return o }
    /// Near match: ≥ 97 % of pixels identical and no channel differs by more than 64 (subpixel AA / gamma wobble).
    func nearMatch(_ a: [UInt8], _ b: [UInt8]) -> Bool { var same = 0; var i = 0; while i < a.count { let d = abs(Int(a[i]) - Int(b[i])); if d > 64 { return false }; if d == 0 { same += 1 }; i += 1 }; return Double(same) / Double(a.count) >= 0.97 }
    var totNear = 0
    // seed caches with frame 0
    let full = Box(x: 0, y: 0, w: PW, h: PH)
    for b in contentBoxes(frames[0], region: full, bg: bg) { boxCache.insert(hash(frames[0], b)); boxPixels[b.w << 16 | b.h, default: []].append(boxBytes(frames[0], b)) }
    for ty in 0..<(PH / TILE) { for tx in 0..<(PW / TILE) { tileCache.insert(hash(frames[0], Box(x: tx * TILE, y: ty * TILE, w: TILE, h: TILE))) } }
    var totChanged = 0, totCopy = 0, totBoxHit = 0, totBoxMiss = 0, totTileHit = 0, totTileDirty = 0, totBoxes = 0, totRefs = 0
    for f in 1..<frames.count {
        let prev = frames[f-1], cur = frames[f]
        let mask = changedMask(prev, cur)
        let changed = mask.lazy.filter { $0 }.count
        if changed == 0 { continue }
        totChanged += changed
        // copy-rect coverage (vertical shifts; scroll/typing-line shifts)
        let (dy, covered) = bestCopyShift(prev, cur, mask: mask)
        totCopy += min(covered, changed)
        // residual region after copy: bounding box of changed pixels not explained by the shift
        var minX = PW, minY = PH, maxX = -1, maxY = -1
        for i in 0..<(PW * PH) where mask[i] {
            let y = i / PW, x = i % PW; let sy = y + dy
            var explained = false
            if dy != 0 && sy >= 0 && sy < PH { let a = (sy * PW + x) * 4, b = i * 4; explained = prev[a] == cur[b] && prev[a+1] == cur[b+1] && prev[a+2] == cur[b+2] }
            if !explained { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        }
        // content boxes in the residual region, matched against history
        if maxX >= 0 {
            let region = Box(x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1)
            let boxes = contentBoxes(cur, region: region, bg: bg)
            totBoxes += boxes.count
            for b in boxes {
                let hsh = hash(cur, b); let area = b.w * b.h
                if boxCache.contains(hsh) { totBoxHit += area; totRefs += 1 }
                else {
                    let bytes = boxBytes(cur, b)
                    if let cands = boxPixels[b.w << 16 | b.h], cands.contains(where: { nearMatch($0, bytes) }) { totNear += area; totRefs += 1 }
                    else { totBoxMiss += area }
                    boxCache.insert(hsh); boxPixels[b.w << 16 | b.h, default: []].append(bytes)
                }
            }
            // grid-tile control over the same residual
            var ty = region.y / TILE
            while ty * TILE < region.y + region.h { var tx = region.x / TILE
                while tx * TILE < region.x + region.w {
                    let t = Box(x: tx * TILE, y: ty * TILE, w: TILE, h: TILE)
                    if t.x + TILE <= PW && t.y + TILE <= PH { let hsh = hash(cur, t); totTileDirty += TILE * TILE; if tileCache.contains(hsh) { totTileHit += TILE * TILE } else { tileCache.insert(hsh) } }
                    tx += 1 }
                ty += 1 }
        }
    }
    let f = Double(frames.count - 1)
    func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : String(format: "%.0f%%", Double(a) / Double(b) * 100) }
    print("\n== \(name): \(frames.count) frames, \(Int(Double(totChanged) / f)) changed px/frame (\(pct(Int(Double(totChanged) / f), PW * PH)) of frame)")
    print("   copy-rect explains \(pct(totCopy, totChanged)) of changed pixels")
    let resid = totBoxHit + totNear + totBoxMiss
    print("   residual content boxes: \(Int(Double(totBoxes) / f))/frame, area \(Int(Double(resid) / f)) px/frame; exact hits \(pct(totBoxHit, resid)), tolerant hits +\(pct(totNear, resid)), true misses \(pct(totBoxMiss, resid)) (\(Int(Double(totRefs) / f)) refs/frame)")
    print("   grid 64px control over the same residual: tile-hash hits cover \(pct(totTileHit, totTileDirty)) of dirty tile area")
    print("   bytes to encode per frame if boxes: miss area \(Int(Double(totBoxMiss) / f)) px ≈ \(String(format: "%.2f", Double(totBoxMiss) / f * 0.13 / 1024)) KB WebP-ll (0.13 B/px text rate); refs \(Int(Double(totRefs) / f)) × 12 B")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let ak = appKitSequences()
analyze("AppKit NSTextView scroll 37pt/frame", ak.scroll)
analyze("AppKit NSTextView typing", ak.typing)
if ProcessInfo.processInfo.environment["SKIP_WEBKIT"] != nil { exit(0) }
webKitScroll { frames in
    analyze("WebKit scroll 37px/frame", frames)
    exit(0)
}
RunLoop.main.run(until: Date().addingTimeInterval(150))
print("webkit timeout"); exit(1)
