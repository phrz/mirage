// Frame-sheet check for DESIGN §3.3 presentation steps. Reads a MIRAGE_TEST_FRAMES directory (frame-NNNN.png at
// 5 fps, frames.jsonl with layer rects) and reports, per layer (each window layer and the desktop around them), the
// visible change events: runs of consecutive frames in which any 16-px block (64 native px) of the layer changed.
// A level presented whole is one event of one or two frames (a 220 ms crossfade); blocks landing one by one show as
// a long event or many small ones. Also writes sheet.png, a contact sheet of the frames.
//   swift experiments/probes/framesheet.swift <dir> [--from ms] [--to ms]
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct L: Codable { var id: UInt32; var x: Int; var y: Int; var w: Int; var h: Int }
struct Line: Codable { var i: Int; var ms: Int; var clock: Int?; var width: Int; var height: Int; var layers: [L] }

let args = CommandLine.arguments
let dir = URL(fileURLWithPath: args[1])
func opt(_ k: String) -> Int? { args.firstIndex(of: k).flatMap { Int(args[$0 + 1]) } }
let from = opt("--from") ?? 0, to = opt("--to") ?? Int.max
let lines = try String(contentsOf: dir.appendingPathComponent("frames.jsonl"), encoding: .utf8).split(separator: "\n").compactMap { try? JSONDecoder().decode(Line.self, from: Data($0.utf8)) }.filter { $0.ms >= from && $0.ms <= to }

func load(_ i: Int) -> (Int, Int, [UInt8])? {
    let url = dir.appendingPathComponent(String(format: "frame-%04d.png", i))
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, px)
}

let B = 16
var frames: [(Line, [UInt8])] = []
for l in lines { if let (_, _, px) = load(l.i) { frames.append((l, px)) } }
guard let first = frames.first else { print("no frames"); exit(1) }
let W = first.0.width, H = first.0.height
let cols = (W + B - 1) / B, rows = (H + B - 1) / B

/// Owner of each block in a frame: the one layer whose rect contains the block, 0 (the desktop) if no layer touches
/// it, nil if it lies where layers overlap or on a layer edge (shadows, corners): only unambiguous blocks are counted.
func owners(_ l: Line) -> [UInt32?] {
    var o = [UInt32?](repeating: 0, count: cols * rows)
    for r in 0..<rows { for c in 0..<cols {
        let bx = c * B, by = r * B, bw = min(B, W - bx), bh = min(B, H - by)
        var inside: [UInt32] = [], touching = 0
        for ly in l.layers {
            if bx >= ly.x && by >= ly.y && bx + bw <= ly.x + ly.w && by + bh <= ly.y + ly.h { inside.append(ly.id) }
            if bx < ly.x + ly.w + 4 && bx + bw > ly.x - 4 && by < ly.y + ly.h + 4 && by + bh > ly.y - 4 { touching += 1 }
        }
        o[r * cols + c] = touching == 0 ? 0 : (inside.count == 1 && touching == 1 ? inside[0] : nil)
    } }
    return o
}
func changed(_ a: [UInt8], _ b: [UInt8], _ c: Int, _ r: Int) -> Bool {
    let x0 = c * B, y0 = r * B, x1 = min(W, x0 + B), y1 = min(H, y0 + B)
    var sum = 0
    for y in y0..<y1 { var o = (y * W + x0) * 4; for _ in x0..<x1 { sum += abs(Int(a[o]) - Int(b[o])) + abs(Int(a[o+1]) - Int(b[o+1])) + abs(Int(a[o+2]) - Int(b[o+2])); o += 4 } }
    return Double(sum) / Double((x1 - x0) * (y1 - y0) * 3) > 0.15
}

struct Event { var startMs: Int; var endMs: Int; var frames: Int; var blocks: Set<Int> }
var events: [UInt32: [Event]] = [:]
var total: [UInt32: Int] = [:]
var open: [UInt32: Event] = [:]
for k in 1..<frames.count {
    let (l, px) = frames[k], prev = frames[k - 1].1
    let own = owners(l), ownPrev = owners(frames[k - 1].0)
    var hit: [UInt32: Set<Int>] = [:]
    var count: [UInt32: Int] = [:]
    for i in 0..<(cols * rows) {
        guard let o = own[i], ownPrev[i] == o else { continue }
        count[o, default: 0] += 1
        if changed(px, prev, i % cols, i / cols) { hit[o, default: []].insert(i) }
    }
    for (o, n) in count { total[o] = max(total[o] ?? 0, n) }
    if let v = opt("--verbose").map(UInt32.init), let h = hit[v] { print("  \(l.ms) ms (clock \(l.clock ?? 0)) layer \(v): \(h.count) blocks changed: \(h.sorted().prefix(24).map { "\($0 % cols),\($0 / cols)" }.joined(separator: " "))") }
    for o in Set(hit.keys).union(open.keys) {
        if let h = hit[o] {
            if var e = open[o] { e.endMs = l.ms; e.frames += 1; e.blocks.formUnion(h); open[o] = e } else { open[o] = Event(startMs: l.ms, endMs: l.ms, frames: 1, blocks: h) }
        } else if let e = open[o] { events[o, default: []].append(e); open[o] = nil }
    }
}
for (o, e) in open { events[o, default: []].append(e) }

print("frames \(frames.count) at \(W)x\(H), \(first.0.ms)–\(frames.last!.0.ms) ms")
for o in events.keys.sorted() {
    let n = max(1, total[o] ?? 1)
    let list = events[o]!
    let large = list.filter { Double($0.blocks.count) / Double(n) >= 0.05 }
    print("layer \(o == 0 ? "desktop" : "\(o)") (\(n) blocks): \(list.count) change events, \(large.count) covering ≥5 % of the layer")
    for e in list {
        let pct = Double(e.blocks.count) * 100 / Double(n)
        print(String(format: "  %6d–%6d ms  %d frame%@  %5d blocks (%5.1f %%)%@", e.startMs, e.endMs, e.frames, e.frames == 1 ? " " : "s", e.blocks.count, pct, e.frames > 2 && pct >= 5 ? "  << spread over more than a crossfade" : ""))
    }
}

// Contact sheet: every frame at half the recorded size, 8 per row, with its time.
let tw = W / 2, th = H / 2, per = 8
let sheetRows = (frames.count + per - 1) / per
if let ctx = CGContext(data: nil, width: tw * per, height: (th + 14) * sheetRows, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    for (k, f) in frames.enumerated() {
        let url = dir.appendingPathComponent(String(format: "frame-%04d.png", f.0.i))
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
        let x = (k % per) * tw, y = ctx.height - (k / per + 1) * (th + 14)
        ctx.draw(img, in: CGRect(x: x, y: y, width: tw, height: th))
    }
    if let out = ctx.makeImage(), let d = CGImageDestinationCreateWithURL(dir.appendingPathComponent("sheet.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(d, out, nil); CGImageDestinationFinalize(d)
    }
}
