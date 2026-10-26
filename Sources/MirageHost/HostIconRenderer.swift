import AppKit
import MirageCore

/// This Mac's own icon for the viewers' device lists (phrz, 2026-10-26): `NSImage.computerName`, the picture Finder and
/// About This Mac show for it (its model and colour), drawn at 128 and 256 px as PNG, once per start.
public enum HostIconRenderer {
    public static func make() -> HostIcon? {
        guard let image = NSImage(named: NSImage.computerName),
              let small = png(image, pixels: 128) else { return nil }
        return HostIcon.make(png128: small, png256: png(image, pixels: 256))
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
