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

    /// A request box no display exceeds: the host fits the display's aspect into it and never goes past native pixels,
    /// so this asks for the display's own pixels whatever their size, from any host version. The iOS viewer streams at
    /// native this way (zoom up to 1:1 is sharp, fit shows it downscaled), and its stream size depends neither on the
    /// device's orientation nor on the keyboard: rotating never reconfigures the stream.
    public static let nativeRequest = (width: 16_384, height: 16_384)

    /// The stream size the host resolves a request to (ScreenCapturer.resolve): the display's aspect fitted into the
    /// requested box, never beyond native pixels, snapped to native when asked and within the tolerance; even sizes.
    public static func resolve(requested: (width: Int, height: Int), nativePixels: (width: Double, height: Double), snapNative: Bool) -> (width: Int, height: Int) {
        let pw = nativePixels.width, ph = nativePixels.height
        let aspect = pw / ph
        var w = Double(max(requested.width, 64)), h = Double(max(requested.height, 64))
        if w / h > aspect { w = h * aspect } else { h = w / aspect }
        w = min(w, pw); h = min(h, ph)   // never upscale beyond native pixels
        if snapNative, snapsToNative(requestedWidth: w, nativeWidth: pw) { w = pw; h = ph }
        return (Int(w) & ~1, Int(h) & ~1)
    }
}
