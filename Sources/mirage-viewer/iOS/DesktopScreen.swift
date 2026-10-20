import SwiftUI
import UIKit
import MirageCore

/// The remote desktop full screen, its status banners and a small control pill (keyboard, stats, disconnect).
struct DesktopScreen: View {
    let session: ViewerSession
    @ObservedObject var model: ViewerModel
    let onDisconnect: () -> Void
    @State private var keyboard = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DesktopView(session: session, model: model, keyboard: $keyboard)
                .ignoresSafeArea(.keyboard)   // the picture keeps its size (no re-stream); it lifts above the keyboard instead
            VStack(alignment: .leading, spacing: 8) {
                if model.showStats { StatsPanel(model: model).padding(.top, 40) }   // below the control pill
                Spacer()
                banners
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(model.inputHeld)
            controls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(8)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { keyboard.toggle() } label: { Image(systemName: keyboard ? "keyboard.chevron.compact.down" : "keyboard") }
            Button { model.showStats.toggle(); UserDefaults.standard.set(model.showStats, forKey: "stats") } label: { Image(systemName: "chart.bar.xaxis") }
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

struct StatsPanel: View {
    @ObservedObject var model: ViewerModel
    var body: some View {
        let s = model.stats
        VStack(alignment: .leading, spacing: 1) {
            Text(model.status)
            Text(String(format: "rtt %.0f ms  age %.0f ms  %.1f fps  video %.0f  tiles %.0f kbps (cap %d)", s.rttMs, s.frameAgeMs, s.fps, s.kbps, s.tileKbps, model.bitrateKbps))
            Text(String(format: "%@  target %d  capacity %d  queue %.0f ms  %dx%d", s.rate.tier?.name ?? "–", s.rate.targetKbps, s.rate.capacityKbps, s.rate.queueMs, s.width, s.height))
            Text(String(format: "predictions %d shown  %d confirmed  %d mismatched  lost %d  nacks %d", s.predictions.shown, s.predictions.confirmed, s.predictions.mismatched, s.lost, s.nacks))
        }
        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white)
        .padding(5).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
        .allowsHitTesting(false)
    }
}

struct DesktopView: UIViewRepresentable {
    let session: ViewerSession
    @ObservedObject var model: ViewerModel
    @Binding var keyboard: Bool

    func makeUIView(context: Context) -> DesktopUIView {
        let v = DesktopUIView(frame: .zero)
        v.model = model
        v.onKeyboardRequest = { on in keyboard = on }
        v.attach(session)
        return v
    }
    func updateUIView(_ v: DesktopUIView, context: Context) {
        v.setSoftKeyboard(keyboard)
        v.updateCursorLayer()
        v.sendStreamRequest()
    }
}
