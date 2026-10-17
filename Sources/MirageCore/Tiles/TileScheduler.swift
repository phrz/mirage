import Foundation

/// The send order the scheduler rule demands (DESIGN §3.3b), in one place so a unit test can pin it:
/// (1) changed tiles within `radius` px of the input locus, (2) other changed tiles, (3) refinement
/// items. Copy-rects are sent before any of these by the caller.
public enum TileScheduler {
    public struct Order: Equatable {
        public var locus: [Int]        // priority 1
        public var changed: [Int]      // priority 2
        public var refinement: [Int]   // priority 4
    }

    /// `locus` is the last input position in native pixels, if any.
    public static func order(changed: [Int], refinement: [Int], locus: (x: Int, y: Int)?, tracker: TileTracker, radius: Int = 200) -> Order {
        guard let l = locus else { return Order(locus: [], changed: changed, refinement: refinement) }
        var near: [Int] = [], far: [Int] = []
        for i in changed {
            let r = tracker.rect(of: i)
            let cx = r.x + r.width / 2, cy = r.y + r.height / 2
            if abs(cx - l.x) <= radius + r.width / 2 && abs(cy - l.y) <= radius + r.height / 2 { near.append(i) } else { far.append(i) }
        }
        return Order(locus: near, changed: far, refinement: refinement)
    }

    /// Flattened send sequence.
    public static func sequence(_ o: Order) -> [Int] { o.locus + o.changed + o.refinement }
}
