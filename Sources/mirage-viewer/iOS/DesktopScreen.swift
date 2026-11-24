import SwiftUI
import UIKit
import MirageCore

/// The remote desktop full screen, its status banners and a Liquid Glass button bar (keyboard, touch mode, stats,
/// settings, disconnect; 44 pt targets). The picture fills the safe area (in landscape, the full height); zoom and pan
/// happen in the view, presentation only. Stats are a small translucent overlay behind the stats button (off at connect
/// unless Settings › Display says otherwise). The bar floats in a corner: dragged, it goes to the corner it was thrown
/// toward (as FaceTime's picture does) and stays there across launches; after a few seconds it folds into one button.
///
/// On an iPhone Duo (DESIGN §3.11) the layout follows the pose. Laptop (and tent: a hinge running side to side): the
/// picture fills the region above the hinge, the bar sits at the top of the region below it, and with the keyboard up
/// the accessory row docks under the bar, the keyboard below. Book, open flat and closed: as above, the picture a canvas
/// that may cross a vertical hinge.
struct DesktopScreen: View {
    let session: ViewerSession
    @ObservedObject var model: ViewerModel
    let onDisconnect: () -> Void
    @State private var keyboard = false
    @State private var settingsShown = false
    /// Half height, so the picture stays in view while a setting changes it; drag up for all of them. (`-settingsLarge 1`:
    /// full height, for screenshots.)
    @State private var settingsDetent: PresentationDetent = UserDefaults.standard.bool(forKey: "settingsLarge") ? .large : .medium
    @AppStorage(ViewerSettings.keyAccessoryKey) private var accessoryRow = true
    /// Direct touch (the default) or trackpad: how touches on the picture act (DesktopUIView), kept across launches.
    @AppStorage(TouchMode.defaultsKey) private var touchMode = TouchMode.direct
    @State private var toolbarShown = true
    @State private var hideToolbar: Task<Void, Never>?
    /// The bar's (or its button's) frame on screen: a zoomed picture pans until it clears it.
    @State private var barFrame: CGRect = .zero
    @AppStorage(BarCorner.defaultsKey) private var barCorner = BarCorner.topTrailing
    /// While the bar is dragged: how far from its corner.
    @State private var barDrag: CGSize?
    /// The keyboard's top edge on screen while it is up: a bar in a bottom corner sits above it.
    @State private var keyboardTop: CGFloat?
    /// Read here so a change in Settings re-sends the stream request at once.
    @AppStorage(ViewerSettings.dynamicResolutionKey) private var dynamicResolution = true
    /// Unified mode (DESIGN §3.11): the host's windows one at a time, a strip of them on top. A connect starts in the mode
    /// last used with this host.
    @State private var unifiedOn = false
    @StateObject private var unifiedHolder = UnifiedHolder()
    /// The fold, read on DesktopView (it covers the screen), so in its coordinates and the screen's.
    @State private var pose = DuoPose(kind: .closed, bounds: .zero)
    /// The picture's view, for the accessory row docked in the laptop pose.
    @State private var desktop = DesktopViewHandle()

    /// The laptop layout is Desktop mode's (Unified keeps its strip and panes, the fold kept out of them by the insets).
    private var laptop: Bool { pose.kind == .laptop && !unifiedOn }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                let fold = pose.pictureInsets
                let foldInsets = UIEdgeInsets(top: fold.top, left: fold.left, bottom: fold.bottom, right: fold.right)
                let safe = UIEdgeInsets(top: max(geo.safeAreaInsets.top, fold.top), left: max(geo.safeAreaInsets.leading, fold.left), bottom: max(geo.safeAreaInsets.bottom, fold.bottom), right: max(geo.safeAreaInsets.trailing, fold.right))
                ZStack(alignment: .topLeading) {
                    if unifiedOn {
                        UnifiedArea(session: session, model: model, unified: unifiedHolder.get(session), keyboard: $keyboard, touchMode: touchMode, accessoryRow: accessoryRow, safeInsets: safe)
                            .onDuoPoseChange { pose = $0 }
                    } else {
                        DesktopView(session: session, model: model, keyboard: $keyboard, touchMode: touchMode, accessoryRow: accessoryRow, safeInsets: safe, topObstruction: laptop || !barCorner.isTop ? 0 : barFrame.maxY, bottomObstruction: laptop || barCorner.isTop || barFrame == .zero ? nil : barFrame.minY, foldInsets: foldInsets, accessoryDocked: laptop, handle: desktop, dynamicResolution: dynamicResolution)
                            .ignoresSafeArea()
                            .onDuoPoseChange { pose = $0 }
                    }
                    if model.showStats {
                        StatsPanel(model: model).padding(.top, landscape ? 8 : 44).padding(.leading, 8)
                    }
                    if !laptop { floatingBar(geo, landscape: landscape) }
                }
                // Laptop: the bar under the hinge, hidden after 3 s only with no keyboard (tent). Anywhere else it folds.
                .onChange(of: laptop ? !keyboard : true, initial: true) { _, autoHide in showToolbar(autoHide: autoHide) }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
                    guard let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                    let full = geo.frame(in: .global).maxY + geo.safeAreaInsets.bottom
                    withAnimation(.snappy(duration: 0.25)) { keyboardTop = f.minY < full - 1 ? f.minY : nil }
                }
                .onChange(of: unifiedOn) { _, on in
                    UserDefaults.standard.set(on, forKey: ViewerSettings.unifiedKey(host: model.hostName))
                    if !on { unifiedHolder.stop() }
                }
                .onAppear { unifiedOn = !linuxHost && UserDefaults.standard.bool(forKey: ViewerSettings.unifiedKey(host: model.hostName)) }
                .onDisappear { unifiedHolder.stop() }
                .task {
                    // Test hook: `-openSettings 1` (simctl launch) opens the settings sheet once the picture is up.
                    guard UserDefaults.standard.bool(forKey: "openSettings") else { return }
                    try? await Task.sleep(for: .seconds(6)); settingsShown = true
                }
            }
            .ignoresSafeArea(.keyboard)   // the picture keeps its size (no re-stream); it lifts above the keyboard instead
            if laptop, let lower = pose.lowerRegion { deck(lower) }
            if laptop {
                // Laptop: at the bottom of the picture, above the hinge; the keyboard deck stays clear.
                banners
                    .frame(height: max(0, pose.upperRegion.maxY - pose.bounds.minY), alignment: .bottom)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
            } else {
                banners
            }
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $settingsShown, onDismiss: { showToolbar() }) {
            SettingsSheet(model: model, prefs: ViewerPreferences.shared)
                .presentationDetents([.medium, .large], selection: $settingsDetent)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private var banners: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            SessionBanners(session: session, model: model)   // the Mac viewer's too
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Hit-testable (phrz, 2026-10-27): a tap on a banner's button is the banner's, never the host's; the empty
        // area around them passes through to the picture.
    }

    /// The laptop pose's lower region (screen coordinates): from the hinge down it is the deck, never the picture (a
    /// zoomed picture is cut off at the hinge). The bar is at its top edge, where a MacBook's function row is; with the
    /// keyboard up, the accessory row docks under it and the system keyboard sits below. In trackpad mode touches on the
    /// empty deck go through to the picture's view as trackpad touches; in direct mode they land nowhere.
    private func deck(_ lower: CGRect) -> some View {
        let hingeTop = pose.upperRegion.maxY
        return ZStack(alignment: .top) {
            Color.black
                .frame(height: max(0, pose.bounds.maxY - hingeTop))
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(touchMode == .direct)
            VStack(spacing: 8) {
                toolbar
                if keyboard && accessoryRow {
                    DockedKeyRow(handle: desktop)
                        .frame(height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.top, lower.minY - pose.bounds.minY + 8)
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    @State private var barAutoHide = false

    /// Shows the bar; it folds again after 3 s (not while the settings sheet is up).
    private func showToolbar(autoHide: Bool? = nil) {
        if let autoHide { barAutoHide = autoHide }
        hideToolbar?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toolbarShown = true }
        guard barAutoHide, !settingsShown else { return }
        hideToolbar = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.3)) { toolbarShown = false }
        }
    }

    /// The bar in its corner, dragged from anywhere on it.
    private func floatingBar(_ geo: GeometryProxy, landscape: Bool) -> some View {
        let frame = geo.frame(in: .global)
        let lift = keyboardTop.map { max(0, frame.maxY - $0) } ?? 0
        return toolbar
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { if barDrag == nil { barFrame = $0 } }
            .offset(barDrag ?? .zero)
            // High priority: a touch that moves is the bar's, never a press of the button it started on.
            .highPriorityGesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { g in hideToolbar?.cancel(); barDrag = g.translation }
                .onEnded { g in
                    // Where the throw would carry the bar's own middle.
                    let p = CGPoint(x: barFrame.midX + g.predictedEndTranslation.width, y: barFrame.midY + g.predictedEndTranslation.height)
                    let to = BarCorner.nearest(p, in: frame)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { barCorner = to; barDrag = nil }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if toolbarShown { showToolbar() }
                })
            .accessibilityActions {
                ForEach(BarCorner.allCases, id: \.self) { c in
                    if c != barCorner { Button("Move to \(c.title)") { withAnimation { barCorner = c } } }
                }
            }
            .padding(.top, (landscape ? 8 : 4) + (unifiedOn ? UnifiedArea.stripHeight : 0))
            .padding(.horizontal, 8)
            .padding(.bottom, 4 + lift)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: barCorner.alignment)
    }

    @ViewBuilder private var toolbar: some View {
        if toolbarShown {
            controls.transition(.opacity)
        } else {
            Button { showToolbar() } label: {
                // The laptop pose's bar is on the deck, not in a corner.
                Image(systemName: laptop ? "chevron.compact.down" : "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: laptop ? 56 : 44, height: laptop ? 28 : 44)
                    .glassBar(in: Capsule())
                    .frame(minWidth: laptop ? 64 : 44, minHeight: 44)   // the touch target: larger than the handle
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))
            .accessibilityLabel("Show controls")
            .transition(.opacity)
        }
    }

    /// The button bar: one Liquid Glass capsule (iOS 26+; a material capsule before), every button a 44×44 pt target.
    private var controls: some View {
        HStack(spacing: 2) {
            barButton(keyboard ? "keyboard.chevron.compact.down" : "keyboard", "Keyboard", on: keyboard) { keyboard.toggle(); showToolbar() }
            Menu {
                Picker("Touch", selection: $touchMode) {
                    Label(TouchMode.direct.title, systemImage: "hand.tap").tag(TouchMode.direct)
                    Label(TouchMode.trackpad.title, systemImage: "rectangle.and.hand.point.up.left").tag(TouchMode.trackpad)
                }
            } label: {
                barIcon(touchMode == .direct ? "hand.tap" : "rectangle.and.hand.point.up.left", on: false)
            }
            .accessibilityLabel("Touch: \(touchMode.title)")
            .onChange(of: touchMode) { showToolbar() }
            if !linuxHost { barButton(Self.unifiedSymbol, "Unified", on: unifiedOn) { withAnimation(.snappy(duration: 0.3)) { unifiedOn.toggle() } } }
            barButton("gearshape", "Settings", on: false) { settingsShown = true; hideToolbar?.cancel() }
            barButton("xmark", "Disconnect", on: false) { onDisconnect() }
        }
        .padding(.horizontal, 4)
        .foregroundStyle(.white)
        .glassBar(in: Capsule())
    }

    /// A Linux host streams its whole screen only: no window layers, so no Unified.
    private var linuxHost: Bool { (try? Store().knownHosts())?[session.host].map(ViewerFeed.isLinux) ?? false }

    /// iOS 27's symbol for windows over a desktop, else its iOS 18 forerunner.
    static let unifiedSymbol = UIImage(systemName: "interface.window.on.rectangle.dashed") != nil ? "interface.window.on.rectangle.dashed" : "rectangle.on.rectangle.dashed"

    private func barButton(_ symbol: String, _ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { barIcon(symbol, on: on) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
    private func barIcon(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .symbolVariant(on ? .fill : .none)
            .foregroundStyle(on ? Color.accentColor : Color.white)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

/// The corner the floating bar sits in, kept across launches.
enum BarCorner: String, CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
    static let defaultsKey = "barCorner"
    var isTop: Bool { self == .topLeading || self == .topTrailing }
    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
    var title: String {
        switch self {
        case .topLeading: "Top Left"
        case .topTrailing: "Top Right"
        case .bottomLeading: "Bottom Left"
        case .bottomTrailing: "Bottom Right"
        }
    }
    static func nearest(_ p: CGPoint, in r: CGRect) -> BarCorner {
        p.y < r.midY ? (p.x < r.midX ? .topLeading : .topTrailing) : (p.x < r.midX ? .bottomLeading : .bottomTrailing)
    }
}

/// Short lines: it has to fit a phone in portrait without covering much.
struct StatsPanel: View {
    @ObservedObject var model: ViewerModel
    var body: some View {
        let s = model.stats
        VStack(alignment: .leading, spacing: 1) {
            Text(model.status).lineLimit(1)
            Text(String(format: "rtt %.0f ms  age %.0f ms  %.1f fps", s.rttMs, s.frameAgeMs, s.fps))
            Text(String(format: "video %.0f  tiles %.0f kbps  cap %@", s.kbps, s.tileKbps, model.bitrateKbps > 0 ? "\(model.bitrateKbps)" : "auto"))
            Text(String(format: "%@  target %d  capacity %d  queue %.0f ms", s.rate.tier?.name ?? "–", s.rate.targetKbps, s.rate.capacityKbps, s.rate.queueMs))
            Text(String(format: "%dx%d  lost %d  nacks %d", s.width, s.height, s.lost, s.nacks))
            Text(String(format: "predictions %d shown  %d ok  %d missed", s.predictions.shown, s.predictions.confirmed, s.predictions.mismatched))
            if let t = model.throttle { Text("Throttled: \(t.name)").foregroundStyle(.orange) }
        }
        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.9))
        .padding(5).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
        .frame(maxWidth: 260, alignment: .leading)
        .allowsHitTesting(false)
    }
}

struct DesktopView: UIViewRepresentable {
    let session: ViewerSession
    @ObservedObject var model: ViewerModel
    @Binding var keyboard: Bool
    let touchMode: TouchMode
    let accessoryRow: Bool
    let safeInsets: UIEdgeInsets
    let topObstruction: CGFloat
    let bottomObstruction: CGFloat?
    /// The fold's share of `safeInsets` (DuoPose.pictureInsets), kept in landscape too.
    var foldInsets: UIEdgeInsets = .zero
    /// The accessory row lives in the screen's layout (DockedKeyRow), not on the keyboard.
    var accessoryDocked = false
    var handle: DesktopViewHandle? = nil
    var dynamicResolution = false

    func makeUIView(context: Context) -> DesktopUIView {
        let v = DesktopUIView(frame: .zero)
        handle?.view = v
        v.model = model
        v.onKeyboardRequest = { on in keyboard = on }
        v.attach(session)
        return v
    }
    func updateUIView(_ v: DesktopUIView, context: Context) {
        v.safeInsets = safeInsets
        v.topObstruction = topObstruction
        v.bottomObstruction = bottomObstruction
        v.foldInsets = foldInsets
        v.accessoryDocked = accessoryDocked
        v.touchMode = touchMode
        v.accessoryRow = accessoryRow
        v.setSoftKeyboard(keyboard)
        v.updateCursorLayer()
        v.scheduleStreamRequest()
    }
}

/// Keeps one Unified controller per screen (made on first use: it needs the session).
@MainActor
final class UnifiedHolder: ObservableObject {
    private var unified: MobileUnified?
    func get(_ session: ViewerSession) -> MobileUnified {
        if let u = unified { return u }
        let u = MobileUnified(session: session); unified = u; return u
    }
    func stop() { unified?.stop() }
}

/// The picture's view, for siblings that act on it (the docked accessory row).
@MainActor final class DesktopViewHandle {
    weak var view: DesktopUIView?
}

/// The keyboard's accessory row (esc, tab, ⌃⌥⌘, arrows) docked in the screen's own layout: the laptop pose puts it under
/// the hinge. It is the picture's own row, moved here while `accessoryDocked` keeps it off the keyboard.
struct DockedKeyRow: UIViewRepresentable {
    let handle: DesktopViewHandle
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ v: UIView, context: Context) {
        // Next turn: the keyboard gives the row up once `accessoryDocked` reaches the picture's view in this same update.
        DispatchQueue.main.async { [weak v, handle] in
            guard let v, let bar = handle.view?.accessoryBar, bar.superview !== v else { return }
            bar.removeFromSuperview()
            bar.frame = v.bounds
            bar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            v.addSubview(bar)
        }
    }
}

extension View {
    /// Liquid Glass on iOS 26 and later (interactive: it reacts to touches as system bars do), a thin material before.
    @ViewBuilder func glassBar<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { self.glassEffect(.regular.interactive(), in: shape) }
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}
