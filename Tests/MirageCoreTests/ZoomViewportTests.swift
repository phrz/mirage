import XCTest
import CoreGraphics
@testable import MirageCore

/// The iOS viewer's presentation-only zoom and pan (no message reaches the host from any of this).
final class ZoomViewportTests: XCTestCase {
    /// An iPhone in portrait: 393×852 pt, safe area 59 top and 34 bottom; a 16:10 stream.
    private func portrait() -> ZoomViewport {
        var v = ZoomViewport()
        v.setLayout(container: CGRect(x: 0, y: 59, width: 393, height: 759), keyboardTop: nil, content: CGSize(width: 1600, height: 1000))
        return v
    }

    private func assertRect(_ r: CGRect, _ e: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.minX, e.minX, accuracy: 0.01, file: file, line: line); XCTAssertEqual(r.minY, e.minY, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(r.width, e.width, accuracy: 0.01, file: file, line: line); XCTAssertEqual(r.height, e.height, accuracy: 0.01, file: file, line: line)
    }

    func testFitFillsTheContainerWidthInPortraitAndTheHeightInLandscape() {
        let v = portrait()
        // 393 wide → 245.6 high, centred in the safe area.
        assertRect(v.pictureRect, CGRect(x: 0, y: 59 + (759 - 245.625) / 2, width: 393, height: 245.625))
        var l = ZoomViewport()
        l.setLayout(container: CGRect(x: 59, y: 0, width: 734, height: 393), keyboardTop: nil, content: CGSize(width: 1600, height: 1000))
        assertRect(l.pictureRect, CGRect(x: 59 + (734 - 628.8) / 2, y: 0, width: 628.8, height: 393))
    }

    func testOneToOneAndTheZoomRange() {
        var v = portrait()
        // A 3024 px wide host display on a 3× screen: fit is 1179 device pixels wide.
        let one = v.oneToOneZoom(hostPixelWidth: 3024, screenScale: 3)
        XCTAssertEqual(one, 3024.0 / 1179, accuracy: 1e-9)
        v.setZoomRange(oneToOne: one)
        XCTAssertEqual(v.maxZoom, one * 1.5, accuracy: 1e-9)
        v.setZoomRange(oneToOne: 1.2)
        XCTAssertEqual(v.maxZoom, 3)   // at least 3×
    }

    func testZoomKeepsThePointUnderThePinchCentre() {
        var v = portrait()
        v.setZoomRange(oneToOne: 2.56)
        let anchor = CGPoint(x: 100, y: 450)
        let before = v.normalized(anchor)
        v.setZoom(3.5, about: anchor)   // 1375 × 860: larger than the container both ways, so nothing clamps
        XCTAssertEqual(v.zoom, 3.5)
        let after = v.viewPoint(before)
        XCTAssertEqual(after.x, anchor.x, accuracy: 0.01)
        XCTAssertEqual(after.y, anchor.y, accuracy: 0.01)
        // Beyond the range: clamped; below fit: fit.
        v.setZoom(50, about: anchor); XCTAssertEqual(v.zoom, v.maxZoom)
        v.setZoom(0.2, about: anchor); XCTAssertEqual(v.zoom, 1)
        assertRect(v.pictureRect, portrait().pictureRect)
    }

    func testPanStopsAtTheEdgesAndAFittingAxisStaysCentred() {
        var v = portrait()
        v.setZoomRange(oneToOne: 2.56)
        v.setZoom(2, about: CGPoint(x: 196.5, y: 438.5))   // 786 × 491: wider than the container, still shorter than it
        let y = v.pictureRect.minY
        XCTAssertEqual(v.pictureRect.midY, 59 + 759 / 2, accuracy: 0.01)
        v.pan(by: CGPoint(x: 10_000, y: 300))
        XCTAssertEqual(v.pictureRect.minX, 0, accuracy: 0.01)        // left edge meets the container's
        XCTAssertEqual(v.pictureRect.minY, y, accuracy: 0.01)        // vertical: fits, does not move
        v.pan(by: CGPoint(x: -10_000, y: 0))
        XCTAssertEqual(v.pictureRect.maxX, 393, accuracy: 0.01)
        v.setZoom(3.5, about: CGPoint(x: 196.5, y: 438.5))         // now taller than the container too
        v.pan(by: CGPoint(x: 0, y: 10_000))
        XCTAssertEqual(v.pictureRect.minY, 59, accuracy: 0.01)
        v.pan(by: CGPoint(x: 0, y: -10_000))
        XCTAssertEqual(v.pictureRect.maxY, 59 + 759, accuracy: 0.01)
    }

    func testKeyboardLiftsAFittingPictureAndBoundsAZoomedOne() {
        var v = portrait()
        // Keyboard top at 470: the 245.6 pt picture centred at 345…591 is lifted to end at 470.
        v.setLayout(container: v.container, keyboardTop: 470, content: v.content)
        XCTAssertEqual(v.pictureRect.maxY, 470, accuracy: 0.01)
        XCTAssertEqual(v.zoom, 1)
        v.setLayout(container: v.container, keyboardTop: nil, content: v.content)
        XCTAssertEqual(v.pictureRect.midY, 59 + 759 / 2, accuracy: 0.01)
        // Zoomed with the keyboard up: the bottom can be panned up to the keyboard's top, no further.
        v.setZoom(3, about: CGPoint(x: 196.5, y: 438.5))
        v.setLayout(container: v.container, keyboardTop: 470, content: v.content)
        v.pan(by: CGPoint(x: 0, y: -10_000))
        XCTAssertEqual(v.pictureRect.maxY, 470, accuracy: 0.01)
    }

    func testRotationKeepsZoomAndTheCentrePoint() {
        var v = portrait()
        v.setZoom(2.5, about: CGPoint(x: 120, y: 400))
        let centre = v.normalized(CGPoint(x: v.visible.midX, y: v.visible.midY))
        v.setLayout(container: CGRect(x: 59, y: 0, width: 734, height: 393), keyboardTop: nil, content: v.content)
        XCTAssertEqual(v.zoom, 2.5)
        let c = v.normalized(CGPoint(x: v.visible.midX, y: v.visible.midY))
        XCTAssertEqual(c.x, centre.x, accuracy: 0.01)
        XCTAssertEqual(c.y, centre.y, accuracy: 0.01)
    }

    func testPointerFollowPushesTheViewOnlyWhenThePictureOverflows() {
        var v = portrait()
        let fit = v
        v.follow(CGPoint(x: 390, y: 400))          // at fit nothing overflows: nothing moves
        XCTAssertEqual(v, fit)
        v.setZoom(3, about: CGPoint(x: 196.5, y: 438.5))
        let o = v.origin
        v.follow(CGPoint(x: 200, y: 438))          // well inside: nothing
        XCTAssertEqual(v.origin, o)
        // The pointer at the right edge: the picture moves left until the pointer is 40 pt inside.
        let n = v.normalized(CGPoint(x: 390, y: 438))
        v.follow(CGPoint(x: 390, y: 438))
        XCTAssertEqual(v.viewPoint(n).x, 393 - 40, accuracy: 0.01)
        // At the picture's own right edge the push stops: the picture's edge meets the container's.
        for _ in 0..<100 { v.follow(v.viewPoint(CGPoint(x: 1, y: 0.5))) }
        XCTAssertEqual(v.pictureRect.maxX, 393, accuracy: 0.01)
        // Keyboard up (landscape-like case at fit): a pointer below its top lifts the overflowing picture.
        var l = ZoomViewport()
        l.setLayout(container: CGRect(x: 59, y: 0, width: 734, height: 393), keyboardTop: 190, content: CGSize(width: 1600, height: 1000))
        let p = l.viewPoint(CGPoint(x: 0.5, y: 0.8))
        XCTAssertGreaterThan(p.y, 190)
        l.follow(p)
        XCTAssertEqual(l.viewPoint(CGPoint(x: 0.5, y: 0.8)).y, 190 - 40, accuracy: 0.01)
    }

    func testCaretFollowFromOnePointFiveTimesAndGlidesThere() {
        var v = portrait()
        v.setLayout(container: v.container, keyboardTop: 470, content: v.content)
        let caretPx = CGRect(x: 1500, y: 900, width: 2, height: 30)    // near the picture's bottom-right
        v.setZoom(1.4, about: CGPoint(x: 196.5, y: 300))
        XCTAssertNil(v.caretTarget(v.viewRect(contentRect: caretPx)))  // below 1.5×: never
        v.setZoom(2.5, about: CGPoint(x: 196.5, y: 300))
        let caret = v.viewRect(contentRect: caretPx)
        XCTAssertFalse(v.visible.insetBy(dx: 24, dy: 24).contains(caret))
        guard let target = v.caretTarget(caret) else { return XCTFail("no target") }
        var t = v; t.set(zoom: v.zoom, origin: target)
        let c = t.viewRect(contentRect: caretPx)
        XCTAssertLessThanOrEqual(c.maxY, 470 - 24 + 0.01)              // above the keyboard
        XCTAssertLessThanOrEqual(c.maxX, 393 - 24 + 0.01)
        XCTAssertNil(t.caretTarget(c))                                  // there: nothing more to do
        // Gentle: one 60 Hz frame covers a small part of the way; a second of frames gets there.
        var g = v
        g.glide(toward: target, dt: 1.0 / 60)
        let first = abs(g.origin.y - v.origin.y), whole = abs(target.y - v.origin.y)
        XCTAssertGreaterThan(first, 0); XCTAssertLessThan(first, whole * 0.25)
        var arrived = false
        for _ in 0..<60 where !arrived { arrived = g.glide(toward: target, dt: 1.0 / 60) }
        XCTAssertTrue(arrived)
        XCTAssertEqual(g.origin, target)
    }

    func testToggleTargetIsOneToOneOrFit() {
        var v = portrait()
        v.setZoomRange(oneToOne: 2.56)
        XCTAssertEqual(v.toggleTarget(oneToOne: 2.56), 2.56)
        XCTAssertEqual(v.toggleTarget(oneToOne: 0.8), 2)           // a host smaller than the fitted picture: 2×
        v.setZoom(2.56, about: CGPoint(x: 100, y: 400))
        XCTAssertEqual(v.toggleTarget(oneToOne: 2.56), 1)
    }

    func testOverlaysMapThroughThePictureAtEveryZoom() {
        // The cursor, the typeahead glyphs and the scroll prediction all map picture pixels through pictureRect.
        var v = portrait()
        for z in [1.0, 1.7, 2.56, 3.84] {
            v.setZoomRange(oneToOne: 2.56)
            v.setZoom(z, about: CGPoint(x: 80, y: 420))
            let r = v.pictureRect
            let glyph = v.viewRect(contentRect: CGRect(x: 800, y: 500, width: 16, height: 30))
            XCTAssertEqual(glyph.minX, r.minX + r.width / 2, accuracy: 0.01)
            XCTAssertEqual(glyph.minY, r.minY + r.height / 2, accuracy: 0.01)
            XCTAssertEqual(glyph.width, 16 * r.width / 1600, accuracy: 0.01)
            let p = v.viewPoint(CGPoint(x: 0.5, y: 0.5))
            XCTAssertEqual(p.x, glyph.minX, accuracy: 0.01); XCTAssertEqual(p.y, glyph.minY, accuracy: 0.01)
            let back = v.normalized(p)
            XCTAssertEqual(back.x, 0.5, accuracy: 1e-9); XCTAssertEqual(back.y, 0.5, accuracy: 1e-9)
        }
    }

    // MARK: Bounds: every corner of the picture can be brought into view

    /// A phone's geometry as DesktopUIView sees it (view points): its bounds, its safe area in both orientations, the
    /// control pill's bottom edge and the keyboard's height (with the accessory row).
    private struct Phone {
        let name: String
        let size: CGSize                       // portrait
        let portraitInsets: (top: Double, bottom: Double)
        let landscapeInsets: (side: Double, bottom: Double)
        let pillBottom: (portrait: Double, landscape: Double)
        let keyboard: (portrait: Double, landscape: Double)
    }
    private let phones = [
        Phone(name: "iPhone 17 Pro Max", size: CGSize(width: 440, height: 956), portraitInsets: (62, 34), landscapeInsets: (62, 20), pillBottom: (95, 37), keyboard: (382, 255)),
        Phone(name: "iPhone 17 Pro", size: CGSize(width: 402, height: 874), portraitInsets: (62, 34), landscapeInsets: (62, 20), pillBottom: (95, 37), keyboard: (382, 255)),
        Phone(name: "iPhone SE", size: CGSize(width: 375, height: 667), portraitInsets: (20, 0), landscapeInsets: (0, 0), pillBottom: (53, 37), keyboard: (306, 243)),
    ]

    /// The viewport as DesktopUIView lays it out: the picture fitted into the safe area (in landscape the full height),
    /// visible where the safe area, the pill and the keyboard leave it.
    private func layout(_ phone: Phone, landscape: Bool, keyboard: Bool, content: CGSize) -> (ZoomViewport, CGSize) {
        let b = landscape ? CGSize(width: phone.size.height, height: phone.size.width) : phone.size
        let (top, left, bottom, right) = landscape
            ? (0.0, phone.landscapeInsets.side, phone.landscapeInsets.bottom, phone.landscapeInsets.side)
            : (phone.portraitInsets.top, 0.0, phone.portraitInsets.bottom, 0.0)
        let container = landscape
            ? CGRect(x: left, y: 0, width: b.width - left - right, height: b.height)
            : CGRect(x: 0, y: top, width: b.width, height: b.height - top - bottom)
        let pill = landscape ? phone.pillBottom.landscape : phone.pillBottom.portrait
        let clearTop = max(top, pill)
        let unobstructed = CGRect(x: left, y: clearTop, width: b.width - left - right, height: b.height - bottom - clearTop)
        let k = keyboard ? Double(b.height) - (landscape ? phone.keyboard.landscape : phone.keyboard.portrait) : nil
        var v = ZoomViewport()
        v.setLayout(container: container, unobstructed: unobstructed, keyboardTop: k, content: content)
        return (v, b)
    }

    /// At several zooms, in both orientations, with and without the keyboard: a pan toward each corner brings that corner
    /// pixel of the picture into the visible area, the picture's edges meeting the visible area's edges exactly where it
    /// is larger than it, and the scroll view's insets put its range (where the rubber band starts) right there.
    func testEveryCornerPixelIsReachableAtEveryZoomOrientationAndKeyboard() {
        let contents = [CGSize(width: 3840, height: 2160), CGSize(width: 3024, height: 1964), CGSize(width: 1600, height: 1000)]
        var checked = 0
        for phone in phones { for content in contents { for landscape in [false, true] { for keyboard in [false, true] {
            let (base, size) = layout(phone, landscape: landscape, keyboard: keyboard, content: content)
            let oneToOne = base.oneToOneZoom(hostPixelWidth: Double(content.width), screenScale: 3)
            for z in [1.0, 1.5, 2.0, 3.0, oneToOne, 99] {
                var v = base
                v.setZoomRange(oneToOne: oneToOne)
                v.setZoom(z, about: CGPoint(x: v.visible.midX, y: v.visible.midY))
                let vis = v.visible
                let tag = "\(phone.name) \(landscape ? "landscape" : "portrait")\(keyboard ? " keyboard" : "") \(Int(content.width))x\(Int(content.height)) at \(String(format: "%.2f", v.zoom))x"
                for (sx, sy, name) in [(1.0, 1.0, "top-left"), (-1.0, 1.0, "top-right"), (1.0, -1.0, "bottom-left"), (-1.0, -1.0, "bottom-right")] {
                    var c = v
                    c.pan(by: CGPoint(x: sx * 100_000, y: sy * 100_000))
                    let r = c.pictureRect
                    let px = CGRect(x: sx > 0 ? 0 : content.width - 1, y: sy > 0 ? 0 : content.height - 1, width: 1, height: 1)
                    let corner = c.viewRect(contentRect: px)
                    XCTAssertTrue(vis.insetBy(dx: -0.01, dy: -0.01).contains(corner), "\(tag): the \(name) pixel \(corner) is outside the visible \(vis)")
                    // Where the picture is larger than the visible area, its edge meets the visible area's edge.
                    if r.width > vis.width + 0.5 { XCTAssertEqual(sx > 0 ? r.minX : r.maxX, sx > 0 ? vis.minX : vis.maxX, accuracy: 0.01, "\(tag) \(name) x") }
                    else { XCTAssertTrue(r.minX >= vis.minX - 0.51 && r.maxX <= vis.maxX + 0.51, "\(tag): a fitting width stays inside") }
                    if r.height > vis.height + 0.5 { XCTAssertEqual(sy > 0 ? r.minY : r.maxY, sy > 0 ? vis.minY : vis.maxY, accuracy: 0.01, "\(tag) \(name) y") }
                    else { XCTAssertTrue(r.minY >= vis.minY - 0.51 && r.maxY <= vis.maxY + 0.51, "\(tag): a fitting height stays inside") }
                    // A UIScrollView with these insets stops (and starts its rubber band) exactly here: its contentOffset
                    // runs from −inset to contentSize + inset − bounds.
                    let i = c.scrollInsets(viewSize: size)
                    let offset = CGPoint(x: sx > 0 ? -i.left : r.width + i.right - size.width, y: sy > 0 ? -i.top : r.height + i.bottom - size.height)
                    XCTAssertEqual(-offset.x, r.minX, accuracy: 0.01, "\(tag) \(name): the scroll view's x range ends where the pan does")
                    XCTAssertEqual(-offset.y, r.minY, accuracy: 0.01, "\(tag) \(name): the scroll view's y range ends where the pan does")
                    XCTAssertGreaterThanOrEqual(min(i.top, i.left, i.bottom, i.right), -0.51, "\(tag): insets are never negative")
                    checked += 1
                }
            }
        } } } }
        XCTAssertEqual(checked, 3 * 3 * 2 * 2 * 6 * 4)
    }

    /// phrz (2026-10-21): zoomed in, the top-right of the picture (the menu bar's status items, Control Center) stayed
    /// under the control pill, and in landscape the bottom (the Dock) under the home indicator: the pan stopped at the
    /// container, which reaches under both. Now the pan goes on until those edges clear them.
    func testThePillAndTheHomeIndicatorNeverHideAnEdge() {
        let content = CGSize(width: 3840, height: 2160)
        // Portrait at 1:1 (taller than the visible area): the top edge comes down to the pill's bottom.
        var (p, _) = layout(phones[0], landscape: false, keyboard: false, content: content)
        p.setZoomRange(oneToOne: 3.9); p.setZoom(3.9, about: CGPoint(x: 220, y: 500))
        p.pan(by: CGPoint(x: -100_000, y: 100_000))
        XCTAssertEqual(p.pictureRect.minY, 95, accuracy: 0.01)
        XCTAssertEqual(p.pictureRect.maxX, 440, accuracy: 0.01)
        // Landscape at fit: the picture fills the height under the pill and the home indicator, so it pans by both.
        var (l, _) = layout(phones[0], landscape: true, keyboard: false, content: content)
        XCTAssertEqual(l.pictureRect.minY, 0, accuracy: 0.01, "fitted to the full height")
        XCTAssertEqual(l.pictureRect.height, 440, accuracy: 0.01)
        l.pan(by: CGPoint(x: 0, y: 100_000)); XCTAssertEqual(l.pictureRect.minY, 37, accuracy: 0.01)
        l.pan(by: CGPoint(x: 0, y: -100_000)); XCTAssertEqual(l.pictureRect.maxY, 420, accuracy: 0.01)
        // Landscape zoomed: the left and right edges stop at the safe area (the Dynamic Island's side, the rounded corners).
        l.setZoom(2, about: CGPoint(x: 478, y: 220))
        l.pan(by: CGPoint(x: 100_000, y: 0)); XCTAssertEqual(l.pictureRect.minX, 62, accuracy: 0.01)
        l.pan(by: CGPoint(x: -100_000, y: 0)); XCTAssertEqual(l.pictureRect.maxX, 956 - 62, accuracy: 0.01)
    }

    /// A layout that has not changed leaves the picture where the scroll view put it (its rubber band, past the range);
    /// any real change clamps it.
    func testAnUnchangedLayoutLeavesTheRubberBandAlone() {
        var v = portrait()
        v.setZoom(3, about: CGPoint(x: 196.5, y: 438.5))
        let past = CGPoint(x: 30, y: v.origin.y)   // 30 pt past the left edge
        v.scrolled(to: past)
        v.setLayout(container: v.container, keyboardTop: nil, content: v.content)
        XCTAssertEqual(v.origin, past)
        v.setLayout(container: v.container, keyboardTop: 600, content: v.content)
        XCTAssertEqual(v.origin.x, 0, accuracy: 0.01)
    }
}
