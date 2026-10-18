import Foundation

// MARK: - Input on datagrams (DESIGN §3.9 item 6, §4a "input integrity")
//
// Input used to ride the reliable control stream: one lost packet stalled every later keystroke
// for a QUIC retransmission, and a 30 s outage left the user's typing in a stream buffer with
// no way to know what the host had seen. It now goes as datagrams with mosh-style redundancy:
// every outgoing packet carries the *latest pointer state* (absolute, idempotent, latest wins)
// and *every discrete event not yet acknowledged* (keys, buttons, scrolls, modifier changes),
// oldest first. The host applies each discrete event once, in sequence order, and answers each
// packet with the highest event and pointer sequence it has applied. Nothing is lost (the
// viewer keeps resending until acked), nothing is duplicated (sequence numbers), order holds
// (packets are cumulative and ascending), and a lost ack costs nothing but a repeat.

/// Input datagram, viewer → host:
/// magic(1) type(1)=input flags(1) pointerSeq(8) x(2) y(2) count(1) then `count` events:
/// seq(8) kind(1: low 7 bits kind, high bit scripted) body.
public struct InputPacket: Equatable {
    public struct Pointer: Equatable, Sendable {
        public var seq: UInt64
        public var x: Double, y: Double   // normalized to the streamed display
        public init(seq: UInt64, x: Double, y: Double) { self.seq = seq; self.x = x; self.y = y }
    }
    /// A discrete input event with its sequence number; `message` is one of key/mouseButton/scroll/modifiers.
    public struct Event: Equatable {
        public var seq: UInt64
        public var message: ControlMessage
        public init(seq: UInt64, message: ControlMessage) { self.seq = seq; self.message = message }
    }
    public var pointer: Pointer?
    public var events: [Event]
    public init(pointer: Pointer?, events: [Event]) { self.pointer = pointer; self.events = events }

    enum Kind: UInt8 { case key = 1, mouseButton = 2, scroll = 3, modifiers = 4 }
    static let flagPointer: UInt8 = 1
    public static let headerSize = 3

    public func encode() -> Data {
        var d = Data(capacity: 32 + events.count * 24)
        d.append(datagramMagic); d.append(DatagramType.input.rawValue)
        d.append(pointer == nil ? 0 : Self.flagPointer)
        if let p = pointer { d.appendBE(p.seq); d.appendBE(Self.q16(p.x)); d.appendBE(Self.q16(p.y)) }
        d.append(UInt8(min(255, events.count)))
        for e in events.prefix(255) {
            d.appendBE(e.seq)
            switch e.message {
            case .key(let k):
                d.append(Kind.key.rawValue | (k.scripted == true ? 0x80 : 0))
                d.appendBE(k.keyCode); d.append((k.down ? 1 : 0) | (k.isRepeat ? 2 : 0)); d.appendBE(k.modifiers)
                let chars = Data((k.characters ?? "").utf8).prefix(255)
                d.append(UInt8(chars.count)); d.append(chars)
            case .mouseButton(let m):
                d.append(Kind.mouseButton.rawValue | (m.scripted == true ? 0x80 : 0))
                d.append(UInt8(clamping: m.button)); d.append(m.down ? 1 : 0)
                d.appendBE(Self.q16(m.x)); d.appendBE(Self.q16(m.y)); d.append(UInt8(clamping: m.clickCount)); d.appendBE(m.modifiers)
            case .scroll(let s):
                d.append(Kind.scroll.rawValue | (s.scripted == true ? 0x80 : 0))
                d.appendBE(Self.q16(s.x)); d.appendBE(Self.q16(s.y))
                d.appendBE(Float32(s.dx).bitPattern); d.appendBE(Float32(s.dy).bitPattern)
                d.append(s.precise ? 1 : 0); d.appendBE(s.modifiers)
            case .modifiers(let m):
                d.append(Kind.modifiers.rawValue)
                d.appendBE(m.keyCode); d.appendBE(m.modifiers)
            default:
                // Not a discrete input event: encode as an empty modifiers change so the sequence stays dense.
                d.append(Kind.modifiers.rawValue); d.appendBE(UInt16(0)); d.appendBE(UInt64(0))
            }
        }
        return d
    }

    public static func decode(_ d: Data) -> InputPacket? {
        guard d.count >= headerSize, d[d.startIndex] == datagramMagic, d[d.startIndex + 1] == DatagramType.input.rawValue else { return nil }
        var r = ByteReader(d, offset: 2)
        let flags = r.readByte()
        var pointer: Pointer? = nil
        if flags & flagPointer != 0 {
            guard r.remaining >= 12 else { return nil }
            let seq: UInt64 = r.read(), x: UInt16 = r.read(), y: UInt16 = r.read()
            pointer = Pointer(seq: seq, x: dq16(x), y: dq16(y))
        }
        guard r.remaining >= 1 else { return nil }
        let n = Int(r.readByte())
        var events: [Event] = []
        events.reserveCapacity(n)
        for _ in 0..<n {
            guard r.remaining >= 9 else { return nil }
            let seq: UInt64 = r.read()
            let kb = r.readByte()
            let scripted: Bool? = kb & 0x80 != 0 ? true : nil
            guard let kind = Kind(rawValue: kb & 0x7f) else { return nil }
            switch kind {
            case .key:
                guard r.remaining >= 12 else { return nil }
                let code: UInt16 = r.read(); let f = r.readByte(); let mods: UInt64 = r.read()
                let len = Int(r.readByte()); guard r.remaining >= len else { return nil }
                let chars = len > 0 ? String(decoding: d[r.offset..<r.offset + len], as: UTF8.self) : nil
                r.offset += len
                events.append(Event(seq: seq, message: .key(.init(keyCode: code, down: f & 1 != 0, isRepeat: f & 2 != 0, modifiers: mods, characters: chars, seq: seq, scripted: scripted))))
            case .mouseButton:
                guard r.remaining >= 15 else { return nil }
                let b = Int(r.readByte()), down = r.readByte() != 0
                let x: UInt16 = r.read(), y: UInt16 = r.read(); let clicks = Int(r.readByte()); let mods: UInt64 = r.read()
                events.append(Event(seq: seq, message: .mouseButton(.init(button: b, down: down, x: dq16(x), y: dq16(y), clickCount: clicks, modifiers: mods, seq: seq, scripted: scripted))))
            case .scroll:
                guard r.remaining >= 21 else { return nil }
                let x: UInt16 = r.read(), y: UInt16 = r.read()
                let dx: UInt32 = r.read(), dy: UInt32 = r.read(); let precise = r.readByte() != 0; let mods: UInt64 = r.read()
                events.append(Event(seq: seq, message: .scroll(.init(x: dq16(x), y: dq16(y), dx: Double(Float32(bitPattern: dx)), dy: Double(Float32(bitPattern: dy)), precise: precise, modifiers: mods, seq: seq, scripted: scripted))))
            case .modifiers:
                guard r.remaining >= 10 else { return nil }
                let code: UInt16 = r.read(); let mods: UInt64 = r.read()
                events.append(Event(seq: seq, message: .modifiers(.init(keyCode: code, modifiers: mods, seq: seq))))
            }
        }
        return InputPacket(pointer: pointer, events: events)
    }

    /// Encoded size of one event (for packing to the datagram size).
    static func encodedSize(_ m: ControlMessage) -> Int {
        switch m {
        case .key(let k): return 9 + 2 + 1 + 8 + 1 + min(255, (k.characters ?? "").utf8.count)
        case .mouseButton: return 9 + 15
        case .scroll: return 9 + 21
        default: return 9 + 10
        }
    }

    static func q16(_ v: Double) -> UInt16 { UInt16(max(0, min(65535, (v * 65535).rounded()))) }
    static func dq16(_ v: UInt16) -> Double { Double(v) / 65535 }
}

/// Input acknowledgement, host → viewer: magic(1) type(1)=inputAck eventSeq(8) pointerSeq(8).
/// Every discrete event with seq ≤ eventSeq has been applied; the pointer state with pointerSeq was applied.
public struct InputAck: Equatable, Sendable {
    public var eventSeq: UInt64
    public var pointerSeq: UInt64
    public init(eventSeq: UInt64, pointerSeq: UInt64) { self.eventSeq = eventSeq; self.pointerSeq = pointerSeq }
    public func encode() -> Data {
        var d = Data(capacity: 18)
        d.append(datagramMagic); d.append(DatagramType.inputAck.rawValue); d.appendBE(eventSeq); d.appendBE(pointerSeq)
        return d
    }
    public static func decode(_ d: Data) -> InputAck? {
        guard d.count >= 18, d[d.startIndex] == datagramMagic, d[d.startIndex + 1] == DatagramType.inputAck.rawValue else { return nil }
        var r = ByteReader(d, offset: 2)
        return InputAck(eventSeq: r.read(), pointerSeq: r.read())
    }
}

/// Viewer side: assigns sequence numbers, keeps the unacked events and the latest pointer, builds
/// packets, retransmits on a timer with backoff, caps the queue, and after a long gap holds the
/// queue for the user's decision (flush or discard). Pure logic; the viewer drives it with its
/// clock and a send closure. Not thread-safe: the owner serializes calls.
public struct InputChannel {
    public struct Tuning: Sendable {
        /// Events kept while the host is not answering; beyond this, new discrete events are dropped (and counted).
        public var maxQueued = 512
        /// At most this many discrete events per packet (the datagram size bounds it too).
        public var maxEventsPerPacket = 48
        public var maxPacketBytes = 1200
        /// First retransmit after max(this, 1.2 × RTT); doubles every 4 unanswered retransmits up to `maxRetransmitNanos`.
        public var baseRetransmitNanos: UInt64 = 60_000_000
        public var maxRetransmitNanos: UInt64 = 10_000_000_000
        /// Discrete events unacked for this long put the channel on hold: the user chooses flush or discard.
        public var holdAfterNanos: UInt64 = 10_000_000_000
        public init() {}
    }
    public var tuning = Tuning()
    /// Scripted runs and headless measurements never hold; the queue flushes by itself when the path returns.
    public var autoFlush = false

    private var nextSeq: UInt64 = 0
    private var unacked: [InputPacket.Event] = []
    private var unackedSince: [UInt64] = []      // parallel to `unacked`: when each was enqueued
    private var pointer: InputPacket.Pointer? = nil
    private var ackedEventSeq: UInt64 = 0
    private var ackedPointerSeq: UInt64 = 0
    private var retransmits = 0
    private var nextRetransmitNanos: UInt64 = 0
    private var rttNanos: UInt64 = 100_000_000
    public private(set) var droppedByCap = 0
    public private(set) var packetsSent = 0
    public private(set) var held = false

    public init() {}

    public var queuedEvents: Int { unacked.count }
    public var lastSeq: UInt64 { nextSeq }
    public var lastSequence: UInt64 { nextSeq }
    /// Takes a sequence number for something that travels outside the input channel (a window command on
    /// the control stream): the host's window list reports it as applied like any input.
    public mutating func reserveSequence() -> UInt64 { nextSeq += 1; return nextSeq }
    /// Age of the oldest unacked discrete event, or 0.
    public func oldestUnackedNanos(now: UInt64) -> UInt64 { unackedSince.first.map { now &- $0 } ?? 0 }
    public mutating func setRTT(nanos: UInt64) { rttNanos = nanos }

    /// Assigns the next sequence number to a discrete event and queues it. Returns its sequence (0 = dropped by the cap).
    @discardableResult
    public mutating func enqueue(_ m: ControlMessage, now: UInt64) -> UInt64 {
        nextSeq += 1
        let seq = nextSeq
        guard unacked.count < tuning.maxQueued else { droppedByCap += 1; return 0 }
        var m = m
        switch m {
        case .key(var k): k.seq = seq; m = .key(k)
        case .mouseButton(var b): b.seq = seq; m = .mouseButton(b)
        case .scroll(var s): s.seq = seq; m = .scroll(s)
        case .modifiers(var mm): mm.seq = seq; m = .modifiers(mm)
        default: break
        }
        unacked.append(.init(seq: seq, message: m)); unackedSince.append(now)
        return seq
    }

    /// Latest pointer position; supersedes the previous one. Returns its sequence number.
    @discardableResult
    public mutating func pointer(x: Double, y: Double) -> UInt64 {
        nextSeq += 1
        pointer = .init(seq: nextSeq, x: x, y: y)
        return nextSeq
    }

    /// The packet to send now (nil if nothing is outstanding), and arms the retransmit timer.
    public mutating func packet(now: UInt64) -> Data? {
        let pointerPending = pointer.map { $0.seq > ackedPointerSeq } ?? false
        if unacked.isEmpty && !pointerPending { retransmits = 0; return nil }
        var events: [InputPacket.Event] = []
        if !held || autoFlush {
            var bytes = 16 + 8
            for e in unacked.prefix(tuning.maxEventsPerPacket) {
                bytes += InputPacket.encodedSize(e.message)
                if bytes > tuning.maxPacketBytes { break }
                events.append(e)
            }
        }
        packetsSent += 1
        let interval = min(tuning.maxRetransmitNanos, max(tuning.baseRetransmitNanos, rttNanos * 12 / 10) << UInt64(min(8, retransmits / 4)))
        nextRetransmitNanos = now &+ interval
        return InputPacket(pointer: pointer, events: events).encode()
    }

    /// Time-driven: a packet to resend if the retransmit timer expired, else nil. Also moves the
    /// channel to "held" after a long gap (unless `autoFlush`).
    public mutating func tick(now: UInt64) -> Data? {
        if !held, !autoFlush, let since = unackedSince.first, now &- since > tuning.holdAfterNanos { held = true }
        let pointerPending = pointer.map { $0.seq > ackedPointerSeq } ?? false
        guard !unacked.isEmpty || pointerPending, now >= nextRetransmitNanos else { return nil }
        retransmits += 1
        return packet(now: now)
    }

    public mutating func ack(_ a: InputAck) {
        if a.eventSeq > ackedEventSeq {
            ackedEventSeq = a.eventSeq
            while let f = unacked.first, f.seq <= a.eventSeq { unacked.removeFirst(); unackedSince.removeFirst() }
        }
        if a.pointerSeq > ackedPointerSeq { ackedPointerSeq = a.pointerSeq }
        retransmits = 0
        if held && unacked.isEmpty { held = false }
    }

    /// The user chose to send what was typed during the gap.
    public mutating func flush() { held = false; retransmits = 0; nextRetransmitNanos = 0 }
    /// The user chose to discard it.
    public mutating func discard() { unacked.removeAll(); unackedSince.removeAll(); held = false; retransmits = 0 }
}

/// Host side: applies each discrete event exactly once in sequence order, the pointer state
/// latest-wins, and says what to acknowledge. Idempotent under any loss, duplication or
/// reordering of packets. Pure logic; the host injects what `receive` returns.
public struct InputReceiver {
    public private(set) var lastEventSeq: UInt64 = 0
    public private(set) var lastPointerSeq: UInt64 = 0
    public private(set) var duplicates = 0
    public private(set) var applied = 0
    public init() {}

    /// Messages to inject, in order, and the ack to send back.
    public mutating func receive(_ p: InputPacket) -> (apply: [ControlMessage], ack: InputAck) {
        var out: [ControlMessage] = []
        var pointer = p.pointer
        if let pt = pointer, pt.seq <= lastPointerSeq { pointer = nil }
        for e in p.events.sorted(by: { $0.seq < $1.seq }) {
            if e.seq <= lastEventSeq { duplicates += 1; continue }
            if let pt = pointer, pt.seq < e.seq {
                out.append(.mouseMove(.init(x: pt.x, y: pt.y, seq: pt.seq))); lastPointerSeq = pt.seq; pointer = nil
            }
            out.append(e.message); lastEventSeq = e.seq; applied += 1
        }
        if let pt = pointer { out.append(.mouseMove(.init(x: pt.x, y: pt.y, seq: pt.seq))); lastPointerSeq = pt.seq }
        return (out, InputAck(eventSeq: lastEventSeq, pointerSeq: lastPointerSeq))
    }
}

/// Test-only loss injection on a datagram send path: `MIRAGE_TEST_LOSS=0.05` drops 5 % of
/// datagrams at random; `MIRAGE_TEST_BURST_MS=2000` additionally drops everything for 2 s every
/// `MIRAGE_TEST_BURST_EVERY_S` seconds (default 10, first burst after one period). The viewer's
/// input datagrams and the host's video datagrams both pass through it, each in its own process,
/// so the scenario scripts set the variables per process. `MIRAGE_TEST_SEED` makes a run repeatable.
public final class LossInjector: @unchecked Sendable {
    public static let shared = LossInjector(environment: ProcessInfo.processInfo.environment)
    public let lossRate: Double
    public let burstNanos: UInt64
    public let burstEveryNanos: UInt64
    private let start = Clock.nowNanos()
    private var rng: SplitMix64
    private let lock = NSLock()
    public private(set) var dropped = 0, passed = 0

    public init(environment env: [String: String]) {
        lossRate = env["MIRAGE_TEST_LOSS"].flatMap(Double.init) ?? 0
        burstNanos = UInt64((env["MIRAGE_TEST_BURST_MS"].flatMap(Double.init) ?? 0) * 1e6)
        burstEveryNanos = UInt64((env["MIRAGE_TEST_BURST_EVERY_S"].flatMap(Double.init) ?? 10) * 1e9)
        rng = SplitMix64(seed: env["MIRAGE_TEST_SEED"].flatMap(UInt64.init) ?? 0x9E3779B97F4A7C15)
    }
    public var isActive: Bool { lossRate > 0 || burstNanos > 0 }
    public var description: String { "loss \(lossRate * 100) %" + (burstNanos > 0 ? ", \(burstNanos / 1_000_000) ms burst every \(burstEveryNanos / 1_000_000_000) s" : "") }

    /// True if a burst is in progress at `now`.
    public func inBurst(now: UInt64 = Clock.nowNanos()) -> Bool {
        guard burstNanos > 0, burstEveryNanos > 0 else { return false }
        let t = now &- start
        return t >= burstEveryNanos && (t % burstEveryNanos) < burstNanos
    }

    /// Decides for one datagram.
    public func shouldDrop(now: UInt64 = Clock.nowNanos()) -> Bool {
        guard isActive else { return false }
        lock.lock(); defer { lock.unlock() }
        if inBurst(now: now) { dropped += 1; return true }
        if lossRate > 0, rng.nextUnit() < lossRate { dropped += 1; return true }
        passed += 1
        return false
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
