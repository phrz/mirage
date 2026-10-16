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
public struct VideoFragment: Equatable, Sendable {
    public static let headerSize = 23
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
    }

    public var frameSeq: UInt32
    public var fragIndex: UInt16
    public var fragCount: UInt16
    public var flags: Flags
    public var captureNanos: UInt64      // host monotonic clock at capture
    public var frameBytes: UInt32        // total payload bytes of the frame
    public var payload: Data

    public init(frameSeq: UInt32, fragIndex: UInt16, fragCount: UInt16, flags: Flags, captureNanos: UInt64, frameBytes: UInt32, payload: Data) {
        self.frameSeq = frameSeq; self.fragIndex = fragIndex; self.fragCount = fragCount
        self.flags = flags; self.captureNanos = captureNanos; self.frameBytes = frameBytes; self.payload = payload
    }

    public func encode() -> Data {
        var d = Data(capacity: Self.headerSize + payload.count)
        d.append(datagramMagic); d.append(DatagramType.video.rawValue)
        d.appendBE(frameSeq); d.appendBE(fragIndex); d.appendBE(fragCount)
        d.append(flags.rawValue); d.appendBE(captureNanos); d.appendBE(frameBytes)
        d.append(payload)
        return d
    }

    public static func decode(_ d: Data) -> VideoFragment? {
        guard d.count >= headerSize, d[d.startIndex] == datagramMagic, d[d.startIndex + 1] == DatagramType.video.rawValue else { return nil }
        var r = ByteReader(d, offset: 2)
        let seq: UInt32 = r.read(), idx: UInt16 = r.read(), cnt: UInt16 = r.read()
        let flags = Flags(rawValue: r.readByte())
        let cap: UInt64 = r.read(), total: UInt32 = r.read()
        guard cnt > 0, idx < cnt else { return nil }
        return VideoFragment(frameSeq: seq, fragIndex: idx, fragCount: cnt, flags: flags, captureNanos: cap, frameBytes: total, payload: d.subdata(in: r.offset..<d.endIndex))
    }

    /// Splits a frame payload into datagrams.
    public static func fragments(frameSeq: UInt32, flags: Flags, captureNanos: UInt64, payload: Data, maxPayload: Int = maxPayload) -> [Data] {
        let count = max(1, (payload.count + maxPayload - 1) / maxPayload)
        precondition(count <= Int(UInt16.max))
        return (0..<count).map { i in
            let lo = payload.startIndex + i * maxPayload
            let hi = min(lo + maxPayload, payload.endIndex)
            return VideoFragment(frameSeq: frameSeq, fragIndex: UInt16(i), fragCount: UInt16(count), flags: flags,
                                 captureNanos: captureNanos, frameBytes: UInt32(payload.count), payload: payload.subdata(in: lo..<hi)).encode()
        }
    }
}

/// Frame payload layout. If `.parameterSets` is set:
/// [u8 count][u16 len, bytes]* then the HEVC sample data (4-byte length-prefixed NAL units, hvcC style).
public enum VideoFramePayload {
    public static func encode(parameterSets: [Data], sample: Data) -> Data {
        guard !parameterSets.isEmpty else { return sample }
        var d = Data(capacity: sample.count + 128)
        d.append(UInt8(parameterSets.count))
        for ps in parameterSets { d.appendBE(UInt16(ps.count)); d.append(ps) }
        d.append(sample)
        return d
    }
    public static func decode(_ d: Data, hasParameterSets: Bool) -> (parameterSets: [Data], sample: Data)? {
        guard hasParameterSets else { return ([], d) }
        guard d.count >= 1 else { return nil }
        var r = ByteReader(d, offset: 0)
        let n = Int(r.readByte())
        var sets: [Data] = []
        for _ in 0..<n {
            guard r.remaining >= 2 else { return nil }
            let len: UInt16 = r.read()
            guard r.remaining >= Int(len) else { return nil }
            sets.append(d.subdata(in: r.offset..<r.offset + Int(len))); r.offset += Int(len)
        }
        return (sets, d.subdata(in: r.offset..<d.endIndex))
    }
}

/// A reassembled frame ready for the decoder.
public struct VideoFrame: Sendable {
    public var seq: UInt32
    public var flags: VideoFragment.Flags
    public var captureNanos: UInt64
    public var firstFragmentNanos: UInt64   // receiver clock
    public var lastFragmentNanos: UInt64
    public var parameterSets: [Data]
    public var sample: Data
    public var bytes: Int
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
                                                 count: Int(f.fragCount), total: Int(f.frameBytes), parts: Array(repeating: nil, count: Int(f.fragCount)))
        guard Int(f.fragCount) == p.count, Int(f.fragIndex) < p.count else { return [] }
        if p.parts[Int(f.fragIndex)] == nil { p.parts[Int(f.fragIndex)] = f.payload; p.received += 1 }
        p.lastNanos = now
        if p.received == p.count {
            partials[f.frameSeq] = nil
            var sample = Data(capacity: p.total)
            for part in p.parts { sample.append(part!) }
            let decoded = VideoFramePayload.decode(sample, hasParameterSets: f.flags.contains(.parameterSets))
            // Older partials are not declared lost yet: a reordered last fragment may still arrive
            // within the window/timeout below. Their late completion is then dropped (seq <= highestCompleted).
            if highestCompleted.map({ f.frameSeq > $0 }) ?? true { highestCompleted = f.frameSeq }
            if let decoded {
                events.append(.completed(VideoFrame(seq: f.frameSeq, flags: p.flags, captureNanos: p.captureNanos, firstFragmentNanos: p.firstNanos,
                                                     lastFragmentNanos: now, parameterSets: decoded.parameterSets, sample: decoded.sample, bytes: sample.count)))
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
