import XCTest
import CoreGraphics
@testable import MirageCore

/// iPhone Duo poses from synthetic geometry (DESIGN §3.11): the simulator's fold poses are set in Xcode's Device Hub only,
/// so the classifier is checked here on the shapes the `.division` region takes.
final class DuoPoseTests: XCTestCase {
    /// The inner display in points (2007×2853 px at 3×), held upright: a laptop's hinge runs side to side across it.
    private let upright = CGRect(x: 0, y: 0, width: 669, height: 951)
    /// The same display turned a quarter: a book's hinge runs top to bottom.
    private let sideways = CGRect(x: 0, y: 0, width: 951, height: 669)
    /// The outer display.
    private let outer = CGRect(x: 0, y: 0, width: 402, height: 874)

    func testClosedAndOpenFlatComeFromTheSizeClassAlone() {
        XCTAssertEqual(DuoPose.classify(bounds: outer, compactWidth: true, divisions: []).kind, .closed)
        XCTAssertEqual(DuoPose.classify(bounds: sideways, compactWidth: false, divisions: []).kind, .openFlat)
        XCTAssertEqual(DuoPose.classify(bounds: upright, compactWidth: false, divisions: []).kind, .openFlat)
    }

    func testAnInactiveDivisionIsOpenFlat() {
        let d = DuoPose.Division(frame: CGRect(x: 0, y: 463, width: 669, height: 24), isActive: false)
        let p = DuoPose.classify(bounds: upright, compactWidth: false, divisions: [d])
        XCTAssertEqual(p.kind, .openFlat)
        XCTAssertNil(p.division)
        XCTAssertEqual(p.upperRegion, upright)
        XCTAssertNil(p.lowerRegion)
    }

    func testAHorizontalHingeIsLaptopWithThePictureAboveIt() {
        // A 12 pt hinge with 6 pt margins either side for controls.
        let d = DuoPose.Division(frame: CGRect(x: 0, y: 463, width: 669, height: 24), hinge: CGRect(x: 0, y: 469, width: 669, height: 12))
        let p = DuoPose.classify(bounds: upright, compactWidth: false, divisions: [d])
        XCTAssertEqual(p.kind, .laptop)
        XCTAssertTrue(p.isFolded)
        XCTAssertEqual(p.upperRegion, CGRect(x: 0, y: 0, width: 669, height: 469))
        XCTAssertEqual(p.lowerRegion, CGRect(x: 0, y: 487, width: 669, height: 464))
        let i = p.pictureInsets
        XCTAssertEqual(i.top, 0); XCTAssertEqual(i.left, 0); XCTAssertEqual(i.right, 0)
        XCTAssertEqual(i.bottom, 951 - 469)
    }

    func testAVerticalHingeIsBookAndReservesNothingForThePicture() {
        let d = DuoPose.Division(frame: CGRect(x: 463, y: 0, width: 24, height: 669), hinge: CGRect(x: 469, y: 0, width: 12, height: 669))
        let p = DuoPose.classify(bounds: sideways, compactWidth: false, divisions: [d])
        XCTAssertEqual(p.kind, .book)
        XCTAssertEqual(p.upperRegion, sideways)
        XCTAssertNil(p.lowerRegion)
        XCTAssertEqual(p.leftRegion, CGRect(x: 0, y: 0, width: 463, height: 669))
        XCTAssertEqual(p.rightRegion, CGRect(x: 487, y: 0, width: 464, height: 669))
        XCTAssertEqual(p.pictureInsets.bottom, 0)
    }

    /// Orientation never decides: a horizontal hinge on a view wider than tall is still laptop, a vertical one on a
    /// taller view still book.
    func testTheHingeDirectionNotTheViewShapeDecides() {
        let h = DuoPose.Division(frame: CGRect(x: 0, y: 330, width: 951, height: 10))
        XCTAssertEqual(DuoPose.classify(bounds: sideways, compactWidth: false, divisions: [h]).kind, .laptop)
        let v = DuoPose.Division(frame: CGRect(x: 330, y: 0, width: 10, height: 951))
        XCTAssertEqual(DuoPose.classify(bounds: upright, compactWidth: false, divisions: [v]).kind, .book)
    }

    /// A zero-thickness hinge (a line) still has a direction; a point falls back to splitting the view's long side.
    func testDegenerateRegions() {
        let line = DuoPose.Division(frame: CGRect(x: 0, y: 475, width: 669, height: 0))
        XCTAssertEqual(DuoPose.classify(bounds: upright, compactWidth: false, divisions: [line]).kind, .laptop)
        let point = DuoPose.Division(frame: CGRect(x: 300, y: 300, width: 0, height: 0))
        XCTAssertEqual(DuoPose.classify(bounds: sideways, compactWidth: false, divisions: [point]).kind, .book)
        XCTAssertEqual(DuoPose.classify(bounds: upright, compactWidth: false, divisions: [point]).kind, .laptop)
    }

    /// A division reported outside the view (a view that sits wholly in one half) is no fold for that view.
    func testADivisionOutsideTheViewIsIgnored() {
        let half = CGRect(x: 0, y: 0, width: 669, height: 460)
        let d = DuoPose.Division(frame: CGRect(x: 0, y: 470, width: 669, height: 12))
        XCTAssertEqual(DuoPose.classify(bounds: half, compactWidth: false, divisions: [d]).kind, .openFlat)
    }

    /// The first active one counts when several are reported.
    func testTheFirstActiveDivisionWins() {
        let off = DuoPose.Division(frame: CGRect(x: 330, y: 0, width: 10, height: 951), isActive: false)
        let on = DuoPose.Division(frame: CGRect(x: 0, y: 470, width: 669, height: 12))
        let p = DuoPose.classify(bounds: upright, compactWidth: false, divisions: [off, on])
        XCTAssertEqual(p.kind, .laptop)
        XCTAssertEqual(p.division, on)
    }
}
