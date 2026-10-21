import SwiftUI
import UIKit
import MirageCore

/// iOS/iPadOS shell: Desktop mode only. A connect screen (paired hosts, or a new one with its 6-digit code), then the
/// remote desktop full screen. The session layer (Session/) is the same code the Mac viewer runs.
@main
struct MirageMobileApp: App {
    @StateObject private var state = AppState()
    init() { DeviceNames.deviceName = UIDevice.current.model }
    var body: some Scene {
        WindowGroup {
            Group {
                if let s = state.session, let m = state.model {
                    DesktopScreen(session: s, model: m) { state.disconnect() }
                } else {
                    ConnectScreen(onConnect: { host, code in state.connect(host, pairCode: code) }, onLink: { state.offer($0) })
                }
            }
            .preferredColorScheme(.dark)
            .onAppear { state.autoConnectFromLaunchArguments() }
            // A pairing link (Camera's "Open in Mirage", or a tap): never connects silently.
            .onOpenURL { state.open($0) }
            .alert(state.offered.map { "Pair with \($0.hostName)?" } ?? "", isPresented: Binding(get: { state.offered != nil }, set: { if !$0 { state.offered = nil } }), presenting: state.offered) { link in
                Button("Pair") { state.pair(link) }
                Button("Cancel", role: .cancel) { state.offered = nil }
            } message: { link in
                Text("\(link.address)\nHost key \(PairingLink.fingerprintText(link.keyHash))\n\nThe Mac will ask to allow this \(UIDevice.current.model) too.")
            }
            .alert(state.linkProblem ?? "", isPresented: Binding(get: { state.linkProblem != nil }, set: { if !$0 { state.linkProblem = nil } })) {
                Button("OK", role: .cancel) { state.linkProblem = nil }
            }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var session: ViewerSession?
    @Published var model: ViewerModel?
    /// A pairing link waiting for "Pair with <host>?".
    @Published var offered: PairingLink?
    @Published var linkProblem: String?

    /// An opened `miragerd://pair` link: confirmed first, never connected silently.
    func open(_ url: URL) {
        guard url.scheme?.lowercased() == PairingLink.scheme else { return }
        guard let link = PairingLink(url: url) else { linkProblem = "That is not a valid Mirage pairing link."; return }
        offer(link)
    }
    func offer(_ link: PairingLink) {
        guard !link.isExpired() else { linkProblem = "That pairing code has expired. Codes change every 30 seconds: scan the one the Mac shows now."; return }
        guard session == nil else { linkProblem = "Disconnect first, then scan the pairing code again."; return }
        offered = link
    }
    func pair(_ link: PairingLink) {
        offered = nil
        guard !link.isExpired() else { linkProblem = "That pairing code has expired. Scan the one the Mac shows now."; return }
        ViewerSettings.noteConnected(link.address)
        let m = Self.makeModel()
        let s = ViewerSession(host: link.address, port: link.port, pairCode: nil, pairLink: link, model: m)
        model = m; session = s; ViewerPreferences.shared.session = s
        s.start()
    }

    /// `HOST`, `HOST:PORT` or `[V6]:PORT`.
    static func parse(_ s: String) -> (host: String, port: UInt16) { ConnectList.parseAddress(s) }

    func connect(_ address: String, pairCode: String?) {
        let (host, port) = Self.parse(address)
        UserDefaults.standard.set(address, forKey: "lastHost")
        ViewerSettings.noteConnected(host)   // the connect list's order: most recent first
        let m = Self.makeModel()
        let s = ViewerSession(host: host, port: port, pairCode: pairCode, model: m)
        model = m; session = s; ViewerPreferences.shared.session = s
        s.start()
    }

    /// A session's model from the settings: bitrate cap (automatic by default), throttle (only a pinned one survives a
    /// relaunch), stats overlay (behind the stats button; a phone has no room to spare for them by default).
    private static func makeModel() -> ViewerModel {
        let d = UserDefaults.standard, prefs = ViewerPreferences.shared
        let m = ViewerModel(bitrateKbps: prefs.bitrateKbps, pixelFactor: d.object(forKey: "scale") as? Double ?? 1.0, throttle: prefs.throttle)
        m.showStats = d.bool(forKey: ViewerSettings.showStatsKey)
        return m
    }

    func disconnect() {
        session?.stop()
        session = nil; model = nil; ViewerPreferences.shared.session = nil
    }

    /// Test and power-user hook: `-connect HOST[:PORT] [-pair CODE]` as launch arguments (simctl launch) connects at once;
    /// `-pairLink URL` opens a pairing link as Camera would (the confirmation shows; nothing connects until Pair).
    private var autoConnected = false
    func autoConnectFromLaunchArguments() {
        if !autoConnected, let link = UserDefaults.standard.string(forKey: "pairLink"), let url = URL(string: link) { autoConnected = true; open(url); return }
        guard !autoConnected, session == nil, let host = UserDefaults.standard.string(forKey: "connect"), !host.isEmpty else { return }
        autoConnected = true
        connect(host, pairCode: UserDefaults.standard.string(forKey: "pair").flatMap { PairingCode.normalize($0) })
    }
}

/// The paired Macs, each with its device's symbol, most recently connected first; a tap connects. + (the navigation bar)
/// adds another one by name or address with its 6-digit code or the QR code its Pair a Device… shows.
struct ConnectScreen: View {
    let onConnect: (String, String?) -> Void
    let onLink: (PairingLink) -> Void
    @State private var hosts: [PairedHost] = []
    @State private var adding = ProcessInfo.processInfo.environment["MIRAGE_TEST_OPEN_ADD"] != nil

    var body: some View {
        NavigationStack {
            Group {
                if hosts.isEmpty {
                    VStack(spacing: 14) {
                        Text("No paired Macs yet.").foregroundStyle(.secondary)
                        Button { adding = true } label: { Label("Add a Mac", systemImage: "plus") }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(hosts) { h in
                        Button { onConnect(h.alias, nil) } label: { row(h) }
                            .tint(.primary)
                    }
                }
            }
            .navigationTitle("Mirage")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a Mac")
                }
            }
            .sheet(isPresented: $adding) {
                AddHostScreen(paired: hosts, onCancel: { adding = false }, onConnect: { address, code in
                    adding = false
                    onConnect(address, code)
                }, onLink: { link in
                    // The "Pair with …?" alert lives on the root view: this sheet goes first.
                    adding = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onLink(link) }
                })
            }
        }
        .onAppear { hosts = ConnectList.load() }
    }

    private func row(_ h: PairedHost) -> some View {
        HStack(spacing: 12) {
            DeviceIconView(model: h.model, family: h.family, size: 34)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.title).foregroundStyle(.primary)
                if let d = h.detail() { Text(d).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// The + sheet: name or address, then the pairing code (typed, or its QR scanned) unless this device is already paired.
struct AddHostScreen: View {
    let paired: [PairedHost]
    let onCancel: () -> Void
    let onConnect: (String, String?) -> Void
    let onLink: (PairingLink) -> Void
    @State private var form = AddHostForm()
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name or Address", text: $form.address, prompt: Text("mac-studio.local"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                if form.needsCode(paired) {
                    HStack {
                        TextField("Pairing Code", text: $form.code, prompt: Text("6 digits"))
                            .keyboardType(.numberPad)
                        Button { scanning = true } label: { Image(systemName: "qrcode.viewfinder").font(.title3) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Scan Pairing Code")
                    }
                }
            }
            .navigationTitle("Add a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { if let r = form.request(paired) { onConnect(r.address, r.code) } }
                        .disabled(form.request(paired) == nil)
                }
            }
            .sheet(isPresented: $scanning) { PairingScanSheet(onLink: onLink) }
        }
        .presentationDetents([.medium, .large])
    }
}
