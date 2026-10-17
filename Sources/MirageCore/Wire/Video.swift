import Foundation

// MARK: - Datagram flow framing
//
// Every datagram starts with `datagramMagic` (0xD7) so the host can tell the flow from a
// stream, then one type byte.

public enum DatagramType: UInt8 {
    case ping = 0x01      // echoed verbatim by the host; see DatagramPing
    case video = 0x02     // one fragment of an encoded video frame; see VideoFragment
    case parity = 0x03    // XOR parity over a group of a frame's fragments; see ParityFragment
}

/// XOR parity datagram: magic(1) type(1) frameSeq(4) groupIndex(2) groupSize(2) firstIndex(2) then
/// the XOR of the group's fragment payloads, each zero-padded to the longest. Recovers one lost
/// fragment per group without a round trip (DESIGN review §2.3). Sent on key/recovery frames
/// always, on other frames when measured loss is high.
public struct ParityFragment: Equatable, Sendable {
    public static let headerSize = 12
    public var frameSeq: UInt32
    public var groupIndex: UInt16
    public var groupSize: UInt16
    public var firstIndex: UInt16
    public var payload: Data

    public init(frameSeq: UInt32, groupIndex: UInt16, groupSize: UInt16, firstIndex: UInt16, payload: Data) {
        self.frameSeq = frameSeq; self.groupIndex = groupIndex; self.groupSize = groupSize; self.firstIndex = firstIndex; self.payload = payload
    }

    public func encode() -> Data {
        var d = Data(capacity: Self.headerSize + payload.count)
        d.append(datagramMagic); d.append(DatagramType.parity.rawValue)
        d.appendBE(frameSeq); d.appendBE(groupIndex); d.appendBE(groupSize); d.appendBE(firstIndex)
        d.append(payload)
        return d
    }

    public static func decode(_ d: Data) -> ParityFragment? {
        guard d.count >= headerSize, d[d.startIndex] == datagramMagic, d[d.startIndex + 1] == DatagramType.parity.rawValue else { return nil }
        var r = ByteReader(d, offset: 2)
        let seq: UInt32 = r.read(), g: UInt16 = r.read(), n: UInt16 = r.read(), f: UInt16 = r.read()
        guard n > 0 else { return nil }
        return ParityFragment(frameSeq: seq, groupIndex: g, groupSize: n, firstIndex: f, payload: d.subdata(in: r.offset..<d.endIndex))
    }

    /// XOR of the payloads (zero-padded).
    public static func xor(_ parts: [Data]) -> Data {
        let n = parts.map(\.count).max() ?? 0
        var out = [UInt8](repeating: 0, count: n)
        for p in parts { p.withUnsafeBytes { b in for i in 0..<p.count { out[i] ^= b[i] } } }
        return Data(out)
    }

    /// Parity datagrams for a frame's fragment payloads, one per group of `groupSize`.
    public static func parity(frameSeq: UInt32, payloads: [Data], groupSize: Int = 8) -> [Data] {
        guard payloads.count >= 2 else { return [] }
        var out: [Data] = []
        var g = 0, i = 0
        while i < payloads.count {
            let slice = Array(payloads[i..<min(payloads.count, i + groupSize)])
            out.append(ParityFragment(frameSeq: frameSeq, groupIndex: UInt16(g), groupSize: UInt16(slice.count), firstIndex: UInt16(i), payload: xor(slice)).encode())
            i += slice.count; g += 1
        }
        return out
    }
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
        /// A progressive-refinement step of a fresh picture (ladder climb): the client crossfades it in.
        public static let progressive = Flags(rawValue: 1 << 4)
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

/// Reassembles fragments into frames, delivers them strictly in sequence order (a frame with a
/// hole holds the frames after it, which are P-frames that reference it), asks for missing
/// fragments by NACK after a short gap, reconstructs single losses from parity, and gives a frame
/// up only after a timeout sized from the RTT. Not thread-safe; drive it from one queue.
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
        var nacks = 0
        var lastNackNanos: UInt64 = 0
        var complete: Bool { received == count }
        var parity: [UInt16: ParityFragment] = [:]   // by group index
    }
    private var partials: [UInt32: Partial] = [:]
    /// Highest sequence delivered (completed or lost); nothing at or below it is delivered again.
    private var delivered: UInt32? = nil
    /// A frame still incomplete after this long (receiver clock) is given up; the viewer sets it from the RTT.
    public var timeoutNanos: UInt64 = 600_000_000
    /// Missing fragments are asked for this long after the frame's last fragment arrived.
    public var nackAfterNanos: UInt64 = 30_000_000
    public var maxNacks = 2
    /// NACKs are repeated no sooner than this (the viewer sets it to ~1 RTT).
    public var nackRepeatNanos: UInt64 = 250_000_000
    public private(set) var recoveredByParity = 0
    public private(set) var recoveredByNack = 0

    public init() {}

    public enum Event {
        case completed(VideoFrame), lost(seq: UInt32)
        /// Ask the host to resend these fragments.
        case nack(seq: UInt32, fragments: [Int])
        var seq: UInt32 { switch self { case .completed(let f): return f.seq; case .lost(let s): return s; case .nack(let s, _): return s } }
    }

    public mutating func ingest(_ f: VideoFragment, now: UInt64 = Clock.nowNanos()) -> [Event] {
        if let d = delivered, f.frameSeq <= d { return [] }
        var p = partials[f.frameSeq] ?? Partial(flags: f.flags, captureNanos: f.captureNanos, firstNanos: now, lastNanos: now,
                                                 count: Int(f.fragCount), total: Int(f.frameBytes), parts: Array(repeating: nil, count: Int(f.fragCount)),
                                                 captureSeq: f.captureSeq, inputSeq: f.inputSeq, region: f.region)
        guard Int(f.fragCount) == p.count, Int(f.fragIndex) < p.count else { return [] }
        if p.parts[Int(f.fragIndex)] == nil {
            p.parts[Int(f.fragIndex)] = f.payload; p.received += 1
            if p.nacks > 0 { recoveredByNack += 1 }
        }
        p.lastNanos = now
        partials[f.frameSeq] = p
        tryParity(f.frameSeq)
        return drain(now: now)
    }

    public mutating func ingest(parity pf: ParityFragment, now: UInt64 = Clock.nowNanos()) -> [Event] {
        if let d = delivered, pf.frameSeq <= d { return [] }
        guard var p = partials[pf.frameSeq] else {
            // Parity before any fragment: keep it in a placeholder sized later.
            partials[pf.frameSeq] = Partial(flags: [], captureNanos: 0, firstNanos: now, lastNanos: now, count: 0, total: 0, parts: [], captureSeq: 0, inputSeq: 0, region: .zero, parity: [pf.groupIndex: pf])
            return []
        }
        p.parity[pf.groupIndex] = pf
        partials[pf.frameSeq] = p
        tryParity(pf.frameSeq)
        return drain(now: now)
    }

    /// Reconstructs a single missing fragment in any group that has its parity.
    private mutating func tryParity(_ seq: UInt32) {
        guard var p = partials[seq], p.count > 0 else { return }
        for (_, pf) in p.parity {
            let lo = Int(pf.firstIndex), hi = min(p.count, lo + Int(pf.groupSize))
            guard lo < hi else { continue }
            let missing = (lo..<hi).filter { p.parts[$0] == nil }
            guard missing.count == 1 else { continue }
            var acc = [UInt8](pf.payload)
            for i in lo..<hi where i != missing[0] { p.parts[i]!.withUnsafeBytes { b in for j in 0..<min(b.count, acc.count) { acc[j] ^= b[j] } } }
            // The missing fragment's length: every fragment but the last is maxPayload-sized; the last takes the remainder.
            let known = (lo..<hi).filter { $0 != missing[0] }.compactMap { p.parts[$0] }
            let full = known.map(\.count).max() ?? acc.count
            let isLast = missing[0] == p.count - 1
            let len = isLast ? p.total - (p.count - 1) * full : full
            guard len > 0, len <= acc.count else { continue }
            p.parts[missing[0]] = Data(acc[0..<len]); p.received += 1; recoveredByParity += 1
        }
        partials[seq] = p
    }

    /// Delivers in order: complete frames at the head go out; a frame with a hole holds everything
    /// behind it until it completes, is NACKed, or times out.
    private mutating func drain(now: UInt64) -> [Event] {
        var events: [Event] = []
        while let seq = partials.keys.min() {
            guard var p = partials[seq] else { break }
            if p.count > 0, p.complete {
                partials[seq] = nil
                var sample = Data(capacity: p.total)
                for part in p.parts { sample.append(part!) }
                let decoded = VideoFramePayload.decode(sample, hasParameterSets: p.flags.contains(.parameterSets), hasTileMask: p.flags.contains(.tileMask))
                delivered = seq
                if let decoded {
                    events.append(.completed(VideoFrame(seq: seq, flags: p.flags, captureNanos: p.captureNanos, firstFragmentNanos: p.firstNanos,
                                                         lastFragmentNanos: p.lastNanos, parameterSets: decoded.parameterSets, tileMask: decoded.tileMask, sample: decoded.sample, bytes: sample.count,
                                                         fragments: p.count, captureSeq: p.captureSeq, inputSeq: p.inputSeq, region: p.region)))
                } else {
                    events.append(.lost(seq: seq))
                }
                continue
            }
            if now - p.firstNanos > timeoutNanos || (p.count == 0 && now - p.firstNanos > timeoutNanos) {
                partials[seq] = nil; delivered = seq; events.append(.lost(seq: seq)); continue
            }
            // Head of line has a hole: ask for the missing fragments once the gap is older than a reorder.
            if p.count > 0, p.nacks < maxNacks, now - p.lastNanos > nackAfterNanos, now - p.lastNackNanos > nackRepeatNanos {
                p.nacks += 1; p.lastNackNanos = now; partials[seq] = p
                events.append(.nack(seq: seq, fragments: (0..<p.count).filter { p.parts[$0] == nil }))
            }
            break
        }
        return events
    }

    /// Time-driven pass (call from a timer): NACKs and timeouts even when nothing arrives.
    public mutating func tick(now: UInt64) -> [Event] { drain(now: now) }

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
