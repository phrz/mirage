import Foundation

/// Which tiles of the display (desktop) layer the viewer may hold *window* pixels for (DESIGN §3.2, layered
/// desktop; the M3.1 ghost regression on mac-daddy: bench fragments left on the desktop after it moved).
/// The display stream excludes the windows that are layers, but window pixels still reach the desktop layer
/// while a window is not yet a layer (its first still has not landed), and for a moment while an excluded
/// window moves. So every time the host sends desktop pixels for a tile it records whether, at that capture,
/// the tile touched a window area (a planned or layered window's frame, or one of its frames in the last
/// moments of a move). A tainted tile that is visible to the viewer (no window layer over it) is re-sent once
/// from the current desktop; clean tiles are never re-sent.
public struct DisplayTaint: Equatable {
    public private(set) var tainted = Set<Int>()
    public init() {}

    /// Desktop pixels for `tiles` were sent from a capture during which `windowAreas` held windows.
    public mutating func sent(_ tiles: [Int], tracker: TileTracker, windowAreas: [PixelRect]) {
        for i in tiles {
            let r = tracker.rect(of: i)
            if windowAreas.contains(where: { $0.intersects(r) }) { tainted.insert(i) } else { tainted.remove(i) }
        }
    }

    /// Tainted tiles to re-send now: visible on the viewer (not `hidden` under a window layer) and clear of
    /// every window area (else the desktop under them may still not be clean in the capture).
    public func due(hidden: Set<Int>, tracker: TileTracker, windowAreas: [PixelRect]) -> [Int] {
        tainted.filter { i in
            guard !hidden.contains(i) else { return false }
            let r = tracker.rect(of: i)
            return !windowAreas.contains(where: { $0.intersects(r) })
        }.sorted()
    }

    /// The viewer reports it holds no clean pixels for these tiles.
    public mutating func mark(_ tiles: [Int]) { tainted.formUnion(tiles) }
    /// The viewer holds window-free pixels for these tiles now (the desktop underlay).
    public mutating func clear(_ tiles: [Int]) { tainted.subtract(tiles) }
    public mutating func reset() { tainted = [] }
}
