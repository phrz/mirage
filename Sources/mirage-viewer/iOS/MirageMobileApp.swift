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
        UserDefaults.standard.set(link.address, forKey: "lastHost")
        let m = Self.makeModel()
        let s = ViewerSession(host: link.address, port: link.port, pairCode: nil, pairLink: link, model: m)
        model = m; session = s; ViewerPreferences.shared.session = s
        s.start()
    }

    /// `HOST`, `HOST:PORT` or `[V6]:PORT`.
    static func parse(_ s: String) -> (host: String, port: UInt16) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
            let h = String(t[t.index(after: t.startIndex)..<close])
            let rest = t[t.index(after: close)...]
            return (h, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? Mirage.defaultPort : Mirage.defaultPort)
        }
        let parts = t.split(separator: ":")
        if parts.count == 2, let p = UInt16(parts[1]) { return (String(parts[0]), p) }
        return (t, Mirage.defaultPort)
    }

    func connect(_ address: String, pairCode: String?) {
        let (host, port) = Self.parse(address)
        UserDefaults.standard.set(address, forKey: "lastHost")
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

/// Paired hosts, or a new one with the 6-digit code `miraged pair` shows on that Mac.
struct ConnectScreen: View {
    let onConnect: (String, String?) -> Void
    let onLink: (PairingLink) -> Void
    @State private var scanning = false
    @State private var host = UserDefaults.standard.string(forKey: "lastHost") ?? ""
    @State private var code = ""
    @State private var known: [(alias: String, name: String)] = []

    private func isPaired(_ address: String) -> Bool {
        let (h, _) = AppState.parse(address)
        return known.contains { $0.alias == h }
    }
    private var canConnect: Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        return !h.isEmpty && (isPaired(h) || PairingCode.normalize(code) != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !known.isEmpty {
                    Section("Paired Macs") {
                        ForEach(known, id: \.alias) { h in
                            Button { host = h.alias; code = "" } label: {
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                    VStack(alignment: .leading) {
                                        Text(h.name).foregroundStyle(.primary)
                                        Text(h.alias).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if AppState.parse(host).host == h.alias { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                        }
                    }
                }
                Section {
                    TextField("Host name or address (e.g. mac-daddy)", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    if !isPaired(host) {
                        HStack {
                            TextField("6-digit pairing code", text: $code)
                                .keyboardType(.numberPad)
                            Button { scanning = true } label: { Image(systemName: "qrcode.viewfinder").font(.title3) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Scan pairing code")
                        }
                    }
                } header: { Text(known.isEmpty ? "Add a Mac" : "Or another Mac") } footer: {
                    Text(isPaired(host) ? "Over your tailnet. Pairing happened once; this device is remembered." : "On that Mac choose Pair a Device… in the Mirage menu bar item, then scan its code (or type the 6 digits). Pairing happens once; afterwards this device is remembered.")
                }
                Section {
                    Button("Connect") { connect() }.disabled(!canConnect)
                }
            }
            .navigationTitle("Mirage")
            .sheet(isPresented: $scanning) { PairingScanSheet(onLink: onLink) }
        }
        .onAppear { known = ((try? Store().knownHosts()) ?? [:]).map { ($0.key, $0.value.hostName) }.sorted { $0.0 < $1.0 } }
    }

    private func connect() {
        let h = host.trimmingCharacters(in: .whitespaces)
        onConnect(h, isPaired(h) ? nil : PairingCode.normalize(code))
    }
}
