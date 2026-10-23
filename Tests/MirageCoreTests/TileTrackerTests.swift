import XCTest
@testable import MirageCore

final class TileTrackerTests: XCTestCase {
    func testSparseChangeGoesLosslessAndIsRateLimited() {
        var t = TileTracker(width: 1280, height: 720)
        let dirty = t.tiles(covering: [PixelRect(x: 100, y: 100, width: 10, height: 10)])
        XCTAssertEqual(dirty, [t.index(col: 1, row: 1)])
        let p1 = t.classify(dirty: dirty, now: 1_000_000_000)
        XCTAssertEqual(p1.lossless, dirty); XCTAssertTrue(p1.video.isEmpty)
        // 20 ms later the same tile changes again (caret blink): rate-limited, becomes pending.
        let p2 = t.classify(dirty: dirty, now: 1_020_000_000)
        XCTAssertTrue(p2.lossless.isEmpty)
        XCTAssertEqual(t.pendingTotal, 1)
        XCTAssertTrue(t.due(now: 1_050_000_000, limit: 10).isEmpty)
        XCTAssertEqual(t.due(now: 1_100_000_000, limit: 10), dirty)
        t.sent(lossless: dirty, now: 1_100_000_000)
        XCTAssertEqual(t.pendingTotal, 0)
    }

    func testLargeDirtyAreaIsVideoThenRefined() {
        var t = TileTracker(width: 1280, height: 720)
        let scroll = PixelRect(x: 0, y: 64, width: 500, height: 400)   // 8×7 = 56 tiles, 23 % of the frame
        let dirty = t.tiles(covering: [scroll])
        let p = t.classify(dirty: dirty, now: 1_000_000_000)
        XCTAssertTrue(p.lossless.isEmpty)
        XCTAssertEqual(p.video, dirty)
        XCTAssertEqual(p.videoRegion, PixelRect(x: 0, y: 64, width: 512, height: 448))
        XCTAssertFalse(p.wholeFrame)
        XCTAssertEqual(t.pendingRefinement, dirty.count)
        // Still moving 100 ms later: nothing due; 300 ms after the last motion: all due, oldest first.
        _ = t.classify(dirty: dirty, now: 1_100_000_000)
        XCTAssertTrue(t.due(now: 1_300_000_000, limit: 1000).isEmpty)
        let due = t.due(now: 1_450_000_000, limit: 1000)
        XCTAssertEqual(due.count, dirty.count)
        // Centre-first among equals: the first due tile is near the frame centre (640, 360).
        let first = t.rect(of: due[0])
        XCTAssertLessThan(abs(first.x + 32 - 640) + abs(first.y + 32 - 360), 260)
    }

    func testWholeFrameAboveFortyPercent() {
        var t = TileTracker(width: 1280, height: 720)
        let dirty = t.tiles(covering: [PixelRect(x: 0, y: 0, width: 1280, height: 400)])
        let p = t.classify(dirty: dirty, now: 1)
        XCTAssertTrue(p.wholeFrame)
        XCTAssertEqual(p.videoRegion, PixelRect(x: 0, y: 0, width: 1280, height: 720))
    }

    func testSustainedSmallRegionBecomesVideo() {
        var t = TileTracker(width: 1280, height: 720)
        let region = PixelRect(x: 200, y: 200, width: 300, height: 200)   // 5×4 = 20 tiles, under motionTileCount
        let dirty = t.tiles(covering: [region])
        var now: UInt64 = 1_000_000_000
        var sawVideo = false
        for _ in 0..<6 {
            let p = t.classify(dirty: dirty, now: now)
            if !p.video.isEmpty { sawVideo = true; XCTAssertEqual(p.video, dirty) }
            now += 33_000_000
        }
        XCTAssertTrue(sawVideo, "20 tiles changing every frame should switch to video")
    }

    func testMergedRects() {
        let t = TileTracker(width: 640, height: 320)
        // A 3×2 block plus a lone tile.
        var tiles: [Int] = []
        for r in 1...2 { for c in 2...4 { tiles.append(t.index(col: c, row: r)) } }
        tiles.append(t.index(col: 9, row: 4))
        let rects = t.mergedRects(tiles)
        XCTAssertEqual(Set(rects), Set([PixelRect(x: 128, y: 64, width: 192, height: 128), PixelRect(x: 576, y: 256, width: 64, height: 64)]))
    }
}

final class ShiftDetectorTests: XCTestCase {
    /// A frame with "text lines": rows of pseudo-random pixels every few px, white elsewhere,
    /// plus ±2 per-channel noise (what SCK's downscale leaves between a moved pixel and its original).
    private func makeFrame(width: Int, height: Int, seed: UInt32, yOffset: Int = 0, noiseSeed: UInt32 = 0) -> [UInt8] {
        var px = [UInt8](repeating: 0xFF, count: width * height * 4)
        var noise = noiseSeed &* 2246822519 &+ 1
        for y in 0..<height {
            let srcY = y + yOffset
            guard srcY >= 0, srcY % 7 < 3 else { continue }   // blank lines between text lines
            var rng = seed &+ UInt32(srcY) &* 2654435761
            for x in 0..<width {
                rng = rng &* 1103515245 &+ 12345
                noise = noise &* 1103515245 &+ 12345
                let v = UInt8((rng >> 16) & 0xff)
                let n = noiseSeed == 0 ? 0 : Int((noise >> 16) % 5) - 2
                let o = (y * width + x) * 4
                px[o] = UInt8(clamping: Int(v) + n); px[o + 1] = UInt8(clamping: Int(v ^ 0x55) + n); px[o + 2] = UInt8(clamping: Int(v ^ 0xAA) + n); px[o + 3] = 0xff
            }
        }
        return px
    }

    func testDetectsVerticalScrollAndExposedStripMismatch() {
        let w = 640, h = 512
        let old = makeFrame(width: w, height: h, seed: 7)
        // Content moved up by 40 px (scrolled down). At native scale scrolled pixels are identical (no downscale noise any more).
        let new = makeFrame(width: w, height: h, seed: 7, yOffset: 40)
        let d = ShiftDetector()
        let r = old.withUnsafeBytes { o in new.withUnsafeBytes { n in
            d.detect(old: .init(base: o.baseAddress!, stride: w * 4, width: w, height: h),
                     new: .init(base: n.baseAddress!, stride: w * 4, width: w, height: h),
                     rect: PixelRect(x: 0, y: 0, width: w, height: h))
        } }
        XCTAssertNotNil(r)
        guard let r else { return }
        XCTAssertEqual(r.dx, 0); XCTAssertEqual(r.dy, -40)
        XCTAssertEqual(r.rect, PixelRect(x: 0, y: 40, width: w, height: h - 40))
        XCTAssertGreaterThan(r.confidence, 0.95)
        XCTAssertTrue(r.mismatchedTiles.isEmpty, "\(r.mismatchedTiles)")
    }

    /// Low-colour (UI, text) tiles must verify byte-exact: ±2 noise on 256-colour content is not the same pixels.
    func testNoisyLowColourContentDoesNotVerify() {
        let w = 640, h = 512
        let old = makeFrame(width: w, height: h, seed: 7)
        let new = makeFrame(width: w, height: h, seed: 7, yOffset: 40, noiseSeed: 99)
        let d = ShiftDetector()
        let r = old.withUnsafeBytes { o in new.withUnsafeBytes { n in
            d.verify(old: .init(base: o.baseAddress!, stride: w * 4, width: w, height: h),
                     new: .init(base: n.baseAddress!, stride: w * 4, width: w, height: h),
                     rect: PixelRect(x: 0, y: 0, width: w, height: h), dx: 0, dy: -40)
        } }
        XCTAssertNil(r, "no tile explained by an inexact copy")
    }

    /// Periodic content (an icon grid: every 120 px the same row, rows told apart only by a small label): the shift a period
    /// away scores almost as well on the profile; exact verification picks the true one.
    func testPeriodicGridPicksTheExactShift() {
        let w = 640, h = 720, period = 120
        func frame(_ off: Int) -> [UInt8] {
            var px = [UInt8](repeating: 30, count: w * h * 4)
            for y in 0..<h {
                let sy = y + off, inRow = ((sy % period) + period) % period, rowIndex = (sy - inRow) / period
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    var v: UInt8 = 30
                    if inRow >= 20, inRow < 80, x % 160 >= 40, x % 160 < 100 { v = 250 }            // icons
                    if inRow >= 90, inRow < 100, x % 160 >= 30, x % 160 < 110 { v = 200 }           // label line
                    if inRow >= 92, inRow < 98, x % 160 >= 70, x % 160 < 76, (rowIndex + x / 160) % 3 == 0 { v = 90 }   // a digit
                    px[o] = v; px[o + 1] = v; px[o + 2] = v; px[o + 3] = 255
                }
            }
            return px
        }
        let old = frame(0), new = frame(40)
        let d = ShiftDetector()
        let r = old.withUnsafeBytes { o in new.withUnsafeBytes { n in
            d.detect(old: .init(base: o.baseAddress!, stride: w * 4, width: w, height: h),
                     new: .init(base: n.baseAddress!, stride: w * 4, width: w, height: h),
                     rect: PixelRect(x: 0, y: 0, width: w, height: h))
        } }
        guard let r else { return XCTFail("no shift") }
        XCTAssertEqual(r.dy, -40)
        XCTAssertTrue(r.mismatchedTiles.isEmpty, "\(r.mismatchedTiles.count) mismatched")
    }

    func testInPlaceChangeIsNotAShift() {
        let w = 320, h = 320
        let old = makeFrame(width: w, height: h, seed: 3)
        var new = old
        for i in stride(from: 0, to: new.count, by: 4 * 97) { new[i] ^= 0x80 }   // scattered pixel edits
        let d = ShiftDetector()
        let r = old.withUnsafeBytes { o in new.withUnsafeBytes { n in
            d.detect(old: .init(base: o.baseAddress!, stride: w * 4, width: w, height: h),
                     new: .init(base: n.baseAddress!, stride: w * 4, width: w, height: h),
                     rect: PixelRect(x: 0, y: 0, width: w, height: h))
        } }
        XCTAssertNil(r)
    }

    func testVerifyKnownWindowDrag() {
        let w = 512, h = 384
        let old = makeFrame(width: w, height: h, seed: 11)
        // Move a 256×192 window at (64,64) by (+24,+12) in the new frame; leave the rest of the frame unchanged.
        var new = old
        let win = PixelRect(x: 64, y: 64, width: 256, height: 192)
        for y in (0..<h).reversed() { for x in (0..<w).reversed() {
            let sx = x - 24, sy = y - 12
            guard win.contains(sx, sy) else { continue }
            let o = (y * w + x) * 4, s = (sy * w + sx) * 4
            new[o] = old[s]; new[o+1] = old[s+1]; new[o+2] = old[s+2]
        } }
        let d = ShiftDetector()
        let r = old.withUnsafeBytes { o in new.withUnsafeBytes { n in
            d.verify(old: .init(base: o.baseAddress!, stride: w * 4, width: w, height: h),
                     new: .init(base: n.baseAddress!, stride: w * 4, width: w, height: h), rect: win, dx: 24, dy: 12)
        } }
        XCTAssertNotNil(r); XCTAssertEqual(r?.confidence, 1.0)
    }
}

final class RateControllerTests: XCTestCase {
    /// Simulates a link: capacity C kbps, base one-way delay, queue growing when the sender exceeds C.
    private func run(capacityKbps: Double, maxKbps: Int, seconds: Int, sendsAtTarget: Bool = true) -> RateController {
        var rc = RateController(initialKbps: 800, maxKbps: maxKbps, nativePixels: 2560 * 1440)
        var now: UInt64 = 1_000_000_000
        var queueBytes = 0.0
        let base: UInt64 = 100_000_000
        for _ in 0..<(seconds * 30) {
            let dt = 1.0 / 30
            let frameBytes = Double(rc.targetKbps) * 1000 / 8 * dt
            queueBytes = max(0, queueBytes + frameBytes - capacityKbps * 1000 / 8 * dt)
            let queueNanos = UInt64(queueBytes / (capacityKbps * 1000 / 8) * 1e9)
            let frags = Int(frameBytes / 1157) + 1
            let trainNanos = UInt64(Double(frags) * 1157 * 8 / (capacityKbps * 1000) * 1e9)
            let sent = now
            let first = sent + base + queueNanos
            rc.frameAcked(sentNanos: sent, firstReceived: first, lastReceived: first + trainNanos, fragments: frags, bytes: Int(frameBytes), now: now + 200_000_000, rttNanos: 200_000_000)
            now += UInt64(dt * 1e9)
        }
        return rc
    }

    func testSettlesBelowCapacityWhenAskedForTooMuch() {
        let rc = run(capacityKbps: 1000, maxKbps: 2000, seconds: 30)
        XCTAssertLessThan(rc.targetKbps, 900, "target \(rc.targetKbps) should back off below a 1 Mbps link")
        XCTAssertGreaterThan(rc.targetKbps, 400)
        XCTAssertLessThan(rc.queueMs, 100)
        XCTAssertGreaterThan(rc.capacityKbps, 600); XCTAssertLessThan(rc.capacityKbps, 1400)
    }

    func testHoldsRequestedRateOnAFatLinkAndClimbsFromTheTinyRung() {
        let start = RateController(initialKbps: 800, maxKbps: 800, nativePixels: 2560 * 1440)
        XCTAssertEqual(start.rung, RateController.tinyRung, "lossy-first: every stream starts tiny")
        let rc = run(capacityKbps: 5000, maxKbps: 800, seconds: 40)
        XCTAssertEqual(rc.targetKbps, 800)
        XCTAssertEqual(rc.rung, 1, "climbs one rung per 5 s of headroom; rung 0 at 1440p needs >1.1 Mbps")
    }

    func testLadderDropsOnSustainedShortfallAndClimbsBack() {
        var rc = RateController(initialKbps: 300, maxKbps: 300, nativePixels: 2560 * 1440)
        var now: UInt64 = 1_000_000_000
        for _ in 0..<120 {   // 4 s at 300 kbps: below 2560×1440's 663 kbps need → rung 1 after 2 s
            rc.frameAcked(sentNanos: now, firstReceived: now + 100_000_000, lastReceived: now + 110_000_000, fragments: 4, bytes: 4000, now: now + 200_000_000, rttNanos: 200_000_000)
            now += 33_000_000
        }
        XCTAssertGreaterThanOrEqual(rc.rung, 1)
        XCTAssertLessThan(rc.scale, 1)
        rc.maxKbps = 2000
        for _ in 0..<1800 {   // generous link, 60 s: the 8 %/s increase ramps the target; one climb per 5 s above the next rung's need
            rc.frameAcked(sentNanos: now, firstReceived: now + 100_000_000, lastReceived: now + 102_000_000, fragments: 4, bytes: 4000, now: now + 200_000_000, rttNanos: 200_000_000)
            now += 33_000_000
        }
        XCTAssertEqual(rc.rung, 0)
    }

    func testBudgetSplit() {
        let rc = RateController(initialKbps: 1000, maxKbps: 1000, nativePixels: 1)
        XCTAssertEqual(rc.budget(videoActive: true), .init(tileKbps: 450, videoKbps: 900))
        XCTAssertEqual(rc.budget(videoActive: true, recentTileKbps: 200), .init(tileKbps: 450, videoKbps: 750))
        XCTAssertEqual(rc.budget(videoActive: true, recentTileKbps: 800), .init(tileKbps: 450, videoKbps: 550))
        XCTAssertEqual(rc.budget(videoActive: false).tileKbps, 900)
    }
}

final class ShiftRefineTests: XCTestCase {
    func testRefineFindsDiagonalOffsetFromSkewedDelta() {
        let w = 512, h = 384
        var old = [UInt8](repeating: 0xFF, count: w * h * 4)
        var rng: UInt32 = 5
        for i in 0..<(w * h) { rng = rng &* 1103515245 &+ 12345; let v = UInt8((rng >> 16) & 0xff); old[i * 4] = v; old[i * 4 + 1] = v; old[i * 4 + 2] = v }
        var new = [UInt8](repeating: 0xFF, count: w * h * 4)
        let win = PixelRect(x: 64, y: 64, width: 256, height: 192)
        for y in 0..<h { for x in 0..<w {
            let sx = x - 7, sy = y - 4
            guard win.contains(sx, sy) else { continue }
            let o = (y * w + x) * 4, s = (sy * w + sx) * 4
            new[o] = old[s]; new[o+1] = old[s+1]; new[o+2] = old[s+2]
        } }
        let d = ShiftDetector()
        let r = old.withUnsafeBytes { o in new.withUnsafeBytes { n in
            d.refine(old: .init(base: o.baseAddress!, stride: w * 4, width: w, height: h), new: .init(base: n.baseAddress!, stride: w * 4, width: w, height: h), rect: win, dx: 4, dy: 2)
        } }
        XCTAssertEqual(r?.dx, 7); XCTAssertEqual(r?.dy, 4)
    }
}

final class LinkTierTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(LinkTier.classify(rateKbps: 800, limitedByLink: false, rttMs: 210, lossPercent: 0), .constrained)   // this Japan link
        XCTAssertEqual(LinkTier.classify(rateKbps: 800, limitedByLink: false, rttMs: 30, lossPercent: 0), .normal, "a low cap on a good link is not a constrained link")
        XCTAssertEqual(LinkTier.classify(rateKbps: 1200, limitedByLink: true, rttMs: 30, lossPercent: 0), .constrained, "held under 2 Mbps by delay")
        XCTAssertEqual(LinkTier.classify(rateKbps: 800, limitedByLink: false, rttMs: 2, lossPercent: 0), .local)
        XCTAssertEqual(LinkTier.classify(rateKbps: 256, limitedByLink: true, rttMs: 900, lossPercent: 5), .extreme)
        XCTAssertEqual(LinkTier.classify(rateKbps: 7000, limitedByLink: false, rttMs: 450, lossPercent: 0), .constrained, "a slow round trip is not a lower picture")
        XCTAssertNotEqual(LinkTier.classify(rateKbps: 20_000, limitedByLink: false, rttMs: 30, lossPercent: 5), .extreme, "loss alone is the transport's, not the picture's")
        XCTAssertEqual(LinkTier.constrained.policy, LinkTier.normal.policy, "Constrained (round trip) must not cut quality")
        XCTAssertTrue(LinkTier.extreme.policy.videoEnabled, "video-minimal, not off")
        XCTAssertEqual(LinkTier.extreme.policy.minRung, RateController.tinyRung); XCTAssertEqual(LinkTier.extreme.policy.maxVideoFPS, 5)
    }
    func testHysteresis() {
        var sel = TierSelector()
        sel.update(rateKbps: 300, limitedByLink: true, rttMs: 150, lossPercent: 0, now: 1_000_000_000)
        XCTAssertEqual(sel.tier, .normal, "one bad sample does not change the tier")
        sel.update(rateKbps: 300, limitedByLink: true, rttMs: 150, lossPercent: 0, now: 2_000_000_000)
        XCTAssertEqual(sel.tier, .normal)
        sel.update(rateKbps: 300, limitedByLink: true, rttMs: 150, lossPercent: 0, now: 3_100_000_000)
        XCTAssertEqual(sel.tier, .normal, "Extreme needs its condition for 10 s, not 2")
        sel.update(rateKbps: 300, limitedByLink: true, rttMs: 150, lossPercent: 0, now: 11_100_000_000)
        XCTAssertEqual(sel.tier, .extreme, "worse tier (Extreme) after 10 s")
        sel.update(rateKbps: 800, limitedByLink: false, rttMs: 200, lossPercent: 0, now: 12_000_000_000)
        sel.update(rateKbps: 800, limitedByLink: false, rttMs: 200, lossPercent: 0, now: 17_000_000_000)
        XCTAssertEqual(sel.tier, .extreme, "better tier needs 10 s")
        sel.update(rateKbps: 800, limitedByLink: false, rttMs: 200, lossPercent: 0, now: 22_100_000_000)
        XCTAssertEqual(sel.tier, .constrained)
        // Other worse tiers keep the 2 s dwell.
        var s2 = TierSelector(initial: .normal)
        s2.update(rateKbps: 800, limitedByLink: false, rttMs: 200, lossPercent: 0, now: 1_000_000_000)
        s2.update(rateKbps: 800, limitedByLink: false, rttMs: 200, lossPercent: 0, now: 3_100_000_000)
        XCTAssertEqual(s2.tier, .constrained)
    }
    func testControllerReportsConstrainedOnThisLink() {
        var rc = RateController(initialKbps: 800, maxKbps: 800, nativePixels: 1000)
        var now: UInt64 = 1_000_000_000
        for _ in 0..<120 { rc.frameAcked(sentNanos: now, firstReceived: now + 100_000_000, lastReceived: now + 110_000_000, fragments: 4, bytes: 4000, now: now + 200_000_000, rttNanos: 210_000_000); now += 33_000_000 }
        XCTAssertEqual(rc.tier, .constrained)
        XCTAssertEqual(rc.policy.maxRung, RateController.tinyRung)
    }
}

final class LadderFPSTests: XCTestCase {
    func testSustainedFPSShortfallDropsARung() {
        var rc = RateController(initialKbps: 800, maxKbps: 800, nativePixels: 2560 * 1440)
        var now: UInt64 = 10_000_000_000
        // Climb away from the tiny rung first.
        for _ in 0..<900 { rc.frameAcked(sentNanos: now, firstReceived: now + 100_000_000, lastReceived: now + 110_000_000, fragments: 4, bytes: 4000, now: now + 200_000_000, rttNanos: 200_000_000); now += 33_000_000 }
        let before = rc.rung
        XCTAssertLessThan(before, RateController.tinyRung)
        for _ in 0..<4 { rc.videoRate(achievedFPS: 4, wantedFPS: 30, active: true, now: now); now += 1_000_000_000 }
        XCTAssertEqual(rc.rung, before + 1, "4 fps against 30 wanted for 3 s drops one rung")
        rc.videoRate(achievedFPS: 28, wantedFPS: 30, active: true, now: now); now += 1_000_000_000
        rc.videoRate(achievedFPS: 28, wantedFPS: 30, active: true, now: now)
        XCTAssertEqual(rc.rung, before + 1, "a healthy rate does not drop further")
    }
}

final class TileSchedulerTests: XCTestCase {
    /// Regression guard for the scheduler rule: changed pixels near the input locus are dequeued before
    /// any other change and before every refinement item.
    func testLocusChangesComeBeforeEverythingElse() {
        let t = TileTracker(width: 1280, height: 720)
        let nearLocus = t.index(col: 5, row: 3)          // tile centre (352, 224)
        let farChange = t.index(col: 18, row: 10)
        let refine = [t.index(col: 0, row: 0), t.index(col: 5, row: 2)]
        let o = TileScheduler.order(changed: [farChange, nearLocus], refinement: refine, locus: (x: 360, y: 240), tracker: t)
        XCTAssertEqual(o.locus, [nearLocus]); XCTAssertEqual(o.changed, [farChange]); XCTAssertEqual(o.refinement, refine)
        let seq = TileScheduler.sequence(o)
        XCTAssertEqual(seq.first, nearLocus)
        XCTAssertLessThan(seq.firstIndex(of: farChange)!, seq.firstIndex(of: refine[0])!)
        let o2 = TileScheduler.order(changed: [farChange], refinement: refine, locus: nil, tracker: t)
        XCTAssertEqual(TileScheduler.sequence(o2).first, farChange)
    }

    func testUnknownTileFormatIsSkippedNotFatal() throws {
        var m = TileMessage.tiles(.init(header: .init(captureSeq: 1, inputSeq: 1, windowID: 0, captureNanos: 1), refinement: true,
                                        tiles: [.init(rect: PixelRect(x: 0, y: 0, width: 8, height: 8), format: .solid, data: Data([1, 2, 3, 4]))])).encode(msgSeq: 7)
        let formatOffset = 9 + 24 + 1 + 2 + 8   // frame header, tile header, refinement byte, count, rect
        m[formatOffset] = 0x7F
        var p = TileStreamParser()
        let got = try p.feed(m)
        XCTAssertEqual(got.count, 1)
        guard case .tiles(let t)? = got.first?.message else { return XCTFail() }
        XCTAssertTrue(t.tiles.isEmpty, "the unknown tile is dropped, the message (and its ack) survives")
    }

    /// An animated Dock icon (3 tiles changing every 80 ms) is a small region, not video and not lossless at every change:
    /// with the input quiet it goes to `flicker` (the small-animation path) after its fourth change; with input flowing
    /// (typing) the same pattern stays lossless.
    func testASmallBusyRegionIsFlickerWhileInputIsQuiet() {
        var t = TileTracker(width: 640, height: 384)
        let icon = [12, 13, 22]
        var flicker: [Int] = [], lossless = 0
        for k in 0..<10 {
            let p = t.classify(dirty: icon, now: UInt64(k) * 80_000_000 + 1_000_000_000, smallRegions: true)
            XCTAssertTrue(p.video.isEmpty, "too small to be video")
            if k >= 3 { flicker = p.flicker } else { lossless += p.lossless.count }
        }
        XCTAssertEqual(flicker, icon)
        XCTAssertEqual(lossless, 9, "lossless for its first three changes only")
        var typing = TileTracker(width: 640, height: 384)
        var sent = 0
        for k in 0..<10 { let p = typing.classify(dirty: icon, now: UInt64(k) * 80_000_000 + 1_000_000_000); sent += p.lossless.count; XCTAssertTrue(p.flicker.isEmpty) }
        XCTAssertEqual(sent, 30, "with input flowing it stays lossless")
    }

    /// The never-unsent invariant's tools: a held tile (a release that never came) shows up as stale after the age and
    /// becomes due when forced; a tile that keeps changing is never stale (it is being sent).
    func testAHeldTileThatNeverGetsReleasedIsFoundAndMadeDue() {
        var t = TileTracker(width: 640, height: 384)
        let s: UInt64 = 1_000_000_000
        t.holdUntilIdle([5, 6], now: s)
        _ = t.classify(dirty: [7], now: s)
        XCTAssertEqual(t.stalePending([5, 6, 7], olderThan: 10 * s, now: s + 5 * s), [])
        XCTAssertEqual(Set(t.stalePending([5, 6, 7], olderThan: 10 * s, now: s + 11 * s)), [5, 6], "held for 11 s, never released; 7 is due (a backlog), not held")
        XCTAssertFalse(t.due(now: s + 11 * s, limit: 10, centre: nil).contains(5), "held: not due")
        t.forceDue([5, 6], now: s + 11 * s)
        XCTAssertTrue(Set(t.due(now: s + 11 * s, limit: 10, centre: nil)).isSuperset(of: [5, 6]), "forced: due now")
    }
}
