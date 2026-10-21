// connectcheck DIR [maxSeconds]: the M-FIVE connect acceptance metric over a frame-recorder run (MIRAGE_TEST_FRAMES=DIR,
// MIRAGE_TEST_FRAMES_MS=100). Regions: every layer rect of the last frame (frames.jsonl) and the desktop (what no layer
// covers). Per region, against the last frame (the settled, lossless picture):
//   coherent: first frame whose 8x8-block means are within 6 levels of the final's (recognisable, not yet crisp);
//   crisp:    first frame within 1.5 levels per pixel of the final, staying so;
//   changes:  appearance changes up to crisp, a run of consecutive frames moving > 2 levels counting once (a crossfade);
//   regress:  the region got further from the final by > 8 levels after being coherent (garbage, black, a wrong picture).
// Pass per region: changes <= 3, no regression; the targets are checked by the caller against coherent/crisp times.
import AppKit

struct Line: Decodable { var i: Int; var ms: Int; var width: Int; var height: Int; var layers: [L] }
struct L: Decodable { var id: UInt32; var x: Int; var y: Int; var w: Int; var h: Int }

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let maxMs = CommandLine.arguments.count > 2 ? Int(Double(CommandLine.arguments[2])! * 1000) : Int.max
let lines = (try! String(contentsOf: dir.appendingPathComponent("frames.jsonl"), encoding: .utf8)).split(separator: "\n").compactMap { try? JSONDecoder().decode(Line.self, from: Data($0.utf8)) }.filter { $0.ms <= maxMs }
guard let last = lines.last else { print("no frames"); exit(1) }
func load(_ i: Int) -> [UInt8]? {
    guard let im = NSImage(contentsOf: dir.appendingPathComponent(String(format: "frame-%04d.png", i))), let cg = im.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = last.width, h = last.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ok = px.withUnsafeMutableBytes { b -> Bool in
        guard let c = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
    }
    return ok ? px : nil
}
let W = last.width, H = last.height
struct Region { var name: String; var mask: [Bool] }
var regions: [Region] = []
var covered = [Bool](repeating: false, count: W * H)
for l in last.layers {
    var m = [Bool](repeating: false, count: W * H)
    for y in max(0, l.y)..<min(H, l.y + l.h) { for x in max(0, l.x)..<min(W, l.x + l.w) { m[y * W + x] = true; covered[y * W + x] = true } }
    if m.contains(true) { regions.append(Region(name: "layer \(l.id) \(l.x * 4),\(l.y * 4) \(l.w * 4)x\(l.h * 4)", mask: m)) }
}
regions.insert(Region(name: "desktop", mask: covered.map { !$0 }), at: 0)
// The menu bar and the Dock (the overlay's chrome, live: clocks, animated icons) are no window's and no desktop's: left out.
let topBand = 64 / 4, bottomBand = 176 / 4
for k in regions.indices { for y in 0..<H where y < topBand || y >= H - bottomBand { for x in 0..<W { regions[k].mask[y * W + x] = false } } }
guard let final = load(last.i) else { print("no final frame"); exit(1) }
// The final frame must be settled (the last 2 s steady), or "crisp" means nothing: run longer.
if lines.count > 21, let early = load(lines[lines.count - 21].i) {
    var s = 0, n = 0
    for p in stride(from: 0, to: W * H, by: 7) where regions.contains(where: { $0.mask[p] }) { let o = p * 4; s += abs(Int(early[o]) - Int(final[o])) + abs(Int(early[o+1]) - Int(final[o+1])) + abs(Int(early[o+2]) - Int(final[o+2])); n += 3 }
    let d = n > 0 ? Double(s) / Double(n) : 0
    if d > 0.5 { print(String(format: "final frame not settled (%.2f levels moved in its last 2 s): run longer", d)) }
}
func mad(_ a: [UInt8], _ b: [UInt8], _ m: [Bool]) -> Double {
    var s = 0, n = 0
    for p in stride(from: 0, to: W * H, by: 2) where m[p] { let o = p * 4; s += abs(Int(a[o]) - Int(b[o])) + abs(Int(a[o+1]) - Int(b[o+1])) + abs(Int(a[o+2]) - Int(b[o+2])); n += 3 }
    return n > 0 ? Double(s) / Double(n) : 0
}
func blockMad(_ a: [UInt8], _ b: [UInt8], _ m: [Bool]) -> Double {
    var s = 0.0, n = 0
    for by in stride(from: 0, to: H - 7, by: 8) { for bx in stride(from: 0, to: W - 7, by: 8) {
        guard m[(by + 4) * W + bx + 4] else { continue }
        var sa = 0, sb = 0
        for y in by..<by + 8 { for x in bx..<bx + 8 { let o = (y * W + x) * 4; sa += Int(a[o]) + Int(a[o+1]) + Int(a[o+2]); sb += Int(b[o]) + Int(b[o+1]) + Int(b[o+2]) } }
        s += abs(Double(sa - sb)) / 192; n += 1
    } }
    return n > 0 ? s / Double(n) : 0
}
struct R { var coherent: Int?; var crisp: Int?; var changes = 0; var inChange = false; var bestToFinal = Double.infinity; var regress = false }
// The first picture: the first frame where anything is drawn (the desktop region no longer the empty canvas), so times can
// be read from it as well as from the recorder's start (which includes connecting and signing in).
var firstPictureMs: Int? = nil
var res = [R](repeating: R(), count: regions.count)
var prev: [UInt8]? = nil
for line in lines {
    guard let f = load(line.i) else { continue }
    if firstPictureMs == nil, blockMad(f, final, regions[0].mask) < 40 { firstPictureMs = line.ms }
    for (k, r) in regions.enumerated() {
        let toFinal = mad(f, final, r.mask)
        if res[k].coherent == nil, blockMad(f, final, r.mask) < 6 { res[k].coherent = line.ms }
        if toFinal < 1.5 { if res[k].crisp == nil { res[k].crisp = line.ms } } else if res[k].crisp != nil, toFinal > 4 { res[k].crisp = nil }
        if res[k].coherent != nil, toFinal > res[k].bestToFinal + 8 { res[k].regress = true }
        res[k].bestToFinal = min(res[k].bestToFinal, toFinal)
        if let p = prev, res[k].crisp == nil || res[k].crisp == line.ms {
            let moving = mad(f, p, r.mask) > 2
            if moving, !res[k].inChange { res[k].changes += 1 }
            res[k].inChange = moving
        }
    }
    prev = f
}
var pass = true
func t(_ ms: Int?) -> String { ms.map { String(format: "%.1f s", Double($0) / 1000) } ?? "never" }
for (k, reg) in regions.enumerated() { let r = res[k]
    let ok = r.changes <= 3 && !r.regress && r.crisp != nil
    if !ok { pass = false }
    print("\(reg.name): coherent \(t(res[k].coherent)), crisp \(t(res[k].crisp)), changes \(res[k].changes)\(res[k].regress ? ", REGRESSED" : "") \(ok ? "ok" : "FAIL")")
}
// The overall times leave out regions under 1 % of the frame (a window almost entirely covered), still listed above.
let big = regions.indices.filter { k in regions[k].mask.filter { $0 }.count * 100 >= W * H }
let coh = big.compactMap { res[$0].coherent }.max(), crisp = big.allSatisfy({ res[$0].crisp != nil }) ? big.compactMap { res[$0].crisp }.max() : nil
func rel(_ ms: Int?) -> String { guard let ms, let f = firstPictureMs else { return "?" }; return String(format: "%.1f s", Double(ms - f) / 1000) }
print("ALL: coherent \(t(coh)), crisp \(t(crisp)) (from the first picture at \(t(firstPictureMs)): coherent \(rel(coh)), crisp \(rel(crisp))) over \(lines.count) frames; \(pass ? "PASS (flicker)" : "FAIL (flicker)")")
