import Foundation

/// The tile stream's send-side gate (crisp-first, 2026-10-25): no refinement message enters the wire past the in-flight
/// limit, whatever the encoders produce. The refinement gate in `refine` holds encode *starts* on estimates; blocks then
/// came out ~5x their estimates on phrz's iPhone, 12 finished at once and 2.5 MB went out against a 148 KB cap, ~3 s of
/// queue in the path. Direct changes and stills never wait here (visible truth goes first); refinement messages wait in
/// order and leave as acks free room. The limit: 2x the in-flight cap on a Local link, 1x plus one message below it (the
/// self-made queue is what hurt the phone).
struct SendGate<Item> {
    struct Held { var item: Item; var bytes: Int }
    private(set) var held: [Held] = []
    var heldBytes: Int { held.reduce(0) { $0 + $1.bytes } }

    /// Whether a message of `bytes` may go now with `inflight` bytes unacked: one message always may when nothing is in
    /// flight, so the stream never stalls on a message larger than the limit.
    static func fits(_ bytes: Int, inflight: Int, cap: Int, local: Bool) -> Bool {
        if inflight <= 0 { return true }
        return local ? inflight + bytes <= cap * 2 : inflight < cap
    }

    /// A refinement message ready to send: returned to send now, or held (behind any already held, in order).
    mutating func offer(_ item: Item, bytes: Int, inflight: Int, cap: Int, local: Bool) -> Item? {
        if held.isEmpty, Self.fits(bytes, inflight: inflight, cap: cap, local: local) { return item }
        held.append(Held(item: item, bytes: bytes)); return nil
    }

    /// Held messages that fit now, oldest first; `inflight` grows by each one released. `stale` says whether a held message
    /// must be dropped instead (its layer changed under it since it was encoded): it is returned in the second list.
    mutating func release(inflight start: Int, cap: Int, local: Bool, stale: (Item) -> Bool) -> (send: [Item], dropped: [Item]) {
        var inflight = start, send: [Item] = [], dropped: [Item] = []
        while let first = held.first {
            if stale(first.item) { dropped.append(first.item); held.removeFirst(); continue }
            guard Self.fits(first.bytes, inflight: inflight, cap: cap, local: local) else { break }
            send.append(first.item); inflight += first.bytes; held.removeFirst()
        }
        return (send, dropped)
    }

    /// Everything held, for a session that stops or suspends.
    mutating func drain() -> [Item] { defer { held = [] }; return held.map(\.item) }
}
