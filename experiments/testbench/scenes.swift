// Synthetic screen content for codec experiments (experiments/scalable): AppKit views that look like the
// things a remote desktop shows (documents, terminals, code, controls, sidebars with vibrancy, photo grids,
// dashboards, chat), all generated from fixed seeds, nothing taken from the person's own windows. Shared by
// the Test Bench (`--scene NAME`, a real window captured through the window server) and by
// experiments/scalable/corpus/render.swift (the same views drawn offscreen at 2x).
import AppKit

/// Deterministic word salad: a fixed vocabulary, a 64-bit LCG.
struct SceneText {
    var rng: UInt64
    init(seed: UInt64) { rng = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next(_ n: Int) -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int(rng >> 33) % max(1, n) }
    static let words = ["the", "remote", "desktop", "streams", "tiles", "over", "a", "slow", "link", "and", "every", "pixel", "that",
                        "changes", "is", "sent", "once", "lossless", "window", "scroll", "copy", "rect", "viewer", "host", "budget",
                        "latency", "quality", "frame", "refine", "crisp", "text", "layer", "motion", "video", "keyframe", "with",
                        "for", "when", "only", "region", "dirty", "base", "detail", "upgrade", "resolution", "phone", "Retina",
                        "kilobytes", "per", "second", "measured", "encoder", "decoder", "screen", "content", "of", "to", "in"]
    mutating func sentence(_ minWords: Int = 6, _ maxWords: Int = 16) -> String {
        let n = minWords + next(maxWords - minWords + 1)
        var s = (0..<n).map { _ in SceneText.words[next(SceneText.words.count)] }.joined(separator: " ")
        s = s.prefix(1).uppercased() + s.dropFirst()
        return s + [".", ".", ".", "?", "!"][next(5)]
    }
    mutating func paragraph(_ sentences: Int) -> String { (0..<sentences).map { _ in sentence() }.joined(separator: " ") }
    static let japanese = ["遠隔デスクトップの画面を、遅い回線でも快適に表示します。", "変更された画素だけを送り、静止した部分は可逆圧縮で鮮明に仕上げます。",
                           "スクロールはコピー矩形として送られ、帯域をほとんど使いません。", "スマートフォンでは一倍の解像度で十分な場合が多いです。",
                           "回線が良くなれば、差分だけを追加して二倍の解像度に上げられます。", "東京と大阪の間で測定した結果を下の表にまとめました。",
                           "文字の輪郭は可逆符号化で、写真は動画符号化で送ります。", "設定画面から画質と帯域の上限を変更できます。"]
}

enum SceneFactory {
    static let names = ["text", "terminal", "vibrancy", "controls", "mixed", "photos", "code", "chat", "document-sans", "document-serif",
                        "document-japanese", "document-small", "spreadsheet", "dashboard", "icons", "gradients", "noise-photo", "wallpaper"]

    static func make(_ name: String, size: NSSize, seed: UInt64 = 1) -> NSView? {
        let r = NSRect(origin: .zero, size: size)
        switch name {
        case "text": return textView(r, seed: seed)
        case "terminal": return terminal(r, seed: seed)
        case "vibrancy": return vibrancy(r, seed: seed)
        case "controls": return controls(r)
        case "mixed": return mixed(r, seed: seed)
        case "photos": return photos(r)
        case "code": return code(r, seed: seed)
        case "chat": return chat(r, seed: seed)
        case "document-sans": return document(r, seed: seed, font: { NSFont.systemFont(ofSize: $0, weight: $1) })
        case "document-serif": return document(r, seed: seed, font: { serif($0, $1) })
        case "document-japanese": return document(r, seed: seed, font: { NSFont(name: $1 == .regular ? "HiraginoSans-W3" : "HiraginoSans-W6", size: $0) ?? .systemFont(ofSize: $0) }, japanese: true)
        case "document-small": return document(r, seed: seed, font: { NSFont(name: $1 == .regular ? "Helvetica" : "Helvetica-Bold", size: $0 * 0.8) ?? .systemFont(ofSize: $0) })
        case "spreadsheet": return Spreadsheet(frame: r, seed: seed)
        case "dashboard": return Dashboard(frame: r, seed: seed)
        case "icons": return icons(r)
        case "gradients": return Gradients(frame: r)
        case "noise-photo": return NoisePhoto(frame: r)
        case "wallpaper": return wallpaper(r)
        default: return nil
        }
    }

    static func serif(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    static func scrollingText(_ r: NSRect, _ text: NSAttributedString, background: NSColor) -> NSScrollView {
        let scroll = NSScrollView(frame: r)
        scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width, .height]; scroll.drawsBackground = true
        scroll.backgroundColor = background
        let tv = NSTextView(frame: NSRect(origin: .zero, size: r.size))
        tv.isEditable = false; tv.isSelectable = false; tv.drawsBackground = true; tv.backgroundColor = background
        tv.textContainerInset = NSSize(width: 12, height: 10)
        tv.autoresizingMask = [.width]; tv.textContainer?.widthTracksTextView = true
        tv.textStorage?.setAttributedString(text)
        scroll.documentView = tv
        return scroll
    }

    /// The bench's own text (600 numbered lines of monospaced words).
    static func textView(_ r: NSRect, seed: UInt64) -> NSView {
        var t = SceneText(seed: seed), s = ""
        for i in 1...200 { s += String(format: "%4d  ", i) + (0..<9).map { _ in SceneText.words[t.next(SceneText.words.count)] }.joined(separator: " ") + "\n" }
        return scrollingText(r, NSAttributedString(string: s, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor.textColor]), background: .textBackgroundColor)
    }

    static func terminal(_ r: NSRect, seed: UInt64) -> NSView {
        var t = SceneText(seed: seed)
        let font = NSFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont(name: "Menlo-Bold", size: 12) ?? font
        let fg = NSColor(white: 0.86, alpha: 1), green = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.4, alpha: 1)
        let blue = NSColor(calibratedRed: 0.4, green: 0.6, blue: 1, alpha: 1), yellow = NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.3, alpha: 1)
        let red = NSColor(calibratedRed: 1, green: 0.4, blue: 0.4, alpha: 1)
        let out = NSMutableAttributedString()
        func add(_ s: String, _ c: NSColor = fg, _ f: NSFont? = nil) { out.append(NSAttributedString(string: s, attributes: [.font: f ?? font, .foregroundColor: c])) }
        func prompt(_ cmd: String) { add("bench@mirage", green, bold); add(" ~/src/mirage ", blue, bold); add("% ", fg); add(cmd + "\n") }
        prompt("ls -la Sources/MirageCore/Tiles")
        let files = ["ShiftDetector.swift", "TileCodec.swift", "TileTracker.swift", "DirtyRegion.swift", "CopyRect.swift", "Palette.swift", "Refiner.swift"]
        add("total 312\n")
        for (i, f) in files.enumerated() {
            add("-rw-r--r--  1 bench  staff  \(String(format: "%6d", 2000 + t.next(40000))) Oct \(10 + i) 1\(t.next(10)):\(String(format: "%02d", t.next(60))) ")
            add(f + "\n", i % 3 == 0 ? fg : blue)
        }
        prompt("swift build -c release")
        for _ in 0..<6 { add("[\(t.next(300))/\(300)] Compiling MirageCore \(files[t.next(files.count)])\n", fg) }
        add("warning: ", yellow, bold); add("variable 'stride' was never mutated; consider changing to 'let'\n")
        add("Build complete! (41.27s)\n", green)
        prompt("git log --oneline -12")
        for _ in 0..<12 { add(String(format: "%07x ", t.next(0xFFFFFFF)), yellow); add(t.sentence(4, 9) + "\n") }
        prompt("top -l 1 -n 8 -o cpu")
        add("PID    COMMAND      %CPU  TIME     #TH   MEM\n", fg, bold)
        for _ in 0..<8 { add(String(format: "%-6d %-12@ %4.1f  %02d:%02d.%02d %-5d %dM\n", 300 + t.next(9000), SceneText.words[t.next(SceneText.words.count)] as NSString, Double(t.next(900)) / 10, t.next(60), t.next(60), t.next(100), 1 + t.next(40), 8 + t.next(900))) }
        prompt("ping -c 4 mac-daddy")
        for i in 0..<4 { add("64 bytes from 100.64.0.\(t.next(250)): icmp_seq=\(i) ttl=64 time=\(150 + t.next(60)).\(t.next(1000)) ms\n") }
        add("error: ", red, bold); add("connection to host timed out after 3 attempts\n")
        prompt("")
        let v = scrollingText(r, out, background: NSColor(white: 0.11, alpha: 1))
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    static func code(_ r: NSRect, seed: UInt64) -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let kw = NSColor(calibratedRed: 0.99, green: 0.37, blue: 0.64, alpha: 1), ty = NSColor(calibratedRed: 0.36, green: 0.85, blue: 1, alpha: 1)
        let str = NSColor(calibratedRed: 0.99, green: 0.42, blue: 0.36, alpha: 1), com = NSColor(calibratedRed: 0.5, green: 0.55, blue: 0.6, alpha: 1)
        let num = NSColor(calibratedRed: 0.82, green: 0.75, blue: 0.5, alpha: 1), fg = NSColor(white: 0.88, alpha: 1), ln = NSColor(white: 0.4, alpha: 1)
        var t = SceneText(seed: seed)
        let out = NSMutableAttributedString()
        func add(_ s: String, _ c: NSColor) { out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c])) }
        for i in 1...90 {
            add(String(format: "%4d  ", i), ln)
            let indent = String(repeating: "    ", count: t.next(4))
            add(indent, fg)
            switch t.next(7) {
            case 0: add("// " + t.sentence(4, 10), com)
            case 1: add("let ", kw); add(SceneText.words[t.next(SceneText.words.count)] + "Count", fg); add(": ", fg); add("Int", ty); add(" = ", fg); add("\(t.next(4096))", num)
            case 2: add("func ", kw); add(SceneText.words[t.next(SceneText.words.count)] + "(_ rect: ", fg); add("PixelRect", ty); add(") -> ", fg); add("Data", ty); add("? {", fg)
            case 3: add("guard let ", kw); add("tile = tracker.tile(at: x, y) ", fg); add("else", kw); add(" { ", fg); add("return nil", kw); add(" }", fg)
            case 4: add("log(", fg); add("\"" + t.sentence(2, 5) + "\"", str); add(")", fg)
            case 5: add("}", fg)
            default: add("budget.spend(bytes: data.count, at: ", fg); add("\(t.next(100)).\(t.next(10))", num); add(")", fg)
            }
            add("\n", fg)
        }
        let v = scrollingText(r, out, background: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    static func document(_ r: NSRect, seed: UInt64, font: (CGFloat, NSFont.Weight) -> NSFont, japanese: Bool = false) -> NSView {
        var t = SceneText(seed: seed)
        let out = NSMutableAttributedString()
        let ps = NSMutableParagraphStyle(); ps.paragraphSpacing = 8; ps.lineSpacing = 2
        func add(_ s: String, _ size: CGFloat, _ w: NSFont.Weight, _ c: NSColor = .textColor) {
            out.append(NSAttributedString(string: s, attributes: [.font: font(size, w), .foregroundColor: c, .paragraphStyle: ps]))
        }
        func para(_ n: Int) -> String { japanese ? (0..<n).map { _ in SceneText.japanese[t.next(SceneText.japanese.count)] }.joined() : t.paragraph(n) }
        add((japanese ? "低速回線のための遠隔デスクトップ" : "A remote desktop for bad links") + "\n", 28, .bold)
        add((japanese ? "設計メモ 第三版" : "Design notes, third revision") + "\n", 15, .regular, .secondaryLabelColor)
        for s in 0..<4 {
            add("\(s + 1). " + (japanese ? "解像度と帯域" : t.sentence(3, 6)) + "\n", 20, .semibold)
            for _ in 0..<2 { add(para(4 + t.next(4)) + "\n", 13 + CGFloat(s % 2) * 2, .regular) }
            add(para(2) + "\n", 11, .regular, .secondaryLabelColor)
        }
        return scrollingText(r, out, background: .textBackgroundColor)
    }

    static func label(_ s: String, _ f: NSFont, _ c: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: s); l.font = f; l.textColor = c; l.sizeToFit(); return l
    }

    static func controls(_ r: NSRect) -> NSView {
        let v = NSView(frame: r)
        var y = r.height - 50
        func row(_ title: String, _ views: [NSView]) {
            let l = label(title, .systemFont(ofSize: 13)); l.frame.origin = NSPoint(x: 30, y: y + 4); v.addSubview(l)
            var x: CGFloat = 200
            for c in views { c.frame.origin = NSPoint(x: x, y: y); v.addSubview(c); x += c.frame.width + 16 }
            y -= 52
        }
        func button(_ t: String, _ def: Bool = false) -> NSButton { let b = NSButton(title: t, target: nil, action: nil); b.bezelStyle = .push; if def { b.keyEquivalent = "\r" }; b.sizeToFit(); return b }
        func check(_ t: String, _ on: Bool) -> NSButton { let b = NSButton(checkboxWithTitle: t, target: nil, action: nil); b.state = on ? .on : .off; b.sizeToFit(); return b }
        func radio(_ t: String, _ on: Bool) -> NSButton { let b = NSButton(radioButtonWithTitle: t, target: nil, action: nil); b.state = on ? .on : .off; b.sizeToFit(); return b }
        row("Buttons", [button("Cancel"), button("Connect", true), button("Options…"), button("Disconnect")])
        row("Checkboxes", [check("Lossless refinement", true), check("Copy-rect scrolling", true), check("Show statistics", false)])
        row("Radio", [radio("Fit", true), radio("1x", false), radio("2x (Retina)", false)])
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26)); pop.addItems(withTitles: ["Automatic quality", "Prefer sharpness", "Prefer motion"])
        let seg = NSSegmentedControl(labels: ["Desktop", "Window", "Region"], trackingMode: .selectOne, target: nil, action: nil); seg.selectedSegment = 1; seg.sizeToFit()
        row("Pop-up, segments", [pop, seg])
        let slider = NSSlider(value: 0.62, minValue: 0, maxValue: 1, target: nil, action: nil); slider.frame.size = NSSize(width: 260, height: 24)
        let ticks = NSSlider(value: 3, minValue: 0, maxValue: 8, target: nil, action: nil); ticks.numberOfTickMarks = 9; ticks.allowsTickMarkValuesOnly = true; ticks.frame.size = NSSize(width: 220, height: 28)
        row("Sliders", [slider, ticks])
        let tf = NSTextField(string: "mac-daddy.tailnet.ts.net"); tf.frame.size = NSSize(width: 260, height: 24)
        let sf = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24)); sf.placeholderString = "Search hosts"
        row("Fields", [tf, sf])
        let p = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 300, height: 20)); p.isIndeterminate = false; p.doubleValue = 64; p.style = .bar
        let sw = NSSwitch(); sw.state = .on; sw.sizeToFit()
        let st = NSStepper(); st.sizeToFit()
        row("Progress, switch", [p, sw, st])
        let cw = NSColorWell(frame: NSRect(x: 0, y: 0, width: 60, height: 28)); cw.color = .systemOrange
        let lvl = NSLevelIndicator(frame: NSRect(x: 0, y: 0, width: 200, height: 18)); lvl.maxValue = 10; lvl.doubleValue = 7; lvl.levelIndicatorStyle = .continuousCapacity
        let stars = NSLevelIndicator(frame: NSRect(x: 0, y: 0, width: 100, height: 18)); stars.maxValue = 5; stars.doubleValue = 4; stars.levelIndicatorStyle = .rating
        row("Colour, levels", [cw, lvl, stars])
        let box = NSBox(frame: NSRect(x: 30, y: 30, width: r.width - 60, height: y - 20)); box.title = "Connection details"
        var t = SceneText(seed: 5)
        let info = label((0..<4).map { _ in t.sentence(6, 12) }.joined(separator: "\n"), .systemFont(ofSize: 12), .secondaryLabelColor)
        info.frame.origin = NSPoint(x: 16, y: 10); box.contentView?.addSubview(info)
        v.addSubview(box)
        return v
    }

    /// A sidebar with vibrancy (blending within the window, over our own colourful content, so nothing behind
    /// the window is sampled) beside a list.
    static func vibrancy(_ r: NSRect, seed: UInt64) -> NSView {
        let v = NSView(frame: r)
        v.addSubview(Gradients(frame: r))
        let side = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 240, height: r.height))
        side.material = .sidebar; side.blendingMode = .withinWindow; side.state = .active
        var y = r.height - 40
        for (i, (sym, title)) in [("desktopcomputer", "Hosts"), ("rectangle.on.rectangle", "Windows"), ("display", "Displays"), ("speedometer", "Link"),
                                  ("chart.bar", "Statistics"), ("folder", "Recordings"), ("gearshape", "Settings"), ("star", "Favourites"),
                                  ("clock", "Recent"), ("tag", "Tags")].enumerated() {
            if i == 4 { let h = label("LIBRARY", .systemFont(ofSize: 11, weight: .semibold), .secondaryLabelColor); h.frame.origin = NSPoint(x: 18, y: y); side.addSubview(h); y -= 26 }
            if let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil) {
                let iv = NSImageView(image: img); iv.frame = NSRect(x: 18, y: y, width: 18, height: 18); iv.contentTintColor = .controlAccentColor; side.addSubview(iv)
            }
            let l = label(title, .systemFont(ofSize: 13)); l.frame.origin = NSPoint(x: 44, y: y); side.addSubview(l)
            y -= 28
        }
        v.addSubview(side)
        let header = NSVisualEffectView(frame: NSRect(x: 240, y: r.height - 52, width: r.width - 240, height: 52))
        header.material = .headerView; header.blendingMode = .withinWindow; header.state = .active
        let h = label("Hosts", .systemFont(ofSize: 18, weight: .bold)); h.frame.origin = NSPoint(x: 16, y: 14); header.addSubview(h)
        v.addSubview(header)
        let list = ListView(frame: NSRect(x: 240, y: 0, width: r.width - 240, height: r.height - 52), seed: seed)
        v.addSubview(list)
        return v
    }

    static func mixed(_ r: NSRect, seed: UInt64) -> NSView {
        let v = NSView(frame: r)
        var t = SceneText(seed: seed)
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Field report: Tokyo to Dallas\n", attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.labelColor]))
        for _ in 0..<6 { text.append(NSAttributedString(string: t.paragraph(4) + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])) }
        v.addSubview(scrollingText(NSRect(x: 0, y: 0, width: r.width * 0.5, height: r.height), text, background: .textBackgroundColor))
        let right = NSRect(x: r.width * 0.5, y: 0, width: r.width * 0.5, height: r.height)
        let iv = NSImageView(frame: NSRect(x: right.minX + 20, y: r.height * 0.45, width: right.width - 40, height: r.height * 0.5))
        iv.image = thumbnail("Big Sur Coastline") ?? thumbnail("Catalina Coast"); iv.imageScaling = .scaleAxesIndependently
        v.addSubview(iv)
        v.addSubview(Dashboard(frame: NSRect(x: right.minX, y: 0, width: right.width, height: r.height * 0.43), seed: seed, compact: true))
        return v
    }

    static let photoNames = ["Big Sur Coastline", "Catalina Coast", "Big Sur Night Grasses", "Catalina Rock", "Big Sur Waters Edge", "Catalina Shoreline",
                             "Big Sur Aerial", "Catalina Evening", "Big Sur Night Succulents", "Catalina Silhouette", "Big Sur Road", "Big Sur Shore Rocks",
                             "Big Sur Mountains", "Catalina Clouds", "Big Sur Horizon", "Catalina Sunset"]
    /// macOS's own wallpaper thumbnails (real photographs, ~356 px, shipped with the system).
    static func thumbnail(_ name: String) -> NSImage? { NSImage(contentsOfFile: "/System/Library/Desktop Pictures/.thumbnails/\(name).heic") }

    /// A photo-browser grid of the system wallpaper thumbnails, drawn at their native pixel size (178 pt at 2x).
    static func photos(_ r: NSRect) -> NSView {
        let v = NSView(frame: r)
        let cell: CGFloat = 178, gap: CGFloat = 8
        var x: CGFloat = gap, y = r.height - cell - gap, i = 0
        while y > -cell / 2 {
            if let img = thumbnail(photoNames[i % photoNames.count]) {
                let iv = NSImageView(frame: NSRect(x: x, y: y, width: cell, height: cell)); iv.image = img; iv.imageScaling = .scaleAxesIndependently
                v.addSubview(iv)
            }
            i += 1; x += cell + gap
            if x + cell > r.width { x = gap; y -= cell + gap }
        }
        return v
    }

    static func icons(_ r: NSRect) -> NSView {
        let v = NSView(frame: r)
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Applications"))?.filter { $0.hasSuffix(".app") }.sorted() ?? []
        let cell: CGFloat = 110
        var x: CGFloat = 20, y = r.height - cell - 10
        for a in apps {
            let iv = NSImageView(frame: NSRect(x: x + 23, y: y + 30, width: 64, height: 64)); iv.image = NSWorkspace.shared.icon(forFile: "/System/Applications/" + a)
            v.addSubview(iv)
            let l = label(String(a.dropLast(4)), .systemFont(ofSize: 11)); l.alignment = .center; l.frame = NSRect(x: x, y: y + 8, width: cell, height: 16)
            v.addSubview(l)
            x += cell
            if x + cell > r.width { x = 20; y -= cell; if y < 0 { break } }
        }
        return v
    }

    /// A big crop of one of macOS's rendered wallpapers (smooth, high-bit-depth gradients).
    static func wallpaper(_ r: NSRect) -> NSView {
        let iv = NSImageView(frame: r)
        if let img = NSImage(contentsOfFile: "/System/Library/Desktop Pictures/Mac Blue.heic") {
            let crop = NSImage(size: r.size)
            crop.lockFocus()
            img.draw(in: NSRect(origin: .zero, size: r.size), from: NSRect(x: 1800, y: 2400, width: r.width * 2.4, height: r.height * 2.4), operation: .copy, fraction: 1)
            crop.unlockFocus()
            iv.image = crop
        }
        iv.imageScaling = .scaleAxesIndependently
        return iv
    }

    static func chat(_ r: NSRect, seed: UInt64) -> NSView { ChatView(frame: r, seed: seed) }
}

final class ListView: NSView {
    var seed: UInt64
    init(frame: NSRect, seed: UInt64) { self.seed = seed; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        var t = SceneText(seed: seed)
        let cols: [CGFloat] = [16, 260, 420, 560]
        let hdr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        for (i, h) in ["Name", "Address", "Last seen", "Link"].enumerated() { (h as NSString).draw(at: NSPoint(x: cols[i], y: 6), withAttributes: hdr) }
        NSColor.separatorColor.setFill(); NSRect(x: 0, y: 26, width: bounds.width, height: 1).fill()
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let b: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        var y: CGFloat = 27, row = 0
        while y < bounds.height {
            if row % 2 == 1 { NSColor.alternatingContentBackgroundColors.last?.setFill(); NSRect(x: 0, y: y, width: bounds.width, height: 24).fill() }
            if row == 3 { NSColor.selectedContentBackgroundColor.setFill(); NSRect(x: 0, y: y, width: bounds.width, height: 24).fill() }
            let name = SceneText.words[t.next(SceneText.words.count)] + "-" + SceneText.words[t.next(SceneText.words.count)]
            (name as NSString).draw(at: NSPoint(x: cols[0], y: y + 3), withAttributes: a)
            ("100.\(64 + t.next(64)).\(t.next(256)).\(t.next(256))" as NSString).draw(at: NSPoint(x: cols[1], y: y + 4), withAttributes: b)
            ("\(1 + t.next(59)) min ago" as NSString).draw(at: NSPoint(x: cols[2], y: y + 4), withAttributes: b)
            ("\(t.next(900) + 50) ms, \(t.next(20) + 1) Mbps" as NSString).draw(at: NSPoint(x: cols[3], y: y + 4), withAttributes: b)
            y += 24; row += 1
        }
    }
}

final class Spreadsheet: NSView {
    var seed: UInt64
    init(frame: NSRect, seed: UInt64) { self.seed = seed; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        var t = SceneText(seed: seed)
        let colW: CGFloat = 86, rowH: CGFloat = 18
        let f: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.black]
        let h: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.darkGray]
        NSColor(white: 0.94, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: rowH).fill(); NSRect(x: 0, y: 0, width: 36, height: bounds.height).fill()
        var c = 0
        while CGFloat(c) * colW + 36 < bounds.width { (String(UnicodeScalar(65 + c % 26)!) as NSString).draw(at: NSPoint(x: 36 + CGFloat(c) * colW + 38, y: 3), withAttributes: h); c += 1 }
        var row = 1
        while CGFloat(row) * rowH < bounds.height {
            ("\(row)" as NSString).draw(at: NSPoint(x: 8, y: CGFloat(row) * rowH + 3), withAttributes: h)
            for col in 0..<c {
                let s: String = col == 0 ? SceneText.words[t.next(SceneText.words.count)] : col % 3 == 0 ? String(format: "%.2f%%", Double(t.next(10000)) / 100) : "\(t.next(100000))"
                if row % 7 == 0 && col == 2 { NSColor(calibratedRed: 1, green: 0.95, blue: 0.6, alpha: 1).setFill(); NSRect(x: 36 + CGFloat(col) * colW, y: CGFloat(row) * rowH, width: colW, height: rowH).fill() }
                (s as NSString).draw(at: NSPoint(x: 36 + CGFloat(col) * colW + 4, y: CGFloat(row) * rowH + 3), withAttributes: f)
            }
            row += 1
        }
        NSColor(white: 0.82, alpha: 1).setFill()
        for i in 0...c { NSRect(x: 36 + CGFloat(i) * colW, y: 0, width: 1, height: bounds.height).fill() }
        for i in 0...row { NSRect(x: 0, y: CGFloat(i) * rowH, width: bounds.width, height: 1).fill() }
    }
}

final class Dashboard: NSView {
    var seed: UInt64; var compact: Bool
    init(frame: NSRect, seed: UInt64, compact: Bool = false) { self.seed = seed; self.compact = compact; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirty: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        var t = SceneText(seed: seed)
        let cards = compact ? 2 : 3
        let cw = (bounds.width - CGFloat(cards + 1) * 16) / CGFloat(cards)
        let ch = compact ? bounds.height - 32 : (bounds.height - 48) / 2
        for row in 0..<(compact ? 1 : 2) {
            for i in 0..<cards {
                let r = NSRect(x: 16 + CGFloat(i) * (cw + 16), y: 16 + CGFloat(row) * (ch + 16), width: cw, height: ch)
                let sh = NSShadow(); sh.shadowBlurRadius = 6; sh.shadowOffset = NSSize(width: 0, height: -2); sh.shadowColor = NSColor(white: 0, alpha: 0.2)
                NSGraphicsContext.saveGraphicsState(); sh.set(); NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill(); NSGraphicsContext.restoreGraphicsState()
                ("Link \(SceneText.words[t.next(SceneText.words.count)])" as NSString).draw(at: NSPoint(x: r.minX + 12, y: r.maxY - 26), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
                ("\(t.next(900)).\(t.next(10)) kbps" as NSString).draw(at: NSPoint(x: r.minX + 12, y: r.maxY - 56), withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor.labelColor])
                let plot = NSRect(x: r.minX + 12, y: r.minY + 12, width: r.width - 24, height: r.height - 80)
                let colour = [NSColor.systemBlue, .systemGreen, .systemOrange, .systemPink, .systemPurple, .systemTeal][(row * 3 + i) % 6]
                if (row + i) % 2 == 0 {
                    let p = NSBezierPath(); var v = 0.5
                    for k in 0...60 { v = min(0.95, max(0.05, v + Double(t.next(200) - 100) / 800)); let pt = NSPoint(x: plot.minX + plot.width * CGFloat(k) / 60, y: plot.minY + plot.height * CGFloat(v)); k == 0 ? p.move(to: pt) : p.line(to: pt) }
                    let fill = p.copy() as! NSBezierPath; fill.line(to: NSPoint(x: plot.maxX, y: plot.minY)); fill.line(to: NSPoint(x: plot.minX, y: plot.minY)); fill.close()
                    NSGradient(starting: colour.withAlphaComponent(0.45), ending: colour.withAlphaComponent(0.02))?.draw(in: fill, angle: -90)
                    colour.setStroke(); p.lineWidth = 2; p.stroke()
                } else {
                    let n = 12
                    for k in 0..<n { let hgt = plot.height * CGFloat(10 + t.next(90)) / 100; colour.setFill(); NSBezierPath(roundedRect: NSRect(x: plot.minX + CGFloat(k) * plot.width / CGFloat(n) + 3, y: plot.minY, width: plot.width / CGFloat(n) - 6, height: hgt), xRadius: 3, yRadius: 3).fill() }
                }
            }
        }
    }
}

/// Modern-UI cards over a multi-stop gradient, with soft shadows and blurred circles.
final class Gradients: NSView {
    override func draw(_ dirty: NSRect) {
        NSGradient(colors: [NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.4, alpha: 1), NSColor(calibratedRed: 0.6, green: 0.3, blue: 0.85, alpha: 1), NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.95, alpha: 1)])?.draw(in: bounds, angle: 35)
        for (i, c) in [NSColor.systemYellow, .systemTeal, .systemPink].enumerated() {
            let d = bounds.height * (0.35 + CGFloat(i) * 0.12)
            let r = NSRect(x: bounds.width * (0.15 + CGFloat(i) * 0.3), y: bounds.height * (0.1 + CGFloat(i % 2) * 0.4), width: d, height: d)
            NSGradient(starting: c.withAlphaComponent(0.7), ending: c.withAlphaComponent(0))?.draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: .zero)
        }
        for i in 0..<3 {
            let r = NSRect(x: 60 + CGFloat(i) * (bounds.width - 120) / 3 + 12, y: bounds.height * 0.18, width: (bounds.width - 120) / 3 - 24, height: bounds.height * 0.5)
            let sh = NSShadow(); sh.shadowBlurRadius = 18; sh.shadowOffset = NSSize(width: 0, height: -6); sh.shadowColor = NSColor(white: 0, alpha: 0.3)
            NSGraphicsContext.saveGraphicsState(); sh.set(); NSColor(white: 1, alpha: 0.8).setFill(); NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18).fill(); NSGraphicsContext.restoreGraphicsState()
            (["Plan", "Link", "Quality"][i] as NSString).draw(at: NSPoint(x: r.minX + 20, y: r.maxY - 44), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor(white: 0.1, alpha: 1)])
            (["Free tier, 1 host", "1.2 Mbps, 180 ms", "Lossless when idle"][i] as NSString).draw(at: NSPoint(x: r.minX + 20, y: r.maxY - 72), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(white: 0.35, alpha: 1)])
            NSGradient(starting: .systemBlue, ending: .systemPurple)?.draw(in: NSBezierPath(roundedRect: NSRect(x: r.minX + 20, y: r.minY + 20, width: r.width - 40, height: 36), xRadius: 18, yRadius: 18), angle: 0)
            ("Choose" as NSString).draw(at: NSPoint(x: r.midX - 26, y: r.minY + 29), withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white])
        }
    }
}

/// The bench's photo backdrop: smooth gradients plus per-pixel noise (> 4096 colours), at the view's pixel size.
final class NoisePhoto: NSView {
    override func draw(_ dirty: NSRect) {
        let scale = window?.backingScaleFactor ?? 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32), let p = rep.bitmapData else { return }
        var rng: UInt32 = 7
        for y in 0..<h { for x in 0..<w {
            rng = rng &* 1664525 &+ 1013904223
            let n = Int(rng >> 28), o = (y * w + x) * 4
            p[o] = UInt8(clamping: 60 + x * 120 / max(1, w) + n); p[o + 1] = UInt8(clamping: 90 + y * 100 / max(1, h) + n); p[o + 2] = UInt8(clamping: 140 + (x + y) % 90 + n); p[o + 3] = 255
        } }
        rep.draw(in: bounds)
    }
}

final class ChatView: NSView {
    var seed: UInt64
    init(frame: NSRect, seed: UInt64) { self.seed = seed; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirty: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        var t = SceneText(seed: seed)
        var y: CGFloat = bounds.height - 20
        let font = NSFont.systemFont(ofSize: 14)
        while y > 40 {
            let mine = t.next(2) == 0
            let s = t.sentence(4, 24) as NSString
            let maxW = bounds.width * 0.55
            let br = s.boundingRect(with: NSSize(width: maxW, height: 1000), options: [.usesLineFragmentOrigin], attributes: [.font: font])
            let bw = ceil(br.width) + 24, bh = ceil(br.height) + 14
            y -= bh
            let x = mine ? bounds.width - bw - 20 : 64
            let bubble = NSRect(x: x, y: y, width: bw, height: bh)
            (mine ? NSColor.systemBlue : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
            NSBezierPath(roundedRect: bubble, xRadius: 16, yRadius: 16).fill()
            if !mine {
                let av = NSRect(x: 20, y: y, width: 32, height: 32)
                NSGradient(starting: [NSColor.systemOrange, .systemGreen, .systemPurple][t.next(3)], ending: .systemPink)?.draw(in: NSBezierPath(ovalIn: av), angle: 45)
                (String(SceneText.words[t.next(SceneText.words.count)].prefix(1)).uppercased() as NSString).draw(at: NSPoint(x: av.minX + 10, y: av.minY + 7), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: NSColor.white])
            }
            s.draw(with: bubble.insetBy(dx: 12, dy: 7), options: [.usesLineFragmentOrigin], attributes: [.font: font, .foregroundColor: mine ? NSColor.white : NSColor.labelColor])
            y -= 10
        }
    }
}
