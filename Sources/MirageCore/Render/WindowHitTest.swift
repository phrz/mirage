import Foundation

/// What a pointer press on the remote desktop lands on and what it may become, decided the same way by every viewer (the
/// Mac's mouse, iOS's touches and trackpad), over the window list as arranged locally (front to back, local frames and the
/// local raise applied), in display-layer pixels.
public enum WindowHitTest {
    /// Title-bar height and the traffic lights' width, in host display points.
    public static let titleBarPoints = 28.0
    public static let trafficLightsPoints = 80.0

    /// The topmost window under a display-layer pixel. Never the compositor model's overlay layer (it covers the whole
    /// display: the menu bar, the Dock and menus are drawn by it, not windows to raise or drag). Display-sized windows above
    /// the normal level are passed over too (the Dock's transparent full-screen window at level 20 covers every point on
    /// macOS 26+: a press on a title bar found it instead of the window, so no title-bar drag or local raise ever started).
    public static func window(at x: Int, _ y: Int, in arranged: [ControlMessage.WindowInfo], displayArea: Int) -> ControlMessage.WindowInfo? {
        arranged.first { w in
            !w.isOverlay && w.frame.contains(x, y) && (w.isLayered || w.windowLevel == 0 || w.frame.area * 10 < displayArea * 6)
        }
    }

    public enum Press: Equatable {
        /// Nothing (the desktop, the menu bar, the Dock): the press goes to the host as it is.
        case none
        /// A window layer's title bar, right of the traffic lights: hold the press back; a local drag once the pointer moves
        /// (DESIGN §3.2), else the click goes on release and raises the window here.
        case layerTitleBar(id: UInt32, frame: PixelRect)
        /// Elsewhere in a window layer: the press goes now; `raise`: it comes to the front here at once.
        case layer(id: UInt32, raise: Bool)
        /// The title bar of a window the display layer carries: the press goes now and starts the predicted (copy-rect) drag.
        case displayTitleBar(id: UInt32, frame: PixelRect)
        /// Elsewhere in a window the display layer carries.
        case display(id: UInt32)

        /// The window a click there raises locally, if any.
        public var raises: UInt32? {
            switch self {
            case .layerTitleBar(let id, _): return id
            case .layer(let id, let raise): return raise ? id : nil
            default: return nil
            }
        }
    }

    /// `plain`: no ⌘, ⌥, ⌃ or ⇧ held. `firstClick`: not the second click of a double click (that one is never a drag).
    /// Only a plain press raises or drags, and only a normal-level window (a menu or a panel stays where macOS keeps it).
    public static func press(at x: Int, _ y: Int, in arranged: [ControlMessage.WindowInfo], displayArea: Int, pxPerPoint: Double,
                             plain: Bool, firstClick: Bool = true) -> Press {
        guard let w = window(at: x, y, in: arranged, displayArea: displayArea) else { return .none }
        let inTitleBar = y < w.frame.y + Int(titleBarPoints * pxPerPoint)
        let normal = w.windowLevel == 0
        if w.isLayered {
            if plain, firstClick, normal, inTitleBar, x > w.frame.x + Int(trafficLightsPoints * pxPerPoint) { return .layerTitleBar(id: w.id, frame: w.frame) }
            return .layer(id: w.id, raise: plain && normal)
        }
        // The predicted (copy-rect) drag moves the display layer's pixels: in the compositor model (an overlay is listed) the
        // display layer is the desktop alone, and a window not yet a layer is not in it, so the prediction smeared the desktop
        // (phrz, 08:46Z: "artifacting galore on desktop", "some weird pseudo window"). There the press just goes.
        let compositorModel = arranged.contains { $0.isOverlay }
        if plain, firstClick, inTitleBar, !compositorModel { return .displayTitleBar(id: w.id, frame: w.frame) }
        return .display(id: w.id)
    }
}
