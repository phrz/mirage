// Offscreen 2x renders of the synthetic scenes in experiments/testbench/scenes.swift (AppKit drawing, no
// window server capture, nothing from the person's screen). Usage: render OUTDIR NAME[:dark][:seedN] ...
// Each view is hosted in a window that is never ordered in and drawn with cacheDisplay into a 2x bitmap.
import AppKit

@main enum Render {
    static func main() {
        _ = NSApplication.shared
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { print("usage: render OUTDIR NAME[:dark][:seedN] ..."); exit(2) }
        let out = URL(fileURLWithPath: args[0])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let size = NSSize(width: 1100, height: 750)
        for spec in args.dropFirst() {
            let parts = spec.split(separator: ":").map(String.init)
            let name = parts[0], dark = parts.contains("dark")
            let seed = parts.first { $0.hasPrefix("seed") }.flatMap { UInt64($0.dropFirst(4)) } ?? 1
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            NSApp.appearance = appearance
            guard let view = SceneFactory.make(name, size: size, seed: seed) else { print("unknown scene \(name)"); continue }
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
            w.appearance = appearance
            w.contentView = view
            view.layoutSubtreeIfNeeded()
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32) else { continue }
            rep.size = size
            appearance.performAsCurrentDrawingAppearance {
                // An opaque window background first: some scenes leave parts of the content view transparent.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor.windowBackgroundColor.setFill(); NSRect(origin: .zero, size: size).fill()
                NSGraphicsContext.restoreGraphicsState()
                view.cacheDisplay(in: view.bounds, to: rep)
            }
            let file = out.appendingPathComponent("r-" + parts.joined(separator: "-") + ".png")
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
            print(file.path)
        }
    }
}
