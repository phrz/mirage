import XCTest
@testable import MirageCore

/// phrz's 08:46Z compositor session: presses on windows that are not layers must not start the display layer's predicted
/// drag (it smeared the desktop), and a floating window over a normal one takes the press.
final class CompositorHitTests: XCTestCase {
    private let overlay = ControlMessage.WindowInfo(id: ControlMessage.WindowInfo.overlayID, pid: 0, title: "", frame: PixelRect(x: 0, y: 0, width: 3200, height: 1800), z: -1, level: ControlMessage.WindowInfo.overlayLevel, layered: true, app: "Mirage overlay")

    func testATitleBarPressOnANonLayerWindowJustGoesInTheCompositorModel() {
        let w = ControlMessage.WindowInfo(id: 7, pid: 1, title: "", frame: PixelRect(x: 100, y: 100, width: 800, height: 600), z: 0, level: 0, layered: false, app: "ChatGPT")
        let seam = WindowHitTest.press(at: 400, 110, in: [w], displayArea: 3200 * 1800, pxPerPoint: 2, plain: true)
        XCTAssertEqual(seam, .displayTitleBar(id: 7, frame: w.frame), "seam design: the predicted drag")
        let comp = WindowHitTest.press(at: 400, 110, in: [overlay, w], displayArea: 3200 * 1800, pxPerPoint: 2, plain: true)
        XCTAssertEqual(comp, .display(id: 7), "compositor model: the press goes, no prediction of desktop pixels")
    }

    func testAFloatingLayerOverANormalWindowTakesThePressAndIsNotDragged() {
        let normal = ControlMessage.WindowInfo(id: 1, pid: 1, title: "", frame: PixelRect(x: 0, y: 0, width: 2000, height: 1200), z: 2, level: 0, layered: true, app: "Finder")
        let floating = ControlMessage.WindowInfo(id: 2, pid: 2, title: "", frame: PixelRect(x: 300, y: 300, width: 600, height: 300), z: 1, level: 3, layered: true, app: "ChatGPT")
        let p = WindowHitTest.press(at: 400, 310, in: [overlay, floating, normal], displayArea: 3200 * 1800, pxPerPoint: 2, plain: true)
        XCTAssertEqual(p, .layer(id: 2, raise: false), "the floating window gets the press (no local raise, no held drag of the window under it)")
    }
}
