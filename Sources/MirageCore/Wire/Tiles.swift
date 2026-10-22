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
    /// This rect minus `o`: up to four disjoint rects (top band, bottom band, left and right of the overlap).
    public func subtracting(_ o: PixelRect) -> [PixelRect] {
        let i = intersection(o)
        guard !i.isEmpty else { return isEmpty ? [] : [self] }
        var out: [PixelRect] = []
        if i.y > y { out.append(PixelRect(x: x, y: y, width: width, height: i.y - y)) }
        if i.maxY < maxY { out.append(PixelRect(x: x, y: i.maxY, width: width, height: maxY - i.maxY)) }
        if i.x > x { out.append(PixelRect(x: x, y: i.y, width: i.x - x, height: i.height)) }
        if i.maxX < maxX { out.append(PixelRect(x: i.maxX, y: i.y, width: maxX - i.maxX, height: i.height)) }
        return out
    }
    /// This rect minus every rect in `others`.
    public func subtracting(_ others: [PixelRect]) -> [PixelRect] {
        others.reduce([self]) { pieces, o in pieces.flatMap { $0.subtracting(o) } }
    }
}

/// Messages on the tile stream, host → client. Framing: [type u8][msgSeq u32][length u32][body].
/// Every message carries the host's capture sequence (shared with video frames, for ordering
/// against the window list) and the last input sequence reflected in those pixels (for the
/// client's prediction reconciliation, DESIGN §3.5). Rects are in the coordinates of the message's
/// layer (`Header.windowID`): the display layer (0) or a window captured as its own layer (M3).
public enum TileMessage: Equatable, Sendable {
    /// Lossless (or near-lossless) rects that replace the client's pixels.
    case tiles(Tiles)
    /// "Move the pixels of `rect` by (dx, dy)": scroll or window drag detected on the host.
    case copyRect(CopyRect)
    /// A layer's pixel size (new layer, native size changed, window resized). Layer 0 is the display.
    case reset(layer: UInt32, width: Int, height: Int)
    /// Present the layer's staged level now (everything sent with `staged` since the last commit), in one
    /// crossfade (DESIGN §3.3: progressive whole-picture steps, never block by block).
    case commit(layer: UInt32)
    /// Several layers' commits as one transaction (stage 1's barrier): presented together, in the same pass, or not at all.
    /// Separate commits could arrive apart (a loss on one held the rest a round trip), showing the desktop's fill where
    /// windows are. Only to viewers whose request said `stageTransaction`.
    case commitSet(layers: [UInt32])
    /// A layer's alpha where it goes as video (HEVC has none): per 64-px tile of the layer, fully clear, fully opaque, or an
    /// 8-bit greyscale plane (zlib). Sent only where it changed, ahead of the video frame; the viewer keeps the latest per
    /// tile and applies it to every video frame written there (coordinator: single-channel greyscale, never colour; uniform
    /// tiles a flag). Only to viewers whose request said `alphaMask`.
    case alphaMask(layer: UInt32, tiles: [AlphaTile])
    /// TRUTH (DESIGN §3.0): the direct changes the host sent since the last frameEnd, up to capture `captureSeq`, are complete
    /// for these layers; the viewer shows them all at once. Only to viewers whose request said `transactionalVersion`.
    case frameEnd(captureSeq: UInt32, layers: [UInt32])

    public struct AlphaTile: Equatable, Sendable {
        public enum Kind: UInt8, Sendable { case clear = 0, opaque = 1, plane = 2 }
        public var col: UInt16, row: UInt16, kind: Kind
        /// For `.plane`: the tile's alpha bytes (its width x height, row-major), zlib-compressed (AlphaPlane).
        public var data: Data
        public init(col: UInt16, row: UInt16, kind: Kind, data: Data = Data()) { self.col = col; self.row = row; self.kind = kind; self.data = data }
    }

    public struct Header: Equatable, Sendable {
        public var captureSeq: UInt32
        public var inputSeq: UInt64
        /// Layer these pixels belong to: 0 = the display layer, else the window id of a layered window
        /// (then rects are relative to that window's top-left).
        public var windowID: UInt32
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
        /// Part of a layer's next presentation level: the client writes them off-screen and shows them only on
        /// the layer's `commit` (a lossless pass assembled whole, never block by block).
        public var staged: Bool
        /// Desktop pixels from the host's desktop-only capture (DesktopUnderlay): no window can be in them, so the viewer's
        /// guard lets them through under layered windows. Older viewers ignore the bit (and their guard drops the tiles).
        public var windowFree: Bool
        public var tiles: [Tile]
        public init(header: Header, refinement: Bool, staged: Bool = false, windowFree: Bool = false, tiles: [Tile]) {
            self.header = header; self.refinement = refinement; self.staged = staged; self.windowFree = windowFree; self.tiles = tiles
        }
        public var bytes: Int { tiles.reduce(0) { $0 + $1.data.count } }
    }
    public struct CopyRect: Equatable, Sendable {
        public var header: Header
        public var rect: PixelRect   // source rect; destination is rect.offset(dx, dy)
        public var dx: Int, dy: Int
        public init(header: Header, rect: PixelRect, dx: Int, dy: Int) { self.header = header; self.rect = rect; self.dx = dx; self.dy = dy }
    }

    enum Kind: UInt8 { case tiles = 1, copyRect = 2, reset = 3, commit = 4, commitSet = 5, alphaMask = 6, frameEnd = 7 }
    /// Tiles dropped because their format byte was unknown (diagnostics).
    nonisolated(unsafe) public static var skippedUnknownFormats = 0

    public func encode(msgSeq: UInt32) -> Data {
        var body = Data()
        let kind: Kind
        switch self {
        case .tiles(let t):
            kind = .tiles
            t.header.write(to: &body)
            body.append((t.refinement ? 1 : 0) | (t.staged ? 2 : 0) | (t.windowFree ? 4 : 0))
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
        case .reset(let layer, let w, let h):
            kind = .reset
            body.appendBE(layer); body.appendBE(UInt16(w)); body.appendBE(UInt16(h))
        case .commit(let layer):
            kind = .commit
            body.appendBE(layer)
        case .commitSet(let layers):
            kind = .commitSet
            body.appendBE(UInt16(layers.count)); for l in layers { body.appendBE(l) }
        case .frameEnd(let seq, let layers):
            kind = .frameEnd
            body.appendBE(seq); body.appendBE(UInt16(layers.count)); for l in layers { body.appendBE(l) }
        case .alphaMask(let layer, let tiles):
            kind = .alphaMask
            body.appendBE(layer); body.appendBE(UInt16(tiles.count))
            for t in tiles { body.appendBE(t.col); body.appendBE(t.row); body.append(t.kind.rawValue); body.appendBE(UInt32(t.data.count)); body.append(t.data) }
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
            let flags = r.readByte()
            let refinement = flags & 1 != 0, staged = flags & 2 != 0, windowFree = flags & 4 != 0
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
            return .tiles(Tiles(header: h, refinement: refinement, staged: staged, windowFree: windowFree, tiles: tiles))
        case .copyRect:
            guard r.remaining >= 24 + 8 + 4, let h = Header.read(&r), let rect = PixelRect.read(&r) else { return nil }
            let dx: Int16 = r.read(), dy: Int16 = r.read()
            return .copyRect(CopyRect(header: h, rect: rect, dx: Int(dx), dy: Int(dy)))
        case .reset:
            guard r.remaining >= 8 else { return nil }
            let layer: UInt32 = r.read(), w: UInt16 = r.read(), h: UInt16 = r.read()
            return .reset(layer: layer, width: Int(w), height: Int(h))
        case .commit:
            guard r.remaining >= 4 else { return nil }
            let layer: UInt32 = r.read()
            return .commit(layer: layer)
        case .commitSet:
            guard r.remaining >= 2 else { return nil }
            let n: UInt16 = r.read()
            guard r.remaining >= 4 * Int(n) else { return nil }
            return .commitSet(layers: (0..<Int(n)).map { _ in r.read() })
        case .frameEnd:
            guard r.remaining >= 6 else { return nil }
            let seq: UInt32 = r.read(), n: UInt16 = r.read()
            guard r.remaining >= 4 * Int(n) else { return nil }
            return .frameEnd(captureSeq: seq, layers: (0..<Int(n)).map { _ in r.read() })
        case .alphaMask:
            guard r.remaining >= 6 else { return nil }
            let layer: UInt32 = r.read(), n: UInt16 = r.read()
            var tiles: [AlphaTile] = []
            for _ in 0..<n {
                guard r.remaining >= 9 else { return nil }
                let col: UInt16 = r.read(), row: UInt16 = r.read()
                guard let k = AlphaTile.Kind(rawValue: r.readByte()) else { return nil }
                let len: UInt32 = r.read()
                guard r.remaining >= Int(len) else { return nil }
                tiles.append(AlphaTile(col: col, row: row, kind: k, data: body.subdata(in: r.offset..<r.offset + Int(len))))
                r.offset += Int(len)
            }
            return .alphaMask(layer: layer, tiles: tiles)
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
