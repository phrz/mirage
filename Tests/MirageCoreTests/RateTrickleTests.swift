import XCTest
@testable import MirageCore

/// The controller must not trust a trickle of video acks over clean probes (mac-daddy, 2026-10-21: an animated Dock icon's
/// video read a ~140 ms queue the probes did not see; the target fell to 150 kbps and the tier to Extreme with 0 frames lost).
final class RateTrickleTests: XCTestCase {
    /// `frameBytes` at `fps` with one-way delay `owd(t)` (ms), probes once a second with RTT `probeRTT(t)` (ms), for `seconds`.
    private func run(frameBytes: Int, fps: Int, seconds: Int, owd: (Int) -> Double, probeRTT: (Int) -> Double) -> RateController {
        var rc = RateController(initialKbps: 800, maxKbps: 800, nativePixels: 3200 * 1800)
        let ms: UInt64 = 1_000_000
        let start: UInt64 = 10_000_000_000
        let frameEvery = 1000 / fps
        for t in 0..<(seconds * 1000) {
            let now = start + UInt64(t) * ms
            if t % frameEvery == 0 {
                let d = UInt64(owd(t)) * ms
                rc.frameAcked(sentNanos: now, firstReceived: now + d, lastReceived: now + d, fragments: 1, bytes: frameBytes, now: now + d + 25 * ms, rttNanos: Double(d + 25 * ms))
            }
            if t % 1000 == 0 {
                let r = UInt64(probeRTT(t)) * ms
                rc.probeSample(sentNanos: now, receivedNanos: now + r / 2, now: now + r)
                rc.tick(now: now)
            }
        }
        return rc
    }
    /// Deterministic noise in 0..<range (a linear congruential sequence over the millisecond).
    private func noise(_ t: Int, _ range: Int) -> Double {
        var x = UInt64(t) &* 6364136223846793005 &+ 1442695040888963407
        x ^= x >> 33
        return Double(x % UInt64(range))
    }

    func testANoisyVideoTrickleBesideCleanProbesHoldsTheTarget() {
        // ~200 kbps of small frames whose delay jumps around by up to 300 ms; the probes see a clean 50 ms link.
        let rc = run(frameBytes: 5_000, fps: 5, seconds: 30, owd: { 25 + self.noise($0, 300) }, probeRTT: { _ in 50 })
        XCTAssertGreaterThanOrEqual(rc.targetKbps, 720, "target held (got \(rc.targetKbps))")
        XCTAssertNotEqual(rc.tier, .extreme, "no Extreme on delay alone with 0 % loss and the probes disagreeing")
        // Tiny frames (an icon): too little volume to push the target at all.
        let tiny = run(frameBytes: 1_500, fps: 4, seconds: 30, owd: { 25 + self.noise($0, 300) }, probeRTT: { _ in 50 })
        XCTAssertGreaterThanOrEqual(tiny.targetKbps, 720)
    }

    func testRealCongestionStillBacksOff() {
        // Full video (30 fps, 10 KB frames) whose delay climbs to +200 ms, and the probes see the same queue.
        let rc = run(frameBytes: 10_000, fps: 30, seconds: 20, owd: { 25 + min(200, Double($0) / 25) }, probeRTT: { 50 + min(200, Double($0) / 25) })
        XCTAssertLessThan(rc.targetKbps, 640, "a real queue still moves the target down (got \(rc.targetKbps))")
    }
}
