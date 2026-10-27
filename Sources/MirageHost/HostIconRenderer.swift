import AppKit
import MirageCore

/// This Mac's own icon for the viewers' device lists (phrz, 2026-10-26): `NSImage.computerName`, the picture Finder and
/// About This Mac show for it (its model and colour), drawn at 128 and 256 px as PNG, once per start.
public enum HostIconRenderer {
    public static func make() -> HostIcon? { make(log: { _ in }) }

    /// Within the budget whatever the model's picture weighs: 128 and 256 px, else 128 alone, else smaller (a detailed,
    /// colourful icon can be heavier than a Mac Studio's). Says what it made, or why none (the host's log).
    public static func make(log: (String) -> Void) -> HostIcon? {
        guard let image = NSImage(named: NSImage.computerName) else { log("host icon: none (no computer image)"); return nil }
        return fit(small: { png(image, pixels: $0) }, big: png(image, pixels: 256), log: log)
    }

    /// The ladder, given how to draw a small one (tests: sizes of their choosing).
    static func fit(small: (Int) -> Data?, big: Data?, log: (String) -> Void) -> HostIcon? {
        for px in [128, 96, 64] {
            guard let s = small(px) else { continue }
            if let icon = HostIcon.make(png128: s, png256: px == 128 ? big : nil) {
                log("host icon: \(px) px \(s.count) bytes" + (icon.png256.map { ", 256 px \($0.count) bytes" } ?? "") + ", hash \(icon.hash.prefix(12))")
                return icon
            }
        }
        log("host icon: none (over \(HostIcon.budget) bytes even at 64 px)")
        return nil
    }

    static func png(_ image: NSImage, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
