import Foundation

// MARK: - Datagram flow framing
//
// Every datagram starts with `datagramMagic` (0xD7) so the host can tell the flow from a
// stream, then one type byte.

public enum DatagramType: UInt8 {
    case ping = 0x01      // echoed verbatim by the host; see DatagramPing
    case video = 0x02     // one fragment of an encoded video frame; see VideoFragment
}

/// Header of a video fragment datagram (all big-endian):
/// magic(1) type(1) frameSeq(4) fragIndex(2) fragCount(2) flags(1) captureNanos(8) frameBytes(4)
/// captureSeq(4) inputSeq(8) region x,y,w,h (4×2)
/// `region` is the part of the native picture this frame updates (native stream pixels); the
/// encoded frame itself may be smaller (resolution ladder) and is scaled onto the region.
public struct VideoFragment: Equatable, Sendable {
    public static let headerSize = 43
    /// Whole datagram size we aim for; stays under the tailnet's 1280-byte MTU with QUIC overhead.
    public static let datagramSize = 1200
    public static let maxPayload = datagramSize - headerSize

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let keyframe = Flags(rawValue: 1 << 0)
        /// Payload begins with HEVC parameter sets (see `VideoFramePayload`).
        public static let parameterSets = Flags(rawValue: 1 << 1)
        /// Recovery point: references only frames the viewer acknowledged (LTR refresh) or is a keyframe.
        public static let recovery = Flags(rawValue: 1 << 2)
        /// Payload carries a tile mask for `region` (see `VideoFramePayload`): only masked tiles changed.
        public static let tileMask = Flags(rawValue: 1 << 3)
    }

    public var frameSeq: UInt32
    public var fragIndex: UInt16
    public var fragCount: UInt16
    public var flags: Flags
    public var captureNanos: UInt64      // host monotonic clock at capture
    public var frameBytes: UInt32        // total payload bytes of the frame
    public var captureSeq: UInt32        // host capture counter, shared with tile messages and the window list
    public var inputSeq: UInt64          // last client input reflected in these pixels
    public var region: PixelRect         // native-pixel rect this frame updates
    public var payload: Data

    public init(frameSeq: UInt32, fragIndex: UInt16, fragCount: UInt16, flags: Flags, captureNanos: UInt64, frameBytes: UInt32,
                captureSeq: UInt32 = 0, inputSeq: UInt64 = 0, region: PixelRect = .zero, payload: Data) {
        self.frameSeq = frameSeq; self.fragIndex = fragIndex; self.fragCount = fragCount
        self.flags = flags; self.captureNanos = captureNanos; self.frameBytes = frameBytes
        self.captureSeq = captureSeq; self.inputSeq = inputSeq; self.region = region; self.payload = payload
    }

    public func encode() -> Data {
        var d = Data(capacity: Self.headerSize + payload.count)
        d.append(datagramMagic); d.append(DatagramType.video.rawValue)
        d.appendBE(frameSeq); d.appendBE(fragIndex); d.appendBE(fragCount)
        d.append(flags.rawValue); d.appendBE(captureNanos); d.appendBE(frameBytes)
        d.appendBE(captureSeq); d.appendBE(inputSeq); region.write(to: &d)
        d.append(payload)
        return d
    }

    public static func decode(_ d: Data) -> VideoFragment? {
        guard d.count >= headerSize, d[d.startIndex] == datagramMagic, d[d.startIndex + 1] == DatagramType.video.rawValue else { return nil }
        var r = ByteReader(d, offset: 2)
        let seq: UInt32 = r.read(), idx: UInt16 = r.read(), cnt: UInt16 = r.read()
        let flags = Flags(rawValue: r.readByte())
        let cap: UInt64 = r.read(), total: UInt32 = r.read()
        let cseq: UInt32 = r.read(), iseq: UInt64 = r.read()
        guard let region = PixelRect.read(&r) else { return nil }
        guard cnt > 0, idx < cnt else { return nil }
        return VideoFragment(frameSeq: seq, fragIndex: idx, fragCount: cnt, flags: flags, captureNanos: cap, frameBytes: total,
                             captureSeq: cseq, inputSeq: iseq, region: region, payload: d.subdata(in: r.offset..<d.endIndex))
    }

    /// Splits a frame payload into datagrams.
    public static func fragments(frameSeq: UInt32, flags: Flags, captureNanos: UInt64, payload: Data, maxPayload: Int = maxPayload,
                                 captureSeq: UInt32 = 0, inputSeq: UInt64 = 0, region: PixelRect = .zero) -> [Data] {
        let count = max(1, (payload.count + maxPayload - 1) / maxPayload)
        precondition(count <= Int(UInt16.max))
        return (0..<count).map { i in
            let lo = payload.startIndex + i * maxPayload
            let hi = min(lo + maxPayload, payload.endIndex)
            return VideoFragment(frameSeq: frameSeq, fragIndex: UInt16(i), fragCount: UInt16(count), flags: flags,
                                 captureNanos: captureNanos, frameBytes: UInt32(payload.count),
                                 captureSeq: captureSeq, inputSeq: inputSeq, region: region, payload: payload.subdata(in: lo..<hi)).encode()
        }
    }
}

/// Frame payload layout. If `.parameterSets` is set: [u8 count][u16 len, bytes]*.
/// If `.tileMask` is set: [u16 len][bits], one bit per 64-px tile of `region` (row-major); the
/// client only takes masked tiles from the decoded picture, so crisp tiles elsewhere survive.
/// Then the HEVC sample data (4-byte length-prefixed NAL units, hvcC style).
public enum VideoFramePayload {
    public static func encode(parameterSets: [Data], tileMask: Data? = nil, sample: Data) -> Data {
        guard !parameterSets.isEmpty || tileMask != nil else { return sample }
        var d = Data(capacity: sample.count + 128 + (tileMask?.count ?? 0))
        if !parameterSets.isEmpty {
            d.append(UInt8(parameterSets.count))
            for ps in parameterSets { d.appendBE(UInt16(ps.count)); d.append(ps) }
        }
        if let m = tileMask { d.appendBE(UInt16(m.count)); d.append(m) }
        d.append(sample)
        return d
    }
    public static func decode(_ d: Data, hasParameterSets: Bool, hasTileMask: Bool = false) -> (parameterSets: [Data], tileMask: Data?, sample: Data)? {
        var r = ByteReader(d, offset: 0)
        var sets: [Data] = []
        if hasParameterSets {
            guard r.remaining >= 1 else { return nil }
            let n = Int(r.readByte())
            for _ in 0..<n {
                guard r.remaining >= 2 else { return nil }
                let len: UInt16 = r.read()
                guard r.remaining >= Int(len) else { return nil }
                sets.append(d.subdata(in: r.offset..<r.offset + Int(len))); r.offset += Int(len)
            }
        }
        var mask: Data? = nil
        if hasTileMask {
            guard r.remaining >= 2 else { return nil }
            let len: UInt16 = r.read()
            guard r.remaining >= Int(len) else { return nil }
            mask = d.subdata(in: r.offset..<r.offset + Int(len)); r.offset += Int(len)
        }
        return (sets, mask, d.subdata(in: r.offset..<d.endIndex))
    }
}

/// Row-major bit set over a region's 64-px tile grid.
public struct TileMask: Equatable, Sendable {
    public let cols: Int, rows: Int
    public var bits: Data
    public init(cols: Int, rows: Int) { self.cols = cols; self.rows = rows; bits = Data(repeating: 0, count: (cols * rows + 7) / 8) }
    public init?(cols: Int, rows: Int, bits: Data) {
        guard bits.count >= (cols * rows + 7) / 8 else { return nil }
        self.cols = cols; self.rows = rows; self.bits = bits
    }
    public static func grid(for region: PixelRect, tile: Int = 64) -> (cols: Int, rows: Int) {
        ((region.width + tile - 1) / tile, (region.height + tile - 1) / tile)
    }
    public subscript(col: Int, row: Int) -> Bool {
        get { let i = row * cols + col; return bits[bits.startIndex + i >> 3] & (1 << (i & 7)) != 0 }
        set { let i = row * cols + col; if newValue { bits[bits.startIndex + i >> 3] |= 1 << (i & 7) } else { bits[bits.startIndex + i >> 3] &= ~(1 << (i & 7)) } }
    }
    public var count: Int { bits.reduce(0) { $0 + $1.nonzeroBitCount } }
    public static func full(cols: Int, rows: Int) -> TileMask { var m = TileMask(cols: cols, rows: rows); for r in 0..<rows { for c in 0..<cols { m[c, r] = true } }; return m }
}

/// A reassembled frame ready for the decoder.
public struct VideoFrame: Sendable {
    public var seq: UInt32
    public var flags: VideoFragment.Flags
    public var captureNanos: UInt64
    public var firstFragmentNanos: UInt64   // receiver clock
    public var lastFragmentNanos: UInt64
    public var parameterSets: [Data]
    public var tileMask: Data?
    public var sample: Data
    public var bytes: Int
    public var fragments: Int
    public var captureSeq: UInt32
    public var inputSeq: UInt64
    public var region: PixelRect
}

/// Reassembles fragments into frames and reports frames that will never complete.
/// Not thread-safe; drive it from one queue.
public struct FrameAssembler {
    struct Partial {
        var flags: VideoFragment.Flags
        var captureNanos: UInt64
        var firstNanos: UInt64
        var lastNanos: UInt64
        var count: Int
        var total: Int
        var parts: [Data?]
        var received = 0
        var captureSeq: UInt32
        var inputSeq: UInt64
        var region: PixelRect
    }
    private var partials: [UInt32: Partial] = [:]
    private var highestCompleted: UInt32? = nil
    /// Frames older than this many sequence numbers behind the newest seen are given up.
    public var reorderWindow: UInt32 = 8
    /// A frame still incomplete after this long (receiver clock) is given up.
    public var timeoutNanos: UInt64 = 600_000_000

    public init() {}

    public enum Event {
        case completed(VideoFrame), lost(seq: UInt32)
        var seq: UInt32 { switch self { case .completed(let f): return f.seq; case .lost(let s): return s } }
    }

    public mutating func ingest(_ f: VideoFragment, now: UInt64 = Clock.nowNanos()) -> [Event] {
        var events: [Event] = []
        if let hc = highestCompleted, f.frameSeq <= hc {
            // Late fragment of an older frame: if it completes a partial we no longer need, retire it quietly.
            partials[f.frameSeq] = nil
            return []
        }
        var p = partials[f.frameSeq] ?? Partial(flags: f.flags, captureNanos: f.captureNanos, firstNanos: now, lastNanos: now,
                                                 count: Int(f.fragCount), total: Int(f.frameBytes), parts: Array(repeating: nil, count: Int(f.fragCount)),
                                                 captureSeq: f.captureSeq, inputSeq: f.inputSeq, region: f.region)
        guard Int(f.fragCount) == p.count, Int(f.fragIndex) < p.count else { return [] }
        if p.parts[Int(f.fragIndex)] == nil { p.parts[Int(f.fragIndex)] = f.payload; p.received += 1 }
        p.lastNanos = now
        if p.received == p.count {
            partials[f.frameSeq] = nil
            var sample = Data(capacity: p.total)
            for part in p.parts { sample.append(part!) }
            let decoded = VideoFramePayload.decode(sample, hasParameterSets: f.flags.contains(.parameterSets), hasTileMask: f.flags.contains(.tileMask))
            // Older partials are not declared lost yet: a reordered last fragment may still arrive
            // within the window/timeout below. Their late completion is then dropped (seq <= highestCompleted).
            if highestCompleted.map({ f.frameSeq > $0 }) ?? true { highestCompleted = f.frameSeq }
            if let decoded {
                events.append(.completed(VideoFrame(seq: f.frameSeq, flags: p.flags, captureNanos: p.captureNanos, firstFragmentNanos: p.firstNanos,
                                                     lastFragmentNanos: now, parameterSets: decoded.parameterSets, tileMask: decoded.tileMask, sample: decoded.sample, bytes: sample.count,
                                                     fragments: p.count, captureSeq: p.captureSeq, inputSeq: p.inputSeq, region: p.region)))
            } else {
                events.append(.lost(seq: f.frameSeq))
            }
        } else {
            partials[f.frameSeq] = p
        }
        // Give up on stragglers: too far behind the newest frame, or too old.
        for seq in partials.keys.sorted() {
            guard let part = partials[seq], seq + reorderWindow < f.frameSeq || now - part.firstNanos > timeoutNanos else { continue }
            partials[seq] = nil; events.append(.lost(seq: seq))
        }
        return events.sorted { a, b in a.seq < b.seq }
    }

    public var pendingCount: Int { partials.count }
}

// MARK: - Byte helpers

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ v: T) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}

struct ByteReader {
    let data: Data
    var offset: Data.Index
    init(_ d: Data, offset: Int) { data = d; self.offset = d.startIndex + offset }
    var remaining: Int { data.endIndex - offset }
    mutating func read<T: FixedWidthInteger>() -> T {
        let size = MemoryLayout<T>.size
        let v = data.subdata(in: offset..<offset + size).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        offset += size
        return T(bigEndian: v)
    }
    mutating func readByte() -> UInt8 { let b = data[offset]; offset += 1; return b }
}
