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
}
