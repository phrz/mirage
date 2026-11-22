import Foundation

/// When a window the viewer shows only as a small still (Unified's window strip on a phone or tablet, `ViewInterest.stillLayers`)
/// gets its next picture. Its changes are held (TileTracker.holdForStill), never sent as they happen; a release makes them
/// due refinement at once, so the viewer gets one crisp lossless picture, from the frame of that moment.
/// A release comes once the window has been quiet for `settleNanos` (a settled picture), and at most once every
/// `minIntervalNanos`; a window that never settles (a video, a progress bar) is released anyway once its change has been
/// held that long, so its still is never more than about that old.
public struct StillCadence: Equatable {
    public static let minIntervalNanos: UInt64 = 4_000_000_000
    public static let settleNanos: UInt64 = 1_000_000_000

    /// When the first change held since the last release came (0: nothing held).
    public private(set) var heldSince: UInt64 = 0
    public private(set) var lastChangeNanos: UInt64 = 0
    /// The last release (0: none yet, so the first change after the window became a still goes as soon as it settles).
    public private(set) var lastReleaseNanos: UInt64 = 0

    public init() {}

    /// A capture changed the window (its changed tiles are held).
    public mutating func changed(now: UInt64) {
        if heldSince == 0 { heldSince = now }
        lastChangeNanos = now
    }

    public func due(now: UInt64) -> Bool {
        guard heldSince != 0 else { return false }
        if lastReleaseNanos != 0, now &- lastReleaseNanos < Self.minIntervalNanos { return false }
        return now &- lastChangeNanos >= Self.settleNanos || now &- heldSince >= Self.minIntervalNanos
    }

    public mutating func released(now: UInt64) {
        heldSince = 0
        lastReleaseNanos = now
    }
}
