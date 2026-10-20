import SwiftUI
import UIKit
import MirageCore

/// The remote desktop full screen, its status banners and a small control pill (keyboard, stats, disconnect).
/// The picture fills the safe area (in landscape, the full height); zoom and pan happen in the view, presentation only.
/// Stats are a small translucent overlay behind the stats button, off at every connect. In landscape the pill hides
/// itself after a few seconds, leaving a small handle in the corner that brings it back.
struct DesktopScreen: View {
    let session: ViewerSession
    @ObservedObject var model: ViewerModel
    let onDisconnect: () -> Void
    @State private var keyboard = false
    @State private var toolbarShown = true
    @State private var hideToolbar: Task<Void, Never>?

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                ZStack(alignment: .topLeading) {
                    DesktopView(session: session, model: model, keyboard: $keyboard, safeInsets: UIEdgeInsets(top: geo.safeAreaInsets.top, left: geo.safeAreaInsets.leading, bottom: geo.safeAreaInsets.bottom, right: geo.safeAreaInsets.trailing))
                        .ignoresSafeArea()
                    if model.showStats {
                        StatsPanel(model: model).padding(.top, landscape ? 8 : 44).padding(.leading, 8)
                    }
                    toolbar
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, landscape ? 8 : 4).padding(.trailing, 8)
                }
                .onChange(of: landscape, initial: true) { _, l in showToolbar(autoHide: l) }
            }
            .ignoresSafeArea(.keyboard)   // the picture keeps its size (no re-stream); it lifts above the keyboard instead
            VStack(alignment: .leading, spacing: 8) {
                Spacer()
                banners
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(model.inputHeld)
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    @State private var landscapeAutoHide = false

    /// Shows the pill; in landscape it hides itself again after 3 s.
    private func showToolbar(autoHide: Bool? = nil) {
        if let autoHide { landscapeAutoHide = autoHide }
        hideToolbar?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toolbarShown = true }
        guard landscapeAutoHide else { return }
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
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.black.opacity(0.3), in: Capsule())
            }
            .accessibilityLabel("Show controls")
            .transition(.opacity)
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { keyboard.toggle(); showToolbar() } label: { Image(systemName: keyboard ? "keyboard.chevron.compact.down" : "keyboard") }
            Button { model.showStats.toggle(); showToolbar() } label: { Image(systemName: "chart.bar.xaxis") }
            Button(role: .destructive) { onDisconnect() } label: { Image(systemName: "xmark") }
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.black.opacity(0.45), in: Capsule())
    }

    @ViewBuilder private var banners: some View {
        if let e = model.error {
            banner(e, color: .red)
        } else if let r = model.reconnecting {
            banner("Reconnecting… attempt \(r.attempt), next in \(r.inSeconds) s", color: .orange)
        } else if model.stalledSeconds > 0 {
            banner("No data from the host for \(model.stalledSeconds) s", color: .orange)
        } else if model.streamInfo == nil {
            banner(model.status, color: .gray)
        }
        if model.hostStatus?.consoleLocked == true {
            banner("\(model.hostName)'s screen is locked. Unlock it to see its windows.", color: .black)
        }
        if model.inputHeld {
            HStack {
                Text("\(model.inputQueued) keystrokes typed while the host was unreachable.")
                Button("Send") { session.flushInput() }.buttonStyle(.borderedProminent)
                Button("Discard", role: .destructive) { session.discardInput() }.buttonStyle(.bordered)
            }
            .font(.footnote.weight(.medium)).foregroundStyle(.white).padding(10)
            .background(.blue.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func banner(_ s: String, color: Color) -> some View {
        Text(s).font(.footnote.weight(.medium)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
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
            Text(String(format: "video %.0f  tiles %.0f kbps  cap %d", s.kbps, s.tileKbps, model.bitrateKbps))
            Text(String(format: "%@  target %d  capacity %d  queue %.0f ms", s.rate.tier?.name ?? "–", s.rate.targetKbps, s.rate.capacityKbps, s.rate.queueMs))
            Text(String(format: "%dx%d  lost %d  nacks %d", s.width, s.height, s.lost, s.nacks))
            Text(String(format: "predictions %d shown  %d ok  %d missed", s.predictions.shown, s.predictions.confirmed, s.predictions.mismatched))
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
    let safeInsets: UIEdgeInsets

    func makeUIView(context: Context) -> DesktopUIView {
        let v = DesktopUIView(frame: .zero)
        v.model = model
        v.onKeyboardRequest = { on in keyboard = on }
        v.attach(session)
        return v
    }
    func updateUIView(_ v: DesktopUIView, context: Context) {
        v.safeInsets = safeInsets
        v.setSoftKeyboard(keyboard)
        v.updateCursorLayer()
        v.scheduleStreamRequest()
    }
}
