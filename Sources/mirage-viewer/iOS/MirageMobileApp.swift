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
                    ConnectScreen { host, code in state.connect(host, pairCode: code) }
                }
            }
            .preferredColorScheme(.dark)
            .onAppear { state.autoConnectFromLaunchArguments() }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var session: ViewerSession?
    @Published var model: ViewerModel?

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
        let defaults = UserDefaults.standard
        let m = ViewerModel(bitrateKbps: defaults.object(forKey: "bitrate") as? Int ?? 800, pixelFactor: defaults.object(forKey: "scale") as? Double ?? 1.0)
        m.showStats = false   // behind the stats button; a phone has no room to spare for them by default
        let s = ViewerSession(host: host, port: port, pairCode: pairCode, model: m)
        model = m; session = s
        s.start()
    }

    func disconnect() {
        session?.stop()
        session = nil; model = nil
    }

    /// Test and power-user hook: `-connect HOST[:PORT] [-pair CODE]` as launch arguments (simctl launch) connects at once.
    private var autoConnected = false
    func autoConnectFromLaunchArguments() {
        guard !autoConnected, session == nil, let host = UserDefaults.standard.string(forKey: "connect"), !host.isEmpty else { return }
        autoConnected = true
        connect(host, pairCode: UserDefaults.standard.string(forKey: "pair").flatMap { PairingCode.normalize($0) })
    }
}

/// Paired hosts, or a new one with the 6-digit code `miraged pair` shows on that Mac.
struct ConnectScreen: View {
    let onConnect: (String, String?) -> Void
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
                        TextField("6-digit code from `miraged pair`", text: $code)
                            .keyboardType(.numberPad)
                    }
                } header: { Text(known.isEmpty ? "Add a Mac" : "Or another Mac") } footer: {
                    Text(isPaired(host) ? "Over your tailnet. Pairing happened once; this device is remembered." : "Run `miraged pair` on that Mac. Pairing happens once; afterwards this device is remembered.")
                }
                Section {
                    Button("Connect") { connect() }.disabled(!canConnect)
                }
            }
            .navigationTitle("Mirage")
        }
        .onAppear { known = ((try? Store().knownHosts()) ?? [:]).map { ($0.key, $0.value.hostName) }.sorted { $0.0 < $1.0 } }
    }

    private func connect() {
        let h = host.trimmingCharacters(in: .whitespaces)
        onConnect(h, isPaired(h) ? nil : PairingCode.normalize(code))
    }
}
