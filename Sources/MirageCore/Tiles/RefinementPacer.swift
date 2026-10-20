import Foundation

/// When refinement may send (DESIGN §3.3 priority 4), kept apart from the streamer so the rules can be tested.
///
/// - Yield: refinement steps aside for 150 ms only when changed pixels are really using the link (their bytes in the
///   last 150 ms over a quarter of the tile budget for that time). It used to yield for 150 ms after any send of three
///   tiles or more: a desktop with a few animating windows sent that every ~100 ms and refinement never ran at all,
///   with the link idle (phrz on an iPhone, mac-daddy 2026-10-20: refine 0 kbps for minutes, Dock and menu bar soft).
/// - Blocks: large refinement items (stills, middle levels, lossless blocks) are pipelined: a new one may start while
///   the unacked ones total under ~0.5 s of the tile budget. One at a time, each waiting for its ack, spent a round trip
///   plus an encode per block idle: at 220 ms RTT refinement reached ~40 % of the target.
public struct RefinementPacer {
    public static let yieldWindowNanos: UInt64 = 150_000_000
    /// Share of the tile budget over the yield window that changed pixels must use for refinement to yield.
    public static let yieldShare = 0.25
    /// Unacked block bytes allowed, in seconds of the tile budget (and a block's own size: half of that).
    public static let blockWindowSeconds = 0.5
    public static let blockSeconds = 0.25
    /// A block whose ack never comes (a viewer that dropped the message) stops counting after ~3 RTT + 2 s.
    public static func blockTimeoutNanos(srttNanos: Double) -> UInt64 { UInt64(3 * srttNanos) + 2_000_000_000 }

    public struct Block: Equatable {
        public let id: Int
        public let layer: UInt32
        public var msgSeq: UInt32?
        public var startedNanos: UInt64
        public var bytes: Int
    }
    public private(set) var blocks: [Block] = []
    private var nextID = 0
    private var direct: [(nanos: UInt64, bytes: Int)] = []

    public init() {}

    // MARK: Yield

    /// Changed pixels (direct tiles, a backdrop level) went out: `bytes` charged to the tile budget.
    public mutating func noteDirect(bytes: Int, now: UInt64) {
        guard bytes > 0 else { return }
        direct.removeAll { now &- $0.nanos > Self.yieldWindowNanos }
        direct.append((now, bytes))
    }
    public func directBytes(now: UInt64) -> Int {
        direct.reduce(0) { now &- $1.nanos <= Self.yieldWindowNanos ? $0 + $1.bytes : $0 }
    }
    /// Whether refinement yields to changed pixels now.
    public func yields(now: UInt64, tileBytesPerSecond: Double) -> Bool {
        Double(directBytes(now: now)) > tileBytesPerSecond * Double(Self.yieldWindowNanos) / 1e9 * Self.yieldShare
    }

    // MARK: Blocks

    /// A block's area in pixels: ~0.25 s of the tile budget at ~0.5 B/px lossless (at least 240×135).
    public static func blockArea(tileBytesPerSecond: Double, layerArea: Int) -> Double {
        max(240.0 * 135.0, min(Double(layerArea), tileBytesPerSecond * blockSeconds / 0.5))
    }
    public var inFlightBytes: Int { blocks.reduce(0) { $0 + $1.bytes } }
    public var isIdle: Bool { blocks.isEmpty }
    /// Whether another block may start: under the window of unacked bytes (always when none is in flight).
    public func canStartBlock(tileBytesPerSecond: Double) -> Bool {
        blocks.isEmpty || Double(inFlightBytes) < tileBytesPerSecond * Self.blockWindowSeconds
    }
    /// Registers a block about to be encoded (its estimate until it is on the stream). Returns its id.
    public mutating func start(layer: UInt32, estimate: Int, now: UInt64) -> Int {
        nextID &+= 1
        blocks.append(Block(id: nextID, layer: layer, msgSeq: nil, startedNanos: now, bytes: estimate))
        return nextID
    }
    /// The block is on the tile stream as message `msgSeq`, `bytes` long.
    public mutating func sent(id: Int, msgSeq: UInt32, bytes: Int, now: UInt64) {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[i].msgSeq = msgSeq; blocks[i].bytes = bytes; blocks[i].startedNanos = now
    }
    /// The block was not sent after all (encode failed, went stale).
    public mutating func dropped(id: Int) { blocks.removeAll { $0.id == id } }
    /// The viewer acked message `msgSeq`. True if it was a block.
    @discardableResult
    public mutating func acked(msgSeq: UInt32) -> Bool {
        guard let i = blocks.firstIndex(where: { $0.msgSeq == msgSeq }) else { return false }
        blocks.remove(at: i)
        return true
    }
    /// Forgets blocks whose ack is overdue. Returns how many.
    @discardableResult
    public mutating func expire(now: UInt64, srttNanos: Double) -> Int {
        let n = blocks.count
        let limit = Self.blockTimeoutNanos(srttNanos: srttNanos)
        blocks.removeAll { now &- $0.startedNanos > limit }
        return n - blocks.count
    }
    public mutating func reset() { blocks = []; direct = [] }
}

/// The desktop's always-visible chrome in stream pixels: the menu bar and the Dock, from the screen's frame and the
/// part of it left to windows (NSScreen's visibleFrame). Refinement serves these first: they are on screen whatever the
/// windows do, and a connect showed them at the first picture's lowest rung for ~45 s.
public enum DesktopChrome {
    /// Insets in points (top: menu bar; bottom/left/right: the Dock where it sits, 0 when it hides).
    public static func bands(width: Int, height: Int, pxPerPoint: Double, top: Double, bottom: Double, left: Double, right: Double) -> [PixelRect] {
        var out: [PixelRect] = []
        func px(_ v: Double) -> Int { min(max(0, Int((v * pxPerPoint).rounded(.up))), max(width, height)) }
        if top > 0 { out.append(PixelRect(x: 0, y: 0, width: width, height: min(height, px(top)))) }
        if bottom > 0 { let h = min(height, px(bottom)); out.append(PixelRect(x: 0, y: height - h, width: width, height: h)) }
        if left > 0 { out.append(PixelRect(x: 0, y: 0, width: min(width, px(left)), height: height)) }
        if right > 0 { let w = min(width, px(right)); out.append(PixelRect(x: width - w, y: 0, width: w, height: height)) }
        return out.filter { !$0.isEmpty }
    }
}
