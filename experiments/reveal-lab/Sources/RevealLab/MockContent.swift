import AppKit
import UniformTypeIdentifiers

/// The five mock "remote" contents. Each is drawn once into a bitmap that is the host's full truth.
enum MockTab: String, CaseIterable, Identifiable {
    case finder, text, photos, web, terminal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .finder: return "Finder"
        case .text: return "Text"
        case .photos: return "Photos"
        case .web: return "Web"
        case .terminal: return "Terminal"
        }
    }
    /// Colour shown past the document's ends (rubber-band overscroll).
    var background: NSColor {
        switch self {
        case .finder: return NSColor(white: 1, alpha: 1)
        case .text: return NSColor(white: 0.93, alpha: 1)
        case .photos: return NSColor(white: 0.11, alpha: 1)
        case .web: return NSColor(white: 0.97, alpha: 1)
        case .terminal: return NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1)
        }
    }
}

enum ContentGeometry {
    static let widthPt: CGFloat = 900
    static let heightPt: CGFloat = 6000
    static let scale: CGFloat = 2
    static var widthPx: Int { Int(widthPt * scale) }
    static var heightPx: Int { Int(heightPt * scale) }
}

/// Small deterministic RNG so every run draws the same content.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(Double(next() >> 11) / Double(1 << 53)) }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
    mutating func pick<T>(_ xs: [T]) -> T { xs[Int(next() % UInt64(xs.count))] }
}

private let words = ("the of and a to in is was for on that with as by at from it an be this which or are have " +
    "remote desktop frame tile pixel link latency scroll window viewer host packet bandwidth estimate glass " +
    "blur colour edge region delivered truth prediction motion surface layer texture budget quiet river " +
    "mountain harbour lantern orchard meadow signal careful gentle measured steady narrow broad early later " +
    "every between through before after under above across around without within toward beyond").split(separator: " ").map(String.init)

private func sentence(_ rng: inout SeededRNG, _ n: Int? = nil) -> String {
    let count = n ?? Int(rng.range(7, 19))
    var s = (0..<count).map { _ in rng.pick(words) }.joined(separator: " ")
    s = s.prefix(1).uppercased() + s.dropFirst()
    return s + rng.pick([".", ".", ".", ",", ";"]).replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: ";", with: ".")
}

private func paragraph(_ rng: inout SeededRNG, sentences: Int) -> String {
    (0..<sentences).map { _ in sentence(&rng) }.joined(separator: " ")
}

enum MockRenderer {
    /// Draws `tab` into a BGRA premultiplied bitmap (top row first). Returns the raw bytes and bytes-per-row.
    static func render(_ tab: MockTab) -> (data: Data, bytesPerRow: Int) {
        let w = ContentGeometry.widthPx, h = ContentGeometry.heightPx
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: info)!
        // Top-left origin in points.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: ContentGeometry.scale, y: -ContentGeometry.scale)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        tab.background.setFill()
        NSRect(x: 0, y: 0, width: ContentGeometry.widthPt, height: ContentGeometry.heightPt).fill()
        switch tab {
        case .finder: drawFinder(ctx)
        case .text: drawText(ctx)
        case .photos: drawPhotos(ctx)
        case .web: drawWeb(ctx)
        case .terminal: drawTerminal(ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
        let bpr = ctx.bytesPerRow
        let data = Data(bytes: ctx.data!, count: bpr * h)
        return (data, bpr)
    }

    // MARK: Finder

    private static func drawFinder(_ ctx: CGContext) {
        var rng = SeededRNG(1)
        let W = ContentGeometry.widthPt, H = ContentGeometry.heightPt
        let side: CGFloat = 190
        NSColor(red: 0.925, green: 0.925, blue: 0.935, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: side, height: H).fill()
        NSColor(white: 0.82, alpha: 1).setFill()
        NSRect(x: side - 1, y: 0, width: 1, height: H).fill()

        let headAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(white: 0.55, alpha: 1)]
        let itemAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.15, alpha: 1)]
        let sections: [(String, [(String, String)])] = [
            ("Favorites", [("AirDrop", "dot.radiowaves.left.and.right"), ("Recents", "clock"), ("Applications", "square.grid.2x2"),
                           ("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"), ("Downloads", "arrow.down.circle")]),
            ("iCloud", [("iCloud Drive", "icloud"), ("Shared", "folder.badge.person.crop")]),
            ("Locations", [("Macintosh HD", "internaldrive"), ("Network", "network")]),
            ("Tags", [("Red", "circle.fill"), ("Orange", "circle.fill"), ("Green", "circle.fill"), ("Blue", "circle.fill"), ("Purple", "circle.fill")]),
        ]
        let tagColors: [String: NSColor] = ["Red": .systemRed, "Orange": .systemOrange, "Green": .systemGreen, "Blue": .systemBlue, "Purple": .systemPurple]
        // The sidebar repeats every ~1500 pt so it is visible wherever one scrolls.
        var block: CGFloat = 0
        while block < H {
            var y: CGFloat = block + 16
            for (title, items) in sections {
                (title as NSString).draw(at: NSPoint(x: 14, y: y), withAttributes: headAttrs)
                y += 22
                for (name, sym) in items {
                    if name == "Documents" && block == 0 {
                        NSColor(white: 0.84, alpha: 1).setFill()
                        NSBezierPath(roundedRect: NSRect(x: 8, y: y - 3, width: side - 16, height: 24), xRadius: 6, yRadius: 6).fill()
                    }
                    if let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil) {
                        let tint = tagColors[name] ?? NSColor.systemBlue
                        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular).applying(.init(paletteColors: [tint]))
                        let im = img.withSymbolConfiguration(cfg) ?? img
                        let s = im.size
                        let sc = min(16 / s.width, 16 / s.height, 1.4)
                        im.draw(in: NSRect(x: 18, y: y + 9 - s.height * sc / 2, width: s.width * sc, height: s.height * sc), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    }
                    (name as NSString).draw(at: NSPoint(x: 42, y: y), withAttributes: itemAttrs)
                    y += 26
                }
                y += 10
            }
            block += 1500
        }

        let types: [(UTType, [String])] = [
            (.folder, ["Projects", "Archive", "Invoices", "Screenshots", "Drafts", "Assets", "Exports", "Backups", "Music", "Scans", "Reference", "Old Stuff"]),
            (.pdf, ["Report", "Manual", "Receipt", "Brochure", "Specification", "Agenda"]),
            (.png, ["Mockup", "Diagram", "Icon Set", "Wallpaper", "Sketch"]),
            (.jpeg, ["Holiday", "Sunset", "Harbour", "Orchard", "Portrait"]),
            (.plainText, ["Notes", "Todo", "Readme", "Changelog"]),
            (.swiftSource, ["Renderer", "Session", "Compositor", "Tunables"]),
            (.zip, ["Bundle", "Release", "Logs"]),
            (.mpeg4Movie, ["Screen Recording", "Clip", "Timelapse"]),
            (.mp3, ["Voice Memo", "Track"]),
            (.json, ["Config", "Fixture"]),
            (.applicationBundle, ["Utility", "Viewer"]),
        ]
        var icons: [UTType: NSImage] = [:]
        for (t, _) in types { icons[t] = NSWorkspace.shared.icon(for: t) }
        let labelAttrs: [NSAttributedString.Key: Any] = {
            let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byWordWrapping
            return [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.12, alpha: 1), .paragraphStyle: p]
        }()
        let groupAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor(white: 0.2, alpha: 1)]
        let cols = 6
        let cellW = (W - side - 20) / CGFloat(cols), cellH: CGFloat = 118
        var y: CGFloat = 14
        var i = 0
        let groups = ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "September", "August", "Earlier"]
        var g = 0
        while y < H - cellH {
            if i % 36 == 0 {
                (groups[g % groups.count] as NSString).draw(at: NSPoint(x: side + 20, y: y + 4), withAttributes: groupAttrs)
                NSColor(white: 0.88, alpha: 1).setFill()
                NSRect(x: side + 20, y: y + 26, width: W - side - 40, height: 1).fill()
                y += 36; g += 1
            }
            for c in 0..<cols {
                let (t, names) = rng.pick(types)
                var name = rng.pick(names)
                if rng.unit() < 0.4 { name += " \(Int(rng.range(2, 40)))" }
                if let ext = t.preferredFilenameExtension, t != .folder, t != .applicationBundle { name += "." + ext }
                if t == .applicationBundle { name += "" }
                let x = side + 10 + CGFloat(c) * cellW
                if i == 7 {
                    NSColor(white: 0.85, alpha: 1).setFill()
                    NSBezierPath(roundedRect: NSRect(x: x + cellW / 2 - 38, y: y + 2, width: 76, height: 72), xRadius: 6, yRadius: 6).fill()
                }
                icons[t]!.draw(in: NSRect(x: x + cellW / 2 - 34, y: y + 4, width: 68, height: 68), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                let labelRect = NSRect(x: x + 6, y: y + 76, width: cellW - 12, height: 34)
                if i == 7 {
                    NSColor.systemBlue.setFill()
                    let sz = (name as NSString).boundingRect(with: labelRect.size, options: [.usesLineFragmentOrigin], attributes: labelAttrs)
                    NSBezierPath(roundedRect: NSRect(x: x + cellW / 2 - sz.width / 2 - 4, y: y + 76, width: sz.width + 8, height: sz.height + 1), xRadius: 4, yRadius: 4).fill()
                    var a = labelAttrs; a[.foregroundColor] = NSColor.white
                    (name as NSString).draw(with: labelRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: a)
                } else {
                    (name as NSString).draw(with: labelRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: labelAttrs)
                }
                i += 1
            }
            y += cellH
        }
    }

    // MARK: Text document

    private static func drawText(_ ctx: CGContext) {
        var rng = SeededRNG(2)
        let W = ContentGeometry.widthPt, H = ContentGeometry.heightPt
        let pageX: CGFloat = 70, pageW = W - 140
        NSColor.white.setFill()
        NSRect(x: pageX, y: 0, width: pageW, height: H).fill()
        NSColor(white: 0.85, alpha: 1).setFill()
        NSRect(x: pageX - 1, y: 0, width: 1, height: H).fill()
        NSRect(x: pageX + pageW, y: 0, width: 1, height: H).fill()
        let margin: CGFloat = 64
        let colX = pageX + margin, colW = pageW - 2 * margin
        func serif(_ size: CGFloat, _ weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
            var d = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.serif) ?? NSFont.systemFont(ofSize: size).fontDescriptor
            if italic { d = d.withSymbolicTraits(.italic) }
            return NSFont(descriptor: d, size: size) ?? NSFont.systemFont(ofSize: size)
        }
        func para(_ font: NSFont, color: NSColor = NSColor(white: 0.12, alpha: 1), spacing: CGFloat = 4, indent: CGFloat = 0) -> [NSAttributedString.Key: Any] {
            let p = NSMutableParagraphStyle(); p.lineSpacing = spacing; p.firstLineHeadIndent = indent; p.headIndent = 0
            return [.font: font, .foregroundColor: color, .paragraphStyle: p]
        }
        var y: CGFloat = 70
        func put(_ s: String, _ a: [NSAttributedString.Key: Any], x: CGFloat = colX, w: CGFloat = colW, after: CGFloat) {
            let r = (s as NSString).boundingRect(with: NSSize(width: w, height: 10000), options: [.usesLineFragmentOrigin], attributes: a)
            (s as NSString).draw(with: NSRect(x: x, y: y, width: w, height: r.height + 2), options: [.usesLineFragmentOrigin], attributes: a)
            y += ceil(r.height) + after
        }
        put("Measured Delivery on Narrow Links", para(serif(34, .bold)), after: 8)
        put("A field guide to prediction, truth and the space in between", para(serif(17, .regular, italic: true), color: NSColor(white: 0.4, alpha: 1)), after: 30)
        var section = 1
        while y < H - 400 {
            put("\(section). " + sentence(&rng, Int(rng.range(2, 5))).dropLast(), para(NSFont.systemFont(ofSize: 22, weight: .bold), color: NSColor(red: 0.1, green: 0.2, blue: 0.45, alpha: 1)), after: 12)
            for _ in 0..<Int(rng.range(2, 4)) {
                put(paragraph(&rng, sentences: Int(rng.range(3, 6))), para(serif(15), spacing: 5, indent: 18), after: 12)
            }
            switch section % 4 {
            case 0:
                let a = para(serif(19, .regular, italic: true), color: NSColor(white: 0.35, alpha: 1))
                NSColor(red: 0.1, green: 0.2, blue: 0.45, alpha: 1).setFill()
                let y0 = y
                put("“" + sentence(&rng, 14).dropLast() + ".”", a, x: colX + 28, w: colW - 56, after: 14)
                NSRect(x: colX + 8, y: y0, width: 3, height: y - y0 - 14).fill()
            case 1:
                let lines = (0..<Int(rng.range(4, 8))).map { i in "let \(rng.pick(["band", "edge", "fill", "tile", "rows"]))\(i) = estimate(\(Int(rng.range(1, 900))), over: .\(rng.pick(["fast4G", "japanBus", "lte"])))" }
                let a = para(NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), color: NSColor(red: 0.2, green: 0.2, blue: 0.3, alpha: 1), spacing: 3)
                let s = lines.joined(separator: "\n")
                let r = (s as NSString).boundingRect(with: NSSize(width: colW - 24, height: 10000), options: [.usesLineFragmentOrigin], attributes: a)
                NSColor(white: 0.95, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: colX, y: y, width: colW, height: r.height + 24), xRadius: 6, yRadius: 6).fill()
                y += 12
                put(s, a, x: colX + 12, w: colW - 24, after: 26)
            case 2:
                for _ in 0..<Int(rng.range(3, 6)) {
                    let y0 = y
                    put(sentence(&rng, Int(rng.range(6, 14))), para(NSFont.systemFont(ofSize: 14)), x: colX + 24, w: colW - 24, after: 6)
                    NSColor(white: 0.2, alpha: 1).setFill()
                    NSBezierPath(ovalIn: NSRect(x: colX + 8, y: y0 + 7, width: 5, height: 5)).fill()
                }
                y += 10
            default:
                put(paragraph(&rng, sentences: 3), para(NSFont.systemFont(ofSize: 13), color: NSColor(white: 0.3, alpha: 1)), after: 14)
            }
            section += 1
        }
    }

    // MARK: Photos

    private static func drawPhotos(_ ctx: CGContext) {
        var rng = SeededRNG(3)
        let W = ContentGeometry.widthPt, H = ContentGeometry.heightPt
        let cols = 4, gap: CGFloat = 3
        let cell = (W - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let headAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: NSColor.white]
        let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.65, alpha: 1)]
        let months = ["October 2026", "September 2026", "August 2026", "July 2026", "June 2026", "May 2026", "April 2026"]
        var y: CGFloat = 0, n = 0, m = 0
        func hsb(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat) -> CGColor { NSColor(hue: h.truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1).cgColor }
        while y < H {
            if n % 24 == 0 {
                (months[m % months.count] as NSString).draw(at: NSPoint(x: 14, y: y + 18), withAttributes: headAttrs)
                ("\(Int(rng.range(20, 300))) photos" as NSString).draw(at: NSPoint(x: 16, y: y + 46), withAttributes: subAttrs)
                y += 72; m += 1
            }
            for c in 0..<cols {
                let r = CGRect(x: gap + CGFloat(c) * (cell + gap), y: y, width: cell, height: cell)
                ctx.saveGState(); ctx.clip(to: r)
                let hue = rng.unit()
                switch Int(rng.next() % 5) {
                case 0: // sunset with mountains
                    let g = CGGradient(colorsSpace: cs, colors: [hsb(hue + 0.6, 0.6, 0.35), hsb(hue + 0.95, 0.7, 0.9), hsb(hue + 0.1, 0.8, 1)] as CFArray, locations: [0, 0.6, 1])!
                    ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
                    ctx.setFillColor(hsb(hue + 0.12, 0.5, 1)); ctx.fillEllipse(in: CGRect(x: r.minX + rng.range(30, cell - 80), y: r.minY + cell * 0.45, width: 50, height: 50))
                    for layer in 0..<3 {
                        ctx.setFillColor(hsb(hue + 0.65, 0.5, 0.15 + CGFloat(layer) * 0.08))
                        ctx.move(to: CGPoint(x: r.minX, y: r.maxY))
                        var x = r.minX
                        while x <= r.maxX + 20 { ctx.addLine(to: CGPoint(x: x, y: r.minY + cell * (0.55 + 0.12 * CGFloat(layer)) + rng.range(-25, 25))); x += rng.range(20, 50) }
                        ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); ctx.fillPath()
                    }
                case 1: // bokeh
                    ctx.setFillColor(hsb(hue, 0.5, 0.12)); ctx.fill(r)
                    for _ in 0..<26 {
                        let d = rng.range(12, 60)
                        ctx.setFillColor(NSColor(hue: (hue + rng.range(-0.1, 0.1) + 1).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 1, alpha: rng.range(0.15, 0.5)).cgColor)
                        ctx.fillEllipse(in: CGRect(x: r.minX + rng.range(-10, cell), y: r.minY + rng.range(-10, cell), width: d, height: d))
                    }
                case 2: // seascape
                    let sky = CGGradient(colorsSpace: cs, colors: [hsb(0.58, 0.5, 0.95), hsb(0.55, 0.2, 1)] as CFArray, locations: [0, 1])!
                    ctx.drawLinearGradient(sky, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.minY + cell * 0.55), options: [.drawsAfterEndLocation])
                    let sea = CGGradient(colorsSpace: cs, colors: [hsb(0.55 + hue * 0.05, 0.7, 0.6), hsb(0.6, 0.8, 0.3)] as CFArray, locations: [0, 1])!
                    ctx.saveGState(); ctx.clip(to: CGRect(x: r.minX, y: r.minY + cell * 0.55, width: cell, height: cell * 0.45))
                    ctx.drawLinearGradient(sea, start: CGPoint(x: r.midX, y: r.minY + cell * 0.55), end: CGPoint(x: r.midX, y: r.maxY), options: [])
                    ctx.restoreGState()
                    ctx.setFillColor(NSColor(white: 1, alpha: 0.8).cgColor)
                    for _ in 0..<5 { ctx.fillEllipse(in: CGRect(x: r.minX + rng.range(0, cell - 60), y: r.minY + rng.range(10, cell * 0.35), width: rng.range(40, 90), height: rng.range(10, 22))) }
                case 3: // radial abstract
                    let g = CGGradient(colorsSpace: cs, colors: [hsb(hue, 0.4, 1), hsb(hue + 0.3, 0.8, 0.7), hsb(hue + 0.5, 0.9, 0.25)] as CFArray, locations: [0, 0.5, 1])!
                    let c0 = CGPoint(x: r.minX + rng.range(0, cell), y: r.minY + rng.range(0, cell))
                    ctx.drawRadialGradient(g, startCenter: c0, startRadius: 0, endCenter: c0, endRadius: cell * 1.1, options: [.drawsAfterEndLocation])
                default: // geometric stripes
                    ctx.setFillColor(hsb(hue, 0.3, 0.95)); ctx.fill(r)
                    ctx.translateBy(x: r.midX, y: r.midY); ctx.rotate(by: rng.range(-0.8, 0.8))
                    var k = -cell
                    while k < cell {
                        ctx.setFillColor(hsb(hue + rng.range(0, 0.3), 0.7, rng.range(0.5, 0.95)))
                        ctx.fill(CGRect(x: k, y: -cell, width: rng.range(8, 30), height: cell * 2)); k += rng.range(20, 50)
                    }
                }
                ctx.restoreGState()
                n += 1
                _ = c
            }
            y += cell + gap
        }
    }

    // MARK: Web page

    private static func drawWeb(_ ctx: CGContext) {
        var rng = SeededRNG(4)
        let W = ContentGeometry.widthPt, H = ContentGeometry.heightPt
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        NSColor(red: 0.08, green: 0.12, blue: 0.22, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: W, height: 60).fill()
        ("◆ Northwind Journal" as NSString).draw(at: NSPoint(x: 28, y: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .heavy), .foregroundColor: NSColor.white])
        var nx: CGFloat = 430
        for item in ["News", "Science", "Travel", "Design", "About"] {
            (item as NSString).draw(at: NSPoint(x: nx, y: 22), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor(white: 0.85, alpha: 1)])
            nx += 86
        }
        func imageBlock(_ r: CGRect, _ hue: CGFloat) {
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.clip()
            let g = CGGradient(colorsSpace: cs, colors: [NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor,
                                                         NSColor(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.55, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
            ctx.setFillColor(NSColor(white: 1, alpha: 0.18).cgColor)
            ctx.fillEllipse(in: CGRect(x: r.minX + r.width * 0.55, y: r.minY + r.height * 0.15, width: r.height * 0.6, height: r.height * 0.6))
            ctx.restoreGState()
        }
        // Hero
        imageBlock(CGRect(x: 0, y: 60, width: W, height: 320), 0.58)
        ("The quiet art of moving pixels" as NSString).draw(at: NSPoint(x: 48, y: 250), withAttributes: [.font: NSFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: NSColor.white])
        ("How a remote desktop survives a bus ride through the mountains" as NSString).draw(at: NSPoint(x: 50, y: 306), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor(white: 1, alpha: 0.85)])
        var y: CGFloat = 410
        let mainX: CGFloat = 40, mainW: CGFloat = 560, sideX: CGFloat = 640, sideW: CGFloat = 220
        let body: [NSAttributedString.Key: Any] = {
            let p = NSMutableParagraphStyle(); p.lineSpacing = 5
            return [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(white: 0.18, alpha: 1), .paragraphStyle: p]
        }()
        var sideY = y
        while y < H - 300 {
            let h = (sentence(&rng, 5).dropLast() as NSString)
            h.draw(with: NSRect(x: mainX, y: y, width: mainW, height: 60), options: [.usesLineFragmentOrigin], attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: NSColor(white: 0.08, alpha: 1)])
            y += 48
            for _ in 0..<2 {
                let p = paragraph(&rng, sentences: 4) as NSString
                let r = p.boundingRect(with: NSSize(width: mainW, height: 2000), options: [.usesLineFragmentOrigin], attributes: body)
                p.draw(with: NSRect(x: mainX, y: y, width: mainW, height: r.height + 2), options: [.usesLineFragmentOrigin], attributes: body)
                y += ceil(r.height) + 16
            }
            if rng.unit() < 0.6 {
                imageBlock(CGRect(x: mainX, y: y, width: mainW, height: 240), rng.unit()); y += 256
                (sentence(&rng, 8) as NSString).draw(at: NSPoint(x: mainX, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.5, alpha: 1)])
                y += 36
            } else {
                for c in 0..<3 {
                    let r = CGRect(x: mainX + CGFloat(c) * 190, y: y, width: 180, height: 200)
                    NSColor.white.setFill(); NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
                    NSColor(white: 0.88, alpha: 1).setStroke(); NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).stroke()
                    imageBlock(CGRect(x: r.minX, y: r.minY, width: r.width, height: 110), rng.unit())
                    (sentence(&rng, 6) as NSString).draw(with: NSRect(x: r.minX + 10, y: r.minY + 120, width: r.width - 20, height: 70), options: [.usesLineFragmentOrigin],
                                                        attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor(white: 0.15, alpha: 1)])
                }
                y += 224
            }
            y += 20
            while sideY < y {
                NSColor(white: 0.93, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: sideX, y: sideY, width: sideW, height: 150), xRadius: 8, yRadius: 8).fill()
                ("RELATED" as NSString).draw(at: NSPoint(x: sideX + 14, y: sideY + 12), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.systemOrange])
                (sentence(&rng, 9) as NSString).draw(with: NSRect(x: sideX + 14, y: sideY + 32, width: sideW - 28, height: 110), options: [.usesLineFragmentOrigin],
                                                    attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor(white: 0.2, alpha: 1)])
                sideY += 170
            }
        }
        NSColor(red: 0.08, green: 0.12, blue: 0.22, alpha: 1).setFill()
        NSRect(x: 0, y: H - 200, width: W, height: 200).fill()
        ("© Northwind Journal · A mock page for Reveal Lab" as NSString).draw(at: NSPoint(x: 40, y: H - 120), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.7, alpha: 1)])
    }

    // MARK: Terminal

    private static func drawTerminal(_ ctx: CGContext) {
        var rng = SeededRNG(5)
        let H = ContentGeometry.heightPt
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let lineH: CGFloat = 16
        let fg = NSColor(white: 0.85, alpha: 1)
        let green = NSColor(red: 0.45, green: 0.85, blue: 0.45, alpha: 1), red = NSColor(red: 0.95, green: 0.4, blue: 0.4, alpha: 1)
        let blue = NSColor(red: 0.45, green: 0.65, blue: 1, alpha: 1), yellow = NSColor(red: 0.95, green: 0.8, blue: 0.35, alpha: 1)
        let grey = NSColor(white: 0.5, alpha: 1), magenta = NSColor(red: 0.85, green: 0.5, blue: 0.9, alpha: 1)
        var y: CGFloat = 10
        func line(_ parts: [(String, NSColor, Bool)]) {
            var x: CGFloat = 12
            for (s, c, b) in parts {
                let a: [NSAttributedString.Key: Any] = [.font: b ? bold : font, .foregroundColor: c]
                (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: a)
                x += (s as NSString).size(withAttributes: a).width
            }
            y += lineH
        }
        func prompt(_ cmd: String) { line([("user@host", green, true), (" ~/src/demo ", blue, true), ("% ", fg, false), (cmd, fg, false)]) }
        let files = ["Package.swift", "README.md", "Sources", "Tests", "build.sh", "docs", "scripts", ".gitignore", "results.txt", "bench.py"]
        while y < H - lineH {
            switch Int(rng.next() % 5) {
            case 0:
                prompt("ls -la")
                for f in files.shuffled(using: &rng).prefix(Int(rng.range(5, 10))) {
                    let dir = !f.contains(".")
                    line([((dir ? "drwxr-xr-x" : "-rw-r--r--") + "  1 user  staff  " + String(format: "%6d", Int(rng.range(64, 90000))) + " Oct \(Int(rng.range(1, 28))) 12:\(Int(rng.range(10, 59)))  ", grey, false), (f, dir ? blue : fg, dir)])
                }
            case 1:
                prompt("swift build -c release")
                for i in 0..<Int(rng.range(6, 16)) {
                    line([("[\(i + 1)/\(Int(rng.range(16, 40)))] ", grey, false), ("Compiling ", fg, false), (rng.pick(["Renderer", "Session", "Tiles", "Codec", "Probe"]) + " " + rng.pick(["Fill", "Blur", "Pacer", "Link"]) + ".swift", fg, true)])
                    if rng.unit() < 0.1 { line([("warning: ", yellow, true), ("variable 'band' was never mutated; consider changing to 'let'", fg, false)]) }
                }
                line([("Build complete! ", green, true), ("(\(String(format: "%.2f", rng.range(2, 40)))s)", grey, false)])
            case 2:
                prompt("git log --oneline -8")
                for _ in 0..<8 {
                    let hash = String(format: "%07x", Int(rng.next() % 0xFFFFFFF))
                    line([(hash + " ", yellow, false), (sentence(&rng, Int(rng.range(4, 9))), fg, false)])
                }
            case 3:
                prompt("swift test")
                for _ in 0..<Int(rng.range(5, 14)) {
                    let pass = rng.unit() < 0.88
                    line([("Test Case ", fg, false), ("'" + rng.pick(["FillTests", "BlurTests", "LinkTests"]) + "." + rng.pick(["testEdge", "testKawase", "testCrossfade", "testBudget", "testMirror"]) + "'", magenta, false),
                          (pass ? " passed " : " failed ", pass ? green : red, true), ("(\(String(format: "%.3f", rng.range(0.001, 0.4))) seconds)", grey, false)])
                }
            default:
                prompt("./bench --frames 600")
                for i in 0..<Int(rng.range(4, 10)) {
                    let p = Int(rng.range(0, 30))
                    line([("frame \(i * 60)  ", grey, false), ("[" + String(repeating: "█", count: p) + String(repeating: "·", count: 30 - p) + "] ", blue, false),
                          (String(format: "%.3f ms", rng.range(0.02, 0.6)), fg, false)])
                }
            }
            y += 4
        }
    }
}
