import XCTest
@testable import MirageCore

final class RefinementPacerTests: XCTestCase {
    /// An idle link with a backlog refines at half the target or more, with a few windows animating on the desktop.
    /// Field case (phrz on an iPhone, mac-daddy 2026-10-20): 800 kbps target, srtt 220 ms, three or more small changed
    /// tiles every ~100 ms; refinement yielded 150 ms after each and sent one block per round trip: 0 kbps for minutes
    /// with backlog, ~40 % of the target at best.
    func testAnIdleLinkWithABacklogRefinesAtHalfTheTargetOrMore() {
        let targetBytesPerSecond = 100_000.0            // 800 kbps
        let tileBytesPerSecond = targetBytesPerSecond * 0.8
        let srtt = 220_000_000.0, encodeNanos: UInt64 = 80_000_000
        var pacer = RefinementPacer()
        var tokens = tileBytesPerSecond * 0.5
        var linkFreeAt: UInt64 = 0
        var acks: [(at: UInt64, seq: UInt32)] = []
        var seq: UInt32 = 0, refined = 0, direct = 0
        let step: UInt64 = 10_000_000, end: UInt64 = 10_000_000_000
        func transmit(_ bytes: Int, at t: UInt64) -> UInt64 {
            linkFreeAt = max(linkFreeAt, t) + UInt64(Double(bytes) / targetBytesPerSecond * 1e9)
            return linkFreeAt
        }
        var now: UInt64 = 0
        while now < end {
            tokens = min(tileBytesPerSecond * 0.5, tokens + tileBytesPerSecond * Double(step) / 1e9)
            for a in acks where a.at <= now { pacer.acked(msgSeq: a.seq) }
            acks.removeAll { $0.at <= now }
            // Animating windows: three 300-byte changed tiles every 100 ms, sent at once (they are what people see).
            if now % 100_000_000 == 0 {
                let b = 900
                tokens -= Double(b); direct += b
                _ = transmit(b, at: now)
                pacer.noteDirect(bytes: b, now: now)
            }
            // Refinement: a block of the backlog whenever the pacer and the budget allow.
            if !pacer.yields(now: now, tileBytesPerSecond: tileBytesPerSecond), pacer.canStartBlock(tileBytesPerSecond: tileBytesPerSecond), tokens > 0 {
                let area = RefinementPacer.blockArea(tileBytesPerSecond: tileBytesPerSecond, layerArea: 3200 * 1800)
                let bytes = Int(area * 0.5)
                let id = pacer.start(layer: 0, estimate: bytes, now: now)
                tokens -= Double(bytes)
                seq &+= 1
                pacer.sent(id: id, msgSeq: seq, bytes: bytes, now: now + encodeNanos)
                acks.append((transmit(bytes, at: now + encodeNanos) + UInt64(srtt / 2), seq))
                refined += bytes
            }
            now += step
        }
        let refinedRate = Double(refined) / (Double(end) / 1e9)
        XCTAssertGreaterThanOrEqual(refinedRate, targetBytesPerSecond * 0.5, "refined \(Int(refinedRate * 8 / 1000)) kbps of 800")
        XCTAssertLessThanOrEqual(Double(refined + direct), tileBytesPerSecond * (Double(end) / 1e9 + 0.5 + RefinementPacer.blockSeconds), "within the tile budget (the bucket starts half full; the last block may overdraw)")
        XCTAssertLessThanOrEqual(Double(pacer.inFlightBytes), tileBytesPerSecond * (RefinementPacer.blockWindowSeconds + RefinementPacer.blockSeconds), "bounded in flight")
    }

    func testRefinementYieldsOnlyToChangesThatUseTheLink() {
        var p = RefinementPacer()
        let budget = 80_000.0                            // 12 KB per 150 ms; a quarter is 3 KB
        p.noteDirect(bytes: 900, now: 1_000_000_000)     // a clock, a caret, three small tiles of an animating window
        XCTAssertFalse(p.yields(now: 1_000_000_000, tileBytesPerSecond: budget))
        p.noteDirect(bytes: 4_000, now: 1_050_000_000)   // a burst of typing or a menu opening
        XCTAssertTrue(p.yields(now: 1_100_000_000, tileBytesPerSecond: budget))
        XCTAssertFalse(p.yields(now: 1_250_000_000, tileBytesPerSecond: budget), "150 ms later refinement resumes")
    }

    func testBlocksArePipelinedWithinAWindowAndExpireWithoutAnAck() {
        var p = RefinementPacer()
        let budget = 80_000.0                            // window 40 KB; a block 20 KB
        XCTAssertTrue(p.canStartBlock(tileBytesPerSecond: budget))
        let a = p.start(layer: 0, estimate: 20_000, now: 0)
        XCTAssertTrue(p.canStartBlock(tileBytesPerSecond: budget), "a second block goes while the first is unacked")
        let b = p.start(layer: 7, estimate: 20_000, now: 0)
        XCTAssertFalse(p.canStartBlock(tileBytesPerSecond: budget), "two blocks fill the window")
        p.sent(id: a, msgSeq: 11, bytes: 18_000, now: 10)
        p.sent(id: b, msgSeq: 12, bytes: 25_000, now: 10)
        XCTAssertTrue(p.acked(msgSeq: 11))
        XCTAssertFalse(p.acked(msgSeq: 99), "not a block")
        XCTAssertTrue(p.canStartBlock(tileBytesPerSecond: budget))
        p.dropped(id: b)
        XCTAssertTrue(p.isIdle)
        _ = p.start(layer: 0, estimate: 50_000, now: 0)
        XCTAssertTrue(p.canStartBlock(tileBytesPerSecond: 10_000) == false)
        XCTAssertEqual(p.expire(now: 9_000_000_000, srttNanos: 200_000_000), 0, "a slow ack is queued, not lost")
        XCTAssertEqual(p.expire(now: 10_100_000_000, srttNanos: 200_000_000), 1, "10 s without an ack")
        XCTAssertTrue(p.isIdle)
    }

    func testChromeBandsFromTheScreenInsets() {
        // 1600x900 pt at 2x, a 24-pt menu bar, the Dock at the bottom (70 pt).
        XCTAssertEqual(DesktopChrome.bands(width: 3200, height: 1800, pxPerPoint: 2, top: 24, bottom: 70, left: 0, right: 0),
                       [PixelRect(x: 0, y: 0, width: 3200, height: 48), PixelRect(x: 0, y: 1660, width: 3200, height: 140)])
        // The Dock on the left; a hidden Dock and menu bar give nothing.
        XCTAssertEqual(DesktopChrome.bands(width: 3200, height: 1800, pxPerPoint: 2, top: 24, bottom: 0, left: 60.5, right: 0),
                       [PixelRect(x: 0, y: 0, width: 3200, height: 48), PixelRect(x: 0, y: 0, width: 121, height: 1800)])
        XCTAssertEqual(DesktopChrome.bands(width: 3200, height: 1800, pxPerPoint: 2, top: 0, bottom: 0, left: 0, right: 0), [])
    }

    /// Show Desktop: a pushed-aside window is captured blank; those frames are dropped for a window seen opaque, never
    /// for one that is transparent from the start, and partly transparent content is kept.
    func testShowDesktopBlankCapturesAreDropped() {
        var b = WindowBlanking()
        XCTAssertTrue(b.keep(alphas: [255, 255, 255, 255, 255]))
        XCTAssertFalse(b.keep(alphas: [0, 0, 0, 0, 0]), "pushed aside: blank, dropped")
        XCTAssertFalse(b.keep(alphas: [0, 0, 3, 0, 255]), "four of five transparent: still blank")
        XCTAssertTrue(b.keep(alphas: [255, 255, 255, 255, 255]), "back")
        XCTAssertTrue(b.keep(alphas: [200, 0, 0, 255, 255]), "partly transparent content is a picture")
        var overlay = WindowBlanking()
        XCTAssertTrue(overlay.keep(alphas: [0, 0, 0, 0, 0]), "a window never seen opaque keeps its frames")
    }
}
