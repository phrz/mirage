import XCTest
@testable import MirageCore

final class FreshPictureTests: XCTestCase {
    func testOnlyStartResizeAndTierChangeRestartTheWholePicture() {
        XCTAssertTrue(FreshPictureTrigger.streamStart.restartsWholePicture)
        XCTAssertTrue(FreshPictureTrigger.resize.restartsWholePicture)
        XCTAssertTrue(FreshPictureTrigger.tierChange.restartsWholePicture)
        // A localized change of any size, and the keyframe that recovers from a loss, never do.
        XCTAssertFalse(FreshPictureTrigger.regionChange.restartsWholePicture)
        XCTAssertFalse(FreshPictureTrigger.recoveryKeyframe.restartsWholePicture)
    }
}

final class TierInputTests: XCTestCase {
    func testMinRTTComesFromProbesNotFromPacedVideoAcks() {
        var rc = RateController(initialKbps: 800, maxKbps: 800, nativePixels: 3200 * 1800)
        var now: UInt64 = 1_000_000_000
        for _ in 0..<5 { rc.probeSample(sentNanos: now - 145_000_000, receivedNanos: 0, now: now); now += 200_000_000 }
        XCTAssertEqual(rc.minRttMs, 145, accuracy: 1)
        // A video ack whose RTT, taken from the pacer's estimated end, reads 40 ms must not move the tier's minimum.
        rc.frameAcked(sentNanos: now - 50_000_000, firstReceived: now - 45_000_000, lastReceived: now - 40_000_000, fragments: 2, bytes: 2000, now: now, rttNanos: 40_000_000)
        XCTAssertEqual(rc.minRttMs, 145, accuracy: 1)
        // Normal and Constrained share one policy: switching between them restarts nothing.
        XCTAssertEqual(LinkTier.normal.policy, LinkTier.constrained.policy)
    }
}
