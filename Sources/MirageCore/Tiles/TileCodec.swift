import Foundation
import CWebP

/// WebP lossless / near-lossless codec for tile rects of BGRA pixels (libwebp, vendored).
/// Measured (experiments/tilebench): ~550–800 B per 64² text tile lossless, 2x smaller than
/// anything in Apple's Compression framework on UI content.
public enum TileCodec {
    public enum Format: UInt8, Sendable {
        case lossless = 0
        /// `near_lossless` 60: identical bytes on text, ~20 % smaller on photographic tiles.
        case nearLossless = 1
    }

    /// Encodes a `width`×`height` BGRA rect starting at `base` with `stride` bytes per row.
    /// Alpha is ignored (imported as BGRX). `effort` 0 (fastest) … 9.
    public static func encode(base: UnsafeRawPointer, width: Int, height: Int, stride: Int, format: Format, effort: Int = 2) -> Data? {
        var config = WebPConfig()
        // The lossless preset only sets lossless/method/quality; the rest needs WebPConfigInit first.
        guard WebPConfigInit(&config) != 0, WebPConfigLosslessPreset(&config, Int32(effort)) != 0 else { return nil }
        config.lossless = 1
        config.exact = 0
        config.thread_level = 0
        if format == .nearLossless { config.near_lossless = 60 }
        var pic = WebPPicture()
        guard WebPPictureInit(&pic) != 0 else { return nil }
        defer { WebPPictureFree(&pic) }
        pic.use_argb = 1
        pic.width = Int32(width); pic.height = Int32(height)
        guard WebPPictureImportBGRX(&pic, base.assumingMemoryBound(to: UInt8.self), Int32(stride)) != 0 else { return nil }
        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        pic.writer = WebPMemoryWrite
        return withUnsafeMutablePointer(to: &writer) { w -> Data? in
            pic.custom_ptr = UnsafeMutableRawPointer(w)
            guard WebPEncode(&config, &pic) != 0 else { return nil }
            return Data(bytes: w.pointee.mem, count: w.pointee.size)
        }
    }

    /// Reads the dimensions of an encoded tile.
    public static func size(of data: Data) -> (width: Int, height: Int)? {
        var w: Int32 = 0, h: Int32 = 0
        let ok = data.withUnsafeBytes { WebPGetInfo($0.bindMemory(to: UInt8.self).baseAddress, data.count, &w, &h) }
        return ok != 0 ? (Int(w), Int(h)) : nil
    }

    /// Decodes into a BGRA buffer (`stride` bytes per row, at least width×4). Returns false on failure.
    @discardableResult
    public static func decode(_ data: Data, into dst: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int) -> Bool {
        data.withUnsafeBytes { src in
            WebPDecodeBGRAInto(src.bindMemory(to: UInt8.self).baseAddress, data.count, dst.assumingMemoryBound(to: UInt8.self), stride * height, Int32(stride)) != nil
        }
    }

    /// Counts distinct colours in a rect, stopping early once `limit` is exceeded; drives the near-lossless choice.
    public static func colourCount(base: UnsafeRawPointer, width: Int, height: Int, stride: Int, limit: Int = 256) -> Int {
        var seen = Set<UInt32>()
        seen.reserveCapacity(limit + 1)
        for y in 0..<height {
            let row = base.advanced(by: y * stride)
            for x in 0..<width {
                seen.insert(row.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self) & 0x00FF_FFFF)
                if seen.count > limit { return seen.count }
            }
        }
        return seen.count
    }
}
