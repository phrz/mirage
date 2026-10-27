import SwiftUI
import UIKit
import MirageCore

/// The remote desktop full screen, its status banners and a Liquid Glass button bar (keyboard, touch mode, stats,
/// settings, disconnect; 44 pt targets). The picture fills the safe area (in landscape, the full height); zoom and pan
/// happen in the view, presentation only. Stats are a small translucent overlay behind the stats button (off at connect
/// unless Settings › Display says otherwise). In landscape the bar hides itself after a few seconds, leaving a handle in
/// the corner that brings it back.
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
    /// The pill's (or its handle's) bottom edge on screen: a zoomed picture pans down until it clears it.
    @State private var pillBottom: CGFloat = 0

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                ZStack(alignment: .topLeading) {
                    DesktopView(session: session, model: model, keyboard: $keyboard, touchMode: touchMode, accessoryRow: accessoryRow, safeInsets: UIEdgeInsets(top: geo.safeAreaInsets.top, left: geo.safeAreaInsets.leading, bottom: geo.safeAreaInsets.bottom, right: geo.safeAreaInsets.trailing), topObstruction: pillBottom)
                        .ignoresSafeArea()
                    if model.showStats {
                        StatsPanel(model: model).padding(.top, landscape ? 8 : 44).padding(.leading, 8)
                    }
                    toolbar
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { pillBottom = $0 }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, landscape ? 8 : 4).padding(.trailing, 8)
                }
                .onChange(of: landscape, initial: true) { _, l in showToolbar(autoHide: l) }
                .task {
                    // Test hook: `-openSettings 1` (simctl launch) opens the settings sheet once the picture is up.
                    guard UserDefaults.standard.bool(forKey: "openSettings") else { return }
                    try? await Task.sleep(for: .seconds(6)); settingsShown = true
                }
            }
            .ignoresSafeArea(.keyboard)   // the picture keeps its size (no re-stream); it lifts above the keyboard instead
            VStack(alignment: .leading, spacing: 8) {
                Spacer()
                SessionBanners(session: session, model: model)   // the Mac viewer's too
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Hit-testable (phrz, 2026-10-27): a tap on a banner's button is the banner's, never the host's; the empty
            // area around them passes through to the picture.
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $settingsShown, onDismiss: { showToolbar() }) {
            SettingsSheet(model: model, prefs: ViewerPreferences.shared)
                .presentationDetents([.medium, .large], selection: $settingsDetent)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    @State private var landscapeAutoHide = false

    /// Shows the bar; in landscape it hides itself again after 3 s (not while the settings sheet is up).
    private func showToolbar(autoHide: Bool? = nil) {
        if let autoHide { landscapeAutoHide = autoHide }
        hideToolbar?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toolbarShown = true }
        guard landscapeAutoHide, !settingsShown else { return }
        hideToolbar = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { toolbarShown = false }
        }
    }

    @ViewBuilder private var toolbar: some View {
        if toolbarShown {
            controls.transition(.opacity)
        } else {
            Button { showToolbar() } label: {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 56, height: 28)
                    .glassBar(in: Capsule())
                    .frame(minWidth: 64, minHeight: 44)   // the touch target: larger than the handle
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
            barButton("gearshape", "Settings", on: false) { settingsShown = true; hideToolbar?.cancel() }
            barButton("xmark", "Disconnect", on: false) { onDisconnect() }
        }
        .padding(.horizontal, 4)
        .foregroundStyle(.white)
        .glassBar(in: Capsule())
    }

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

    func makeUIView(context: Context) -> DesktopUIView {
        let v = DesktopUIView(frame: .zero)
        v.model = model
        v.onKeyboardRequest = { on in keyboard = on }
        v.attach(session)
        return v
    }
    func updateUIView(_ v: DesktopUIView, context: Context) {
        v.safeInsets = safeInsets
        v.topObstruction = topObstruction
        v.touchMode = touchMode
        v.accessoryRow = accessoryRow
        v.setSoftKeyboard(keyboard)
        v.updateCursorLayer()
        v.scheduleStreamRequest()
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
