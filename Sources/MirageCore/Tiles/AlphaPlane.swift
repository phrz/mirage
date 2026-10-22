import Foundation
import Compression

/// A tile's alpha as an 8-bit greyscale plane, zlib-compressed for `TileMessage.alphaMask` (a raw single-channel plane: the
/// cheapest lossless form for masks that are mostly flat with soft edges).
public enum AlphaPlane {
    public static func compress(_ plane: [UInt8]) -> Data? {
        guard !plane.isEmpty else { return nil }
        var out = [UInt8](repeating: 0, count: plane.count + 64)
        let n = plane.withUnsafeBufferPointer { src in compression_encode_buffer(&out, out.count, src.baseAddress!, plane.count, nil, COMPRESSION_ZLIB) }
        return n > 0 ? Data(out[0..<n]) : nil
    }
    public static func decompress(_ data: Data, count: Int) -> [UInt8]? {
        guard count > 0, !data.isEmpty else { return nil }
        var out = [UInt8](repeating: 0, count: count)
        let n = data.withUnsafeBytes { src in compression_decode_buffer(&out, count, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB) }
        return n == count ? out : nil
    }
    /// FNV-1a, to send a tile's mask only when it changed.
    public static func hash(_ plane: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in plane { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
