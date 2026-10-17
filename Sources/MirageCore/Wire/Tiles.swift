import Foundation

/// First byte a client sends on the reliable *tile* stream so the host can tell it from the
/// control stream (JSON frames start with a length byte < 0x10) and the datagram flow (0xD7).
public let tileStreamMagic: UInt8 = 0xD8
/// Second reliable stream for *interactive* tiles (changed pixels, copy-rects): nothing queued on the
/// refinement stream can delay them.
public let fastTileStreamMagic: UInt8 = 0xD9

/// A rect in native stream pixels (the size in `StreamInfo`), top-left origin.
public struct PixelRect: Equatable, Hashable, Sendable, Codable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
    public static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public func contains(_ px: Int, _ py: Int) -> Bool { px >= x && py >= y && px < maxX && py < maxY }
    public func intersection(_ o: PixelRect) -> PixelRect {
        let x0 = max(x, o.x), y0 = max(y, o.y), x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        return x1 > x0 && y1 > y0 ? PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : .zero
    }
    public func union(_ o: PixelRect) -> PixelRect {
        if isEmpty { return o }; if o.isEmpty { return self }
        let x0 = min(x, o.x), y0 = min(y, o.y), x1 = max(maxX, o.maxX), y1 = max(maxY, o.maxY)
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    public func intersects(_ o: PixelRect) -> Bool { !intersection(o).isEmpty }
    public func offset(_ dx: Int, _ dy: Int) -> PixelRect { PixelRect(x: x + dx, y: y + dy, width: width, height: height) }
    public var area: Int { max(0, width) * max(0, height) }
}

/// Messages on the tile stream, host → client. Framing: [type u8][msgSeq u32][length u32][body].
/// Every message carries the host's capture sequence (shared with video frames, for ordering
/// against the window list) and the last input sequence reflected in those pixels (for the
/// client's prediction reconciliation, DESIGN §3.5).
public enum TileMessage: Equatable, Sendable {
    /// Lossless (or near-lossless) rects that replace the client's pixels.
    case tiles(Tiles)
    /// "Move the pixels of `rect` by (dx, dy)": scroll or window drag detected on the host.
    case copyRect(CopyRect)
    /// Native size changed; the client clears its canvas.
    case reset(width: Int, height: Int)

    public struct Header: Equatable, Sendable {
        public var captureSeq: UInt32
        public var inputSeq: UInt64
        public var windowID: UInt32      // 0 = none / unknown
        public var captureNanos: UInt64  // host clock
        public init(captureSeq: UInt32, inputSeq: UInt64, windowID: UInt32, captureNanos: UInt64) {
            self.captureSeq = captureSeq; self.inputSeq = inputSeq; self.windowID = windowID; self.captureNanos = captureNanos
        }
    }
    public struct Tile: Equatable, Sendable {
        public var rect: PixelRect
        public var format: TileCodec.Format
        public var data: Data
        public init(rect: PixelRect, format: TileCodec.Format, data: Data) { self.rect = rect; self.format = format; self.data = data }
    }
    public struct Tiles: Equatable, Sendable {
        public var header: Header
        /// Why these tiles were sent, for the client's stats; refinement crossfades in on the client.
        public var refinement: Bool
        public var tiles: [Tile]
        public init(header: Header, refinement: Bool, tiles: [Tile]) { self.header = header; self.refinement = refinement; self.tiles = tiles }
        public var bytes: Int { tiles.reduce(0) { $0 + $1.data.count } }
    }
    public struct CopyRect: Equatable, Sendable {
        public var header: Header
        public var rect: PixelRect   // source rect; destination is rect.offset(dx, dy)
        public var dx: Int, dy: Int
        public init(header: Header, rect: PixelRect, dx: Int, dy: Int) { self.header = header; self.rect = rect; self.dx = dx; self.dy = dy }
    }

    enum Kind: UInt8 { case tiles = 1, copyRect = 2, reset = 3 }
    /// Tiles dropped because their format byte was unknown (diagnostics).
    nonisolated(unsafe) public static var skippedUnknownFormats = 0

    public func encode(msgSeq: UInt32) -> Data {
        var body = Data()
        let kind: Kind
        switch self {
        case .tiles(let t):
            kind = .tiles
            t.header.write(to: &body)
            body.append(t.refinement ? 1 : 0)
            body.appendBE(UInt16(t.tiles.count))
            for tile in t.tiles {
                tile.rect.write(to: &body)
                body.append(tile.format.rawValue)
                body.appendBE(UInt32(tile.data.count))
                body.append(tile.data)
            }
        case .copyRect(let c):
            kind = .copyRect
            c.header.write(to: &body)
            c.rect.write(to: &body)
            body.appendBE(Int16(c.dx)); body.appendBE(Int16(c.dy))
        case .reset(let w, let h):
            kind = .reset
            body.appendBE(UInt16(w)); body.appendBE(UInt16(h))
        }
        var d = Data(capacity: 9 + body.count)
        d.append(kind.rawValue); d.appendBE(msgSeq); d.appendBE(UInt32(body.count))
        d.append(body)
        return d
    }

    public static let headerSize = 9
    public static let maxLength = 8 << 20

    /// Parses one framed message; returns nil if the body is malformed.
    public static func decode(kind kindByte: UInt8, body: Data) -> TileMessage? {
        guard let kind = Kind(rawValue: kindByte) else { return nil }
        var r = ByteReader(body, offset: 0)
        switch kind {
        case .tiles:
            guard r.remaining >= 24 + 1 + 2, let h = Header.read(&r) else { return nil }
            let refinement = r.readByte() != 0
            let n: UInt16 = r.read()
            var tiles: [Tile] = []
            tiles.reserveCapacity(Int(n))
            for _ in 0..<n {
                guard r.remaining >= 8 + 1 + 4, let rect = PixelRect.read(&r) else { return nil }
                let formatByte = r.readByte()
                let len: UInt32 = r.read()
                guard r.remaining >= Int(len) else { return nil }
                // A format this build does not know (a newer host) is skipped, never fatal: the stream
                // must stay up and the ack must still go out.
                if let f = TileCodec.Format(rawValue: formatByte) {
                    tiles.append(Tile(rect: rect, format: f, data: body.subdata(in: r.offset..<r.offset + Int(len))))
                } else {
                    skippedUnknownFormats += 1
                }
                r.offset += Int(len)
            }
            return .tiles(Tiles(header: h, refinement: refinement, tiles: tiles))
        case .copyRect:
            guard r.remaining >= 24 + 8 + 4, let h = Header.read(&r), let rect = PixelRect.read(&r) else { return nil }
            let dx: Int16 = r.read(), dy: Int16 = r.read()
            return .copyRect(CopyRect(header: h, rect: rect, dx: Int(dx), dy: Int(dy)))
        case .reset:
            guard r.remaining >= 4 else { return nil }
            let w: UInt16 = r.read(), h: UInt16 = r.read()
            return .reset(width: Int(w), height: Int(h))
        }
    }
}

extension TileMessage.Header {
    func write(to d: inout Data) { d.appendBE(captureSeq); d.appendBE(inputSeq); d.appendBE(windowID); d.appendBE(captureNanos) }
    static func read(_ r: inout ByteReader) -> TileMessage.Header? {
        guard r.remaining >= 24 else { return nil }
        let c: UInt32 = r.read(), i: UInt64 = r.read(), w: UInt32 = r.read(), n: UInt64 = r.read()
        return .init(captureSeq: c, inputSeq: i, windowID: w, captureNanos: n)
    }
}
extension PixelRect {
    func write(to d: inout Data) { d.appendBE(UInt16(clamping: x)); d.appendBE(UInt16(clamping: y)); d.appendBE(UInt16(clamping: width)); d.appendBE(UInt16(clamping: height)) }
    static func read(_ r: inout ByteReader) -> PixelRect? {
        guard r.remaining >= 8 else { return nil }
        let x: UInt16 = r.read(), y: UInt16 = r.read(), w: UInt16 = r.read(), h: UInt16 = r.read()
        return PixelRect(x: Int(x), y: Int(y), width: Int(w), height: Int(h))
    }
}

/// Incremental parser for the tile stream's byte stream.
public struct TileStreamParser {
    private var buffer = Data()
    public private(set) var skipped = 0
    public init() {}
    /// Feeds bytes; returns complete messages with their sequence numbers, in order.
    public mutating func feed(_ data: Data) throws -> [(seq: UInt32, bytes: Int, message: TileMessage)] {
        buffer.append(data)
        var out: [(UInt32, Int, TileMessage)] = []
        while buffer.count >= TileMessage.headerSize {
            var r = ByteReader(buffer, offset: 1)
            let seq: UInt32 = r.read(), len: UInt32 = r.read()
            guard Int(len) <= TileMessage.maxLength else { throw MirageError.protocolViolation("tile message length \(len)") }
            let total = TileMessage.headerSize + Int(len)
            guard buffer.count >= total else { break }
            let kind = buffer[buffer.startIndex]
            let body = buffer.subdata(in: buffer.startIndex + TileMessage.headerSize..<buffer.startIndex + total)
            buffer.removeFirst(total)
            // A message this build cannot decode (an unknown kind from a newer host) is skipped, not fatal.
            guard let m = TileMessage.decode(kind: kind, body: body) else { skipped += 1; continue }
            out.append((seq, total, m))
        }
        return out
    }
}
