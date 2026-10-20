import XCTest
import CoreGraphics
@testable import MirageCore

/// Synthetic two-finger traces: natural scrolls (fingers drifting apart or together by 5–15 %, sideways, not quite
/// parallel, with jitter) must scroll, deliberate pinches must zoom, and nothing switches mid-gesture.
final class TwoFingerClassifierTests: XCTestCase {
    /// A deterministic jitter source.
    struct Noise {
        var state: UInt64
        mutating func next() -> Double {   // −1…1
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: state >> 11) % 2_000_001) / 1_000_000 - 1
        }
    }

    /// One trace: finger positions sampled at 120 Hz.
    struct Trace {
        var name: String
        var samples: [(t: Double, a: CGPoint, b: CGPoint)]
    }

    /// Two fingers `spread` apart (along x), their centre travelling `travel` points at `degrees` from straight up (0°,
    /// 90° is to the right), the spread drifting by `drift` (a fraction) over the gesture, the second finger trailing by
    /// up to `lag` points, ±`jitter` points of noise, in `duration` seconds (eased: accelerate, settle).
    static func scroll(_ name: String, spread: Double, drift: Double, degrees: Double, travel: Double, duration: Double,
                       lag: Double = 3, jitter: Double = 1, rest: Double = 0, seed: UInt64 = 1) -> Trace {
        var n = Noise(state: seed)
        let ux = sin(degrees * .pi / 180), uy = -cos(degrees * .pi / 180)
        let c = CGPoint(x: 400, y: 600)
        var out: [(Double, CGPoint, CGPoint)] = []
        let steps = max(2, Int(duration * 120))
        // Resting fingers first (only jitter).
        let restSteps = Int(rest * 120)
        for i in 0...steps + restSteps {
            let t = Double(i) / 120
            let f = i <= restSteps ? 0 : Double(i - restSteps) / Double(steps)
            let e = f * f * (3 - 2 * f)
            let s = spread * (1 + drift * f)
            let m = CGPoint(x: c.x + ux * travel * e, y: c.y + uy * travel * e)
            let l = lag * sin(f * .pi)
            let j = i == 0 ? 0 : jitter
            let a = CGPoint(x: m.x - s / 2 + j * n.next(), y: m.y + j * n.next())
            let b = CGPoint(x: m.x + s / 2 - l * ux + j * n.next(), y: m.y - l * uy + j * n.next())
            out.append((t, a, b))
        }
        return Trace(name: name, samples: out)
    }

    /// Fingers `from` apart going to `to` apart about a centre that drifts `drift` points sideways; `anchored`: the first
    /// finger stays put and the second does all the moving.
    static func pinch(_ name: String, from s0: Double, to s1: Double, duration: Double, drift: Double = 0, anchored: Bool = false,
                      degrees: Double = 90, rest: Double = 0, seed: UInt64 = 7) -> Trace {
        var n = Noise(state: seed)
        let ux = sin(degrees * .pi / 180), uy = -cos(degrees * .pi / 180)   // the line between the fingers
        let c0 = CGPoint(x: 400, y: 600)
        var out: [(Double, CGPoint, CGPoint)] = []
        let steps = max(2, Int(duration * 120)), restSteps = Int(rest * 120)
        for i in 0...steps + restSteps {
            let f = i <= restSteps ? 0 : Double(i - restSteps) / Double(steps)
            let e = f * f * (3 - 2 * f)
            let s = s0 + (s1 - s0) * e
            let j = i == 0 ? 0 : 0.8
            var a: CGPoint, b: CGPoint
            if anchored {
                a = CGPoint(x: c0.x - s0 / 2 * ux, y: c0.y - s0 / 2 * uy)
                b = CGPoint(x: a.x + s * ux, y: a.y + s * uy)
            } else {
                let c = CGPoint(x: c0.x + drift * e * uy, y: c0.y - drift * e * ux)   // drift across the finger line
                a = CGPoint(x: c.x - s / 2 * ux, y: c.y - s / 2 * uy)
                b = CGPoint(x: c.x + s / 2 * ux, y: c.y + s / 2 * uy)
            }
            a.x += j * n.next(); a.y += j * n.next(); b.x += j * n.next(); b.y += j * n.next()
            out.append((Double(i) / 120, a, b))
        }
        return Trace(name: name, samples: out)
    }

    /// The decisions a trace goes through, and the centre's travel when the first one was made.
    func run(_ trace: Trace) -> (decisions: [TwoFingerClassifier.Decision], travelAtDecision: Double?) {
        var k = TwoFingerClassifier(trace.samples[0].a, trace.samples[0].b)
        var seen: [TwoFingerClassifier.Decision] = []
        var travel: Double?
        for s in trace.samples.dropFirst() {
            let d = k.update(s.a, s.b, time: s.t)
            if d != .undecided, seen.last != d {
                seen.append(d)
                if travel == nil {
                    let c = TwoFingerClassifier.midpoint(s.a, s.b)
                    travel = TwoFingerClassifier.distance(c, k.startCentroid)
                }
            }
        }
        return (seen, travel)
    }

    func testNaturalScrollsScroll() {
        var count = 0, seed: UInt64 = 1
        for spread in [30.0, 45, 60, 90, 120] {
            for drift in [-0.15, -0.1, -0.05, 0.05, 0.1, 0.15] {
                for degrees in [-20.0, -10, 0, 10, 20, 70, 90, 110] {   // vertical-ish and horizontal-ish
                    for (travel, duration) in [(60.0, 0.12), (150, 0.2), (300, 0.45), (-120, 0.3)] {
                        seed += 1
                        let t = Self.scroll("spread \(spread) drift \(drift) at \(degrees)° travel \(travel) in \(duration) s", spread: spread, drift: drift,
                                            degrees: degrees, travel: travel, duration: duration, lag: 4, jitter: 1.2, seed: seed)
                        let r = run(t)
                        XCTAssertEqual(r.decisions, [.scroll], t.name)
                        XCTAssertLessThanOrEqual(r.travelAtDecision ?? .infinity, 24, "\(t.name): the scroll starts promptly")
                        count += 1
                    }
                }
            }
        }
        XCTAssertEqual(count, 960)
    }

    /// Fingers that settle as they land (the distance between them changes quickly while the centre barely moves), then
    /// scroll; and fingers resting before a scroll.
    func testSettlingAndRestingFingersStillScroll() {
        var k = TwoFingerClassifier(CGPoint(x: 100, y: 400), CGPoint(x: 150, y: 400))
        XCTAssertEqual(k.update(CGPoint(x: 96, y: 401), CGPoint(x: 156, y: 399), time: 0.01), .undecided, "spread +10 pt, centre still")
        XCTAssertEqual(k.update(CGPoint(x: 95, y: 396), CGPoint(x: 158, y: 394), time: 0.03), .undecided)
        XCTAssertEqual(k.update(CGPoint(x: 95, y: 380), CGPoint(x: 158, y: 378), time: 0.05), .scroll, "the centre travels 21 pt: a scroll")
        XCTAssertEqual(k.update(CGPoint(x: 60, y: 380), CGPoint(x: 200, y: 378), time: 0.07), .scroll, "it stays a scroll, whatever the fingers do")
        let r = run(Self.scroll("rest then scroll", spread: 50, drift: 0.12, degrees: 5, travel: 200, duration: 0.3, rest: 0.4))
        XCTAssertEqual(r.decisions, [.scroll])
    }

    /// A strongly splayed scroll: the fingers spread 60 pt while travelling 80 pt together. The spread does not dominate.
    func testSplayedScrollIsAScroll() {
        let r = run(Self.scroll("splayed", spread: 60, drift: 1.0, degrees: 0, travel: 80, duration: 0.25, jitter: 0.5))
        XCTAssertEqual(r.decisions, [.scroll])
    }

    func testDeliberatePinchesPinch() {
        let traces = [
            Self.pinch("out, quick", from: 50, to: 170, duration: 0.25),
            Self.pinch("out, slow", from: 60, to: 150, duration: 0.8),
            Self.pinch("in", from: 180, to: 60, duration: 0.3),
            Self.pinch("in, vertical fingers", from: 160, to: 70, duration: 0.35, degrees: 0),
            Self.pinch("diagonal fingers", from: 70, to: 180, duration: 0.3, degrees: 45),
            Self.pinch("anchored thumb", from: 60, to: 150, duration: 0.3, anchored: true),
            Self.pinch("anchored, closing", from: 170, to: 80, duration: 0.3, anchored: true, degrees: 30),
            Self.pinch("with drift", from: 60, to: 170, duration: 0.3, drift: 15),
            Self.pinch("after a rest", from: 60, to: 160, duration: 0.3, rest: 0.5),
        ]
        for t in traces {
            XCTAssertEqual(run(t).decisions, [.pinch], t.name)
        }
    }

    /// Not enough to be a pinch: 30 pt (below the 40-pt floor), or 16 % of a wide spread (below 18 %). Neither zooms;
    /// with no travel they stay undecided (a two-finger tap if short).
    func testSmallSpreadChangesDoNotPinch() {
        XCTAssertEqual(run(Self.pinch("30 pt", from: 50, to: 80, duration: 0.2)).decisions, [])
        XCTAssertEqual(run(Self.pinch("16 % of 300", from: 300, to: 348, duration: 0.2)).decisions, [])
    }

    /// The decision is made early: fingers that travelled together past the window and only then spread stay a scroll.
    func testLateSpreadStaysAScroll() {
        var k = TwoFingerClassifier(CGPoint(x: 100, y: 600), CGPoint(x: 160, y: 600))
        for i in 1...30 { k.update(CGPoint(x: 100, y: 600 - Double(i) * 3), CGPoint(x: 160, y: 600 - Double(i) * 3), time: Double(i) / 120) }
        XCTAssertEqual(k.decision, .scroll)
        XCTAssertEqual(k.update(CGPoint(x: 40, y: 500), CGPoint(x: 240, y: 500), time: 0.3), .scroll)
    }

    // MARK: DirectTouch with the classifier

    private func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    /// Replays a trace through DirectTouch: what it does.
    func actions(_ trace: Trace) -> [DirectTouch.Action] {
        var d = DirectTouch()
        var out = d.began(1, at: trace.samples[0].a, time: 0) + d.began(2, at: trace.samples[0].b, time: 0)
        for s in trace.samples.dropFirst() { out += d.moved(1, to: s.a, time: s.t) + d.moved(2, to: s.b, time: s.t) }
        let last = trace.samples.last!
        out += d.ended(1, at: last.a, time: last.t + 0.008) + d.ended(2, at: last.b, time: last.t + 0.016)
        return out
    }

    func testDirectTouchScrollsANaturalScrollAndNeverZooms() {
        let a = actions(Self.scroll("phrz", spread: 48, drift: 0.12, degrees: 12, travel: 180, duration: 0.25, lag: 4))
        guard case .scrollBegan? = a.first else { return XCTFail("\(a.prefix(3))") }
        XCTAssertFalse(a.contains { if case .pinchBegan = $0 { return true }; if case .pinch = $0 { return true }; return false })
        guard case .scrollEnded? = a.last else { return XCTFail("\(a.suffix(2))") }
    }

    func testDirectTouchPinchStartsWithoutAJump() {
        let a = actions(Self.pinch("out", from: 60, to: 180, duration: 0.3))
        guard case .pinchBegan? = a.first else { return XCTFail("\(a.prefix(3))") }
        XCTAssertFalse(a.contains { if case .scroll = $0 { return true }; if case .scrollBegan = $0 { return true }; return false })
        let scales = a.compactMap { if case .pinch(let s, _) = $0 { return s }; return nil }
        XCTAssertLessThan(scales.first ?? 9, 1.1, "the zoom follows from where it was recognised")
        XCTAssertEqual(scales.last ?? 0, 180 / 100.0, accuracy: 0.15, "decided at ~40 pt of change (100 pt apart), then follows to 180")
        XCTAssertEqual(a.last, .pinchEnded)
    }

    /// A decided scroll holds until the fingers lift: no pinch however they spread, and a third finger does not turn it
    /// into a view pan.
    func testDirectTouchScrollIsLockedUntilTheFingersLift() {
        var d = DirectTouch()
        _ = d.began(1, at: pt(200, 400), time: 0); _ = d.began(2, at: pt(250, 400), time: 0)
        _ = d.moved(1, to: pt(200, 385), time: 0.02)
        let a = d.moved(2, to: pt(250, 385), time: 0.02)
        XCTAssertEqual(a.first, .scrollBegan(at: pt(225, 400)))
        XCTAssertEqual(d.moved(1, to: pt(120, 385), time: 0.04), [.scroll(dx: -40, dy: 0)], "fingers splaying 80 pt: still the scroll")
        XCTAssertEqual(d.began(3, at: pt(300, 300), time: 0.05), [], "a third finger changes nothing")
        XCTAssertEqual(d.moved(2, to: pt(250, 375), time: 0.06), [.scroll(dx: 0, dy: -5)])
        XCTAssertEqual(d.phase, .multi(.scroll))
    }

    /// The same for a pinch: once zooming, the fingers travelling together pan with the zoom (pinch actions), no scroll.
    func testDirectTouchPinchIsLockedUntilTheFingersLift() {
        var d = DirectTouch()
        _ = d.began(1, at: pt(200, 400), time: 0); _ = d.began(2, at: pt(260, 400), time: 0)
        _ = d.moved(1, to: pt(175, 400), time: 0.03)
        let a = d.moved(2, to: pt(285, 400), time: 0.03)   // 60 → 110 pt: +50 pt, 83 %, centre still
        XCTAssertEqual(a, [.pinchBegan(at: pt(230, 400))])
        let b = d.moved(1, to: pt(175, 300), time: 0.06) + d.moved(2, to: pt(285, 300), time: 0.06)
        XCTAssertFalse(b.contains { if case .scroll = $0 { return true }; return false })
        XCTAssertEqual(d.phase, .multi(.zoom))
    }
}

/// One axis per scroll gesture on the viewer (and, with the same rule, on the host).
final class ScrollAxisLockTests: XCTestCase {
    /// Deltas of a drag in `n` steps of `step` points at `degrees` from vertical, 120 Hz from `t0`.
    func drag(_ l: inout ScrollAxisLock, degrees: Double, step: Double, n: Int, t0: Double = 0) -> [(dx: Double, dy: Double)] {
        let dx = step * sin(degrees * .pi / 180), dy = -step * cos(degrees * .pi / 180)
        return (0..<n).compactMap { i in l.filter(dx: dx, dy: dy, time: t0 + Double(i) / 120) }
    }

    func testNearlyVerticalLocksVertical() {
        for degrees in [-24.0, -15, -5, 5, 15, 24] {
            var l = ScrollAxisLock(); l.begin()
            let out = drag(&l, degrees: degrees, step: 3, n: 40)
            XCTAssertEqual(l.axis, .vertical, "\(degrees)°")
            XCTAssertTrue(out.allSatisfy { $0.dx == 0 }, "\(degrees)°: no sideways travel at all")
            XCTAssertEqual(out.map(\.dy).reduce(0, +), -3 * cos(degrees * .pi / 180) * 40, accuracy: 1e-9, "the vertical travel all goes out")
        }
    }

    func testNearlyHorizontalLocksHorizontal() {
        var l = ScrollAxisLock(); l.begin()
        let out = drag(&l, degrees: 75, step: 4, n: 30)
        XCTAssertEqual(l.axis, .horizontal)
        XCTAssertTrue(out.allSatisfy { $0.dy == 0 })
    }

    /// The first ~10 pt decide: nothing goes out before, then the travel held back goes out at once along the axis.
    func testTheFirstTenPointsDecide() {
        var l = ScrollAxisLock(); l.begin()
        XCTAssertNil(l.filter(dx: 1, dy: -3, time: 0))
        XCTAssertNil(l.filter(dx: 1, dy: -3, time: 0.008))
        let first = l.filter(dx: 1, dy: -4, time: 0.016)   // 3, −10: 10.4 pt at 73° from horizontal
        XCTAssertEqual(first?.dx, 0); XCTAssertEqual(first?.dy, -10)
        XCTAssertEqual(l.axis, .vertical)
    }

    /// Motion along one axis only decides at once (a locked viewer's deltas reach the host like this).
    func testSingleAxisMotionDecidesAtOnce() {
        var l = ScrollAxisLock(); l.begin()
        XCTAssertEqual(l.filter(dx: 0, dy: 0.4, time: 0).map { [$0.dx, $0.dy] }, [0, 0.4])
        XCTAssertEqual(l.axis, .vertical)
    }

    /// Free only for a clearly diagonal, large motion: within 20° of 45° once it has travelled 30 pt.
    func testDiagonalLargeMotionIsFree() {
        for degrees in [30.0, 45, 60, -45, 135] {
            var l = ScrollAxisLock(); l.begin()
            let out = drag(&l, degrees: degrees, step: 3, n: 30)
            XCTAssertEqual(l.axis, .free, "\(degrees)°")
            XCTAssertEqual(out.map(\.dx).reduce(0, +), 90 * sin(degrees * .pi / 180), accuracy: 1e-9)
        }
        // Just outside the band: locked.
        var l = ScrollAxisLock(); l.begin()
        _ = drag(&l, degrees: 22, step: 3, n: 30)   // 68° from horizontal: 23° from 45°
        XCTAssertEqual(l.axis, .vertical)
    }

    /// A diagonal motion that stops short of 30 pt is not free: the lift decides it on its dominant axis, and what was
    /// held goes out there.
    func testShortDiagonalEndsOnItsDominantAxis() {
        var l = ScrollAxisLock(); l.begin()
        XCTAssertTrue(drag(&l, degrees: 40, step: 4, n: 5).isEmpty, "20 pt diagonal: still undecided")
        let e = l.end(vx: 400, vy: -500, time: 0.05)
        XCTAssertEqual(l.axis, .vertical)
        XCTAssertEqual(e.flush?.dx, 0)
        XCTAssertEqual(e.flush?.dy ?? 0, -20 * cos(40 * .pi / 180), accuracy: 1e-9)
        XCTAssertEqual(e.velocity.vx, 0); XCTAssertEqual(e.velocity.vy, -500)
    }

    /// Momentum keeps to the gesture's axis: its velocity is projected at the lift, and its deltas pass the lock.
    func testMomentumKeepsTheAxis() {
        var l = ScrollAxisLock(); l.begin()
        _ = drag(&l, degrees: 15, step: 6, n: 20)
        XCTAssertEqual(l.axis, .vertical)
        let e = l.end(vx: 350, vy: -1400, time: 20.0 / 120)
        XCTAssertNil(e.flush)
        XCTAssertEqual(e.velocity.vx, 0); XCTAssertEqual(e.velocity.vy, -1400)
        var m = ScrollMomentum(); m.start(vx: e.velocity.vx, vy: e.velocity.vy)
        var t = 20.0 / 120, sumY = 0.0, frames = 0
        while m.active {
            t += 1.0 / 60
            let d = m.step(dt: 1.0 / 60)
            // Even a stray sideways delta during the coast is dropped.
            if let o = l.filter(dx: d.dx + 0.5, dy: d.dy, time: t) { XCTAssertEqual(o.dx, 0); sumY += o.dy }
            frames += 1
        }
        XCTAssertGreaterThan(frames, 30); XCTAssertLessThan(sumY, -300)
        XCTAssertEqual(l.axis, .vertical)
    }

    /// A free gesture's momentum stays free.
    func testFreeMomentumStaysFree() {
        var l = ScrollAxisLock(); l.begin()
        _ = drag(&l, degrees: 45, step: 4, n: 20)
        let e = l.end(vx: 600, vy: -600, time: 0.2)
        XCTAssertEqual(e.velocity.vx, 600); XCTAssertEqual(e.velocity.vy, -600)
    }

    /// A 250 ms pause starts a new gesture; anything shorter (a momentum frame, a hitch) does not.
    func testAPauseStartsANewGesture() {
        var l = ScrollAxisLock(); l.begin()
        _ = drag(&l, degrees: 0, step: 3, n: 10)
        XCTAssertEqual(l.axis, .vertical)
        XCTAssertNil(l.filter(dx: 12, dy: 0, time: 10.0 / 120 + 0.2), "200 ms later: the same gesture, sideways locked out")
        let g = l.gesture
        _ = drag(&l, degrees: 90, step: 3, n: 10, t0: 10.0 / 120 + 0.2 + 0.3)
        XCTAssertEqual(l.gesture, g + 1)
        XCTAssertEqual(l.axis, .horizontal)
        // begin() (fingers down) also starts again.
        l.begin()
        XCTAssertNil(l.axis)
    }
}

/// The host's shaper on the event types an iOS viewer sends: the first scroll message (the whole travel that decided it),
/// 120 Hz finger deltas, then momentum at the display's rate, all precise, none with a phase.
final class ScrollShaperPathTests: XCTestCase {
    func nanos(_ s: Double) -> UInt64 { UInt64(1_000_000_000 + s * 1e9) }

    /// What an old (un-locked) viewer sends: a first chunk and every delta with a sideways part, then a decaying momentum
    /// with one too. Posted: vertical only, whole points, the vertical travel kept.
    func testUnlockedIPhoneScrollPostsVerticalOnly() {
        var s = ScrollShaper()
        var posted: [(Int, Int)] = []
        var raw = 0.0
        func send(_ dx: Double, _ dy: Double, _ t: Double) { raw += dy; if let p = s.shape(dx: dx, dy: dy, nanos: nanos(t)) { posted.append((p.dx, p.dy)) } }
        send(-13.4, 83.2, 0)   // phrz's log: wheel -13,83 px
        var t = 0.0
        for i in 0..<20 { t += 1.0 / 120; send(-2.1 + Double(i % 3) * 0.4, 9.7, t) }
        var v = (x: -150.0, y: 1100.0)
        for _ in 0..<60 { t += 1.0 / 60; send(v.x / 60, v.y / 60, t); v.x *= 0.95; v.y *= 0.95 }
        XCTAssertEqual(s.axis, .vertical)
        XCTAssertTrue(posted.allSatisfy { $0.0 == 0 }, "not one sideways point")
        XCTAssertEqual(Double(posted.map(\.1).reduce(0, +)), raw, accuracy: 1, "whole points, remainder carried")
    }

    /// A locked viewer sends single-axis deltas: the host takes the same axis at once, even for a tiny first delta.
    func testLockedViewerDeltasAreTakenAtOnce() {
        var s = ScrollShaper()
        XCTAssertEqual(s.shape(dx: 1.6, dy: 0, nanos: nanos(0)).map { [$0.dx, $0.dy] }, [1, 0])
        XCTAssertEqual(s.axis, .horizontal)
    }

    /// A noisy tiny first delta no longer decides alone: the first ~10 pt do.
    func testATinyNoisyFirstDeltaDoesNotDecide() {
        var s = ScrollShaper()
        XCTAssertNil(s.shape(dx: 0.9, dy: 0.3, nanos: nanos(0)), "under 10 pt: undecided")
        var posted: [(Int, Int)] = []
        for i in 1...10 { if let p = s.shape(dx: 0.3, dy: -2.5, nanos: nanos(Double(i) / 120)) { posted.append((p.dx, p.dy)) } }
        XCTAssertEqual(s.axis, .vertical)
        XCTAssertTrue(posted.allSatisfy { $0.0 == 0 })
    }

    /// A clearly diagonal, large gesture (a free one from the viewer) posts both axes.
    func testFreeGesturePostsBothAxes() {
        var s = ScrollShaper()
        let p = s.shape(dx: 35, dy: -38, nanos: nanos(0))
        XCTAssertEqual(s.axis, .free)
        XCTAssertEqual(p.map { [$0.dx, $0.dy] }, [35, -38])
    }

    /// Momentum after a 250 ms gap is a new gesture (decided again); within it, the axis holds.
    func testMomentumWithinTheGapKeepsTheAxisAndAPauseStartsAgain() {
        var s = ScrollShaper()
        _ = s.shape(dx: 0, dy: -20, nanos: nanos(0))
        XCTAssertEqual(s.shape(dx: 5, dy: -0.2, nanos: nanos(0.2)).map { [$0.dx, $0.dy] } ?? [0, 0], [0, 0], "200 ms later: sideways dropped")
        XCTAssertEqual(s.axis, .vertical)
        XCTAssertEqual(s.shape(dx: 15, dy: 1, nanos: nanos(0.5)).map { [$0.dx, $0.dy] }, [15, 0])
        XCTAssertEqual(s.axis, .horizontal)
    }
}
