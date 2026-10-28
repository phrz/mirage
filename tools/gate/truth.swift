import Foundation
import CoreGraphics
import ImageIO
// Truth metric (numbers only): every viewer frame (frames.jsonl wall time) against the host's own screenshots ("truth
// reference" log lines: ISO time + 576 hex cell means), the best match among host shots from 600 ms before to 100 ms after
// the frame. A frame is partial when more than `tol` (default 1 %) of its 32×18 cells differ by over 15 levels from it.
// Usage: truth <frames dir> <refs file: "ISO hex" lines> [start wall]
let dir = CommandLine.arguments[1], refsPath = CommandLine.arguments[2]
let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
var refs: [(Double, [Double])] = []
for line in try String(contentsOfFile: refsPath, encoding: .utf8).split(separator: "\n") {
    let p = line.split(separator: " "); guard p.count == 2, let d = iso.date(from: String(p[0])) else { continue }
    let h = Array(p[1]); var m: [Double] = []; var i = 0
    while i + 1 < h.count { m.append(Double(Int(String(h[i...i + 1]), radix: 16) ?? 0)); i += 2 }
    if m.count == 576 { refs.append((d.timeIntervalSince1970, m)) }
}
struct L: Decodable { var i: Int; var wall: Double }
let lines = try String(contentsOfFile: dir + "/frames.jsonl", encoding: .utf8).split(separator: "\n").compactMap { try? JSONDecoder().decode(L.self, from: Data($0.utf8)) }
let start = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3])! : (lines.first?.wall ?? 0)
var partial = 0, total = 0, firstWhole: Double? = nil
var report: [String] = []
var perFrame: [(Double, Set<Int>)] = []
for l in lines {
    let url = URL(fileURLWithPath: dir + String(format: "/frame-%04d.png", l.i))
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let cw = w / 32, ch = h / 18
    var cells = [Double](repeating: 0, count: 576)
    for cy in 0..<18 { for cx in 0..<32 {
        var s = 0.0, n = 0.0
        for y in stride(from: cy * ch, to: (cy + 1) * ch, by: 2) { for x in stride(from: cx * cw, to: (cx + 1) * cw, by: 2) {
            let o = (y * w + x) * 4; s += 0.299 * Double(px[o]) + 0.587 * Double(px[o + 1]) + 0.114 * Double(px[o + 2]); n += 1
        } }
        cells[cy * 32 + cx] = s / n
    } }
    let cand = refs.filter { $0.0 >= l.wall - 1.0 && $0.0 <= l.wall + 1.0 }
    guard !cand.isEmpty else { continue }
    let scored = cand.map { r in (zip(cells, r.1).filter { abs($0 - $1) > 15 }.count, r.1) }
    let best = scored.map(\.0).min()!
    if ProcessInfo.processInfo.environment["TRUTH_WHERE"] != nil, best > 5, let r = scored.first(where: { $0.0 == best })?.1 {
        var grid = ""
        for cy in 0..<18 { var row = ""; for cx in 0..<32 { let i = cy * 32 + cx; let d = cells[i] - r[i]; row += abs(d) > 15 ? (d > 0 ? "+" : "-") : "." }; grid += row + "\n" }
        print(String(format: "cells at %.2f s (+ viewer lighter, - darker):\n", l.wall - start) + grid); exit(0)
    }
    let bestRef = scored.first(where: { $0.0 == best })!.1
    perFrame.append((l.wall - start, Set((0..<576).filter { abs(cells[$0] - bestRef[$0]) > 15 })))
}
// Cells that differ in at least 70 % of frames: a steady-state mismatch (the compositor model's Dock glass, shadows), reported
// apart; a gap or a missing window is a cell that differs beyond those.
var count = [Int](repeating: 0, count: 576)
// (Also: the mean of cells wrong per frame beyond the steady ones, and the longest a region stayed wrong: the longest run of
// consecutive frames in which one cell differed, in seconds.)
for (_, d) in perFrame { for c in d { count[c] += 1 } }
let persistent = Set((0..<576).filter { perFrame.count > 3 && Double(count[$0]) >= 0.7 * Double(perFrame.count) })
for (t, d) in perFrame {
    total += 1
    let extra = d.subtracting(persistent).count
    if extra > 5 { partial += 1; if report.count < 12 { report.append(String(format: "  %.2f s: %d cells differ (beyond the steady ones)", t, extra)) } }
    else if firstWhole == nil { firstWhole = t }
}
var runStart = [Double?](repeating: nil, count: 576), longest = 0.0, longestCell = -1, wrongSum = 0
for (t, d) in perFrame {
    let extra = d.subtracting(persistent); wrongSum += extra.count
    for c in 0..<576 {
        if extra.contains(c) { if runStart[c] == nil { runStart[c] = t } ; if t - runStart[c]! > longest { longest = t - runStart[c]!; longestCell = c } }
        else { runStart[c] = nil }
    }
}
print("steady-state mismatch: \(persistent.count) cells differ in most frames")
print(String(format: "cells wrong per frame (beyond steady): mean %.1f; longest-wrong region: %.2f s (cell %d,%d)", perFrame.isEmpty ? 0 : Double(wrongSum) / Double(perFrame.count), longest, longestCell >= 0 ? longestCell % 32 : -1, longestCell >= 0 ? longestCell / 32 : -1))
print(String(format: "frames compared %d, partial %d (%.1f%%), first whole frame at %@ s", total, partial, total > 0 ? 100 * Double(partial) / Double(total) : 0, firstWhole.map { String(format: "%.2f", $0) } ?? "never"))
report.forEach { print($0) }
