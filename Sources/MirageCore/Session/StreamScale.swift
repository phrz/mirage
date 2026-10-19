import Foundation

/// Native-scale snap (M3.2): at any stream scale other than the display's own pixels a scroll or a window move is a
/// fractional pixel shift (mac-daddy at 3022 px for 3200 native: a 30 pt scroll is 56.7 px), so copy-rects cannot be
/// exact and window layers must be rescaled. Within 15 % of native the stream is taken at native, 1:1; never at another
/// fraction (only 1:1 keeps every shift whole-pixel).
public enum StreamScale {
    public static let snapTolerance = 0.15
    public static func snapsToNative(requestedWidth: Double, nativeWidth: Double) -> Bool {
        guard nativeWidth > 0, requestedWidth > 0 else { return false }
        return abs(requestedWidth / nativeWidth - 1) <= snapTolerance
    }
}
