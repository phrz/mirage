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
            .onAppear {
                state.autoConnectFromLaunchArguments()
                // Removing a paired Mac ends the session to it first.
                let st = state
                HostRemovalCenter.shared.endSession = { [weak st] alias in if st?.session?.host == alias { st?.disconnect() } }
            }
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
    /// Pairs and stays on the list (phrz, 2026-10-26): the new row waits for the Mac's Allow, then a tap connects.
    func pair(_ link: PairingLink) {
        offered = nil
        guard !link.isExpired() else { linkProblem = "That pairing code has expired. Scan the one the Mac shows now."; return }
        HostPairingCenter.shared.pair(link: link)
    }

    /// `HOST`, `HOST:PORT` or `[V6]:PORT`.
    static func parse(_ s: String) -> (host: String, port: UInt16) { ConnectList.parseAddress(s) }

    /// A paired Mac connects; a new one with its code pairs and stays on the list (no session until a tap).
    func connect(_ address: String, pairCode: String?) {
        if let pairCode { HostPairingCenter.shared.pair(address: address, code: pairCode); return }
        startSession(address, pairCode: nil)
    }

    private func startSession(_ address: String, pairCode: String?) {
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

    /// Test and power-user hook: `-connect HOST[:PORT] [-pair CODE]` as launch arguments (simctl launch) pairs and connects at once;
    /// `-pairLink URL` opens a pairing link as Camera would (the confirmation shows; nothing connects until Pair).
    private var autoConnected = false
    func autoConnectFromLaunchArguments() {
        if !autoConnected, let link = UserDefaults.standard.string(forKey: "pairLink"), let url = URL(string: link) { autoConnected = true; open(url); return }
        guard !autoConnected, session == nil, let host = UserDefaults.standard.string(forKey: "connect"), !host.isEmpty else { return }
        autoConnected = true
        startSession(host, pairCode: UserDefaults.standard.string(forKey: "pair").flatMap { PairingCode.normalize($0) })
    }
}

/// The paired Macs, each with its device's symbol, most recently connected first; a tap connects. + (the navigation bar)
/// adds another one by name or address with its 6-digit code or the QR code its Pair a Device… shows.
struct ConnectScreen: View {
    let onConnect: (String, String?) -> Void
    let onLink: (PairingLink) -> Void
    @State private var hosts: [PairedHost] = []
    @State private var adding = ProcessInfo.processInfo.environment["MIRAGE_TEST_OPEN_ADD"] != nil
    /// A pairing link from the + sheet, handed to the root once that sheet is gone.
    @State private var pendingLink: PairingLink?
    @ObservedObject private var updates = HostUpdateCenter.shared
    @ObservedObject private var probes = HostProbeCenter.shared
    @ObservedObject private var removal = HostRemovalCenter.shared
    @ObservedObject private var pairing = HostPairingCenter.shared
    @ObservedObject private var notices = ListNotices.shared
    /// The new Mac's row, highlighted after pairing (a phone's list has no selection).
    @State private var highlighted: String?
    /// The Mac whose Get Info sheet shows (long-press → Get Info).
    @State private var infoHost: PairedHost?
    @Environment(\.scenePhase) private var scenePhase

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
                    ScrollViewReader { scroller in
                        List(hosts) { h in
                            Button { if h.canConnect { onConnect(h.alias, nil) } } label: { row(h) }
                                .tint(.primary)
                                .listRowBackground(highlighted == h.alias ? Color.accentColor.opacity(0.22) : nil)
                                // Swipe to delete: forget this Mac (it is asked to forget this device too).
                                .swipeActions(edge: .trailing) {
                                    if h.canConnect {
                                        Button(role: .destructive) { Task { await removal.remove(h) } } label: { Label("Delete", systemImage: "trash") }
                                    }
                                }
                                // Long-press → Update, straight away (the arrow asks first).
                                .contextMenu {
                                    if h.canConnect {
                                        Button { onConnect(h.alias, nil) } label: { Label("Connect", systemImage: "play.display") }
                                        Button { infoHost = h } label: { Label("Get Info", systemImage: "info.circle") }
                                    }
                                    if case .updateAvailable = h.update, UpdatePrompt.state(h) == .canUpdate, !updates.isRunning(h.alias) {
                                        Button { updates.update(h) } label: { Label("Update", systemImage: "arrow.up.circle") }
                                    }
                                }
                                .id(h.alias)
                        }
                        .onChange(of: highlighted) { if let a = highlighted { withAnimation { scroller.scrollTo(a) } } }
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
            // The "Pair with …?" alert lives on the root view: it is asked for only once this sheet is gone (onDismiss). An
            // alert presented while sheets were still animating out was dropped: the scanner closed and nothing happened, the
            // phone never connected (phrz's new iPhone, 2026-10-25).
            .sheet(isPresented: $adding, onDismiss: { if let l = pendingLink { pendingLink = nil; onLink(l) } }) {
                AddHostScreen(paired: hosts.filter(\.canConnect), onCancel: { adding = false }, onConnect: { address, code in
                    adding = false
                    onConnect(address, code)
                }, onLink: { link in
                    pendingLink = link
                    adding = false
                })
            }
        }
        .onAppear { reload() }
        .onChange(of: updates.revision) { reload() }
        .onChange(of: probes.revision) { reload() }
        .onChange(of: removal.revision) { reload() }
        .onChange(of: pairing.revision) { reload() }
        // A passing note (a Mac ready after pairing, an update done): gone after a few seconds.
        .safeAreaInset(edge: .bottom) {
            if let n = notices.note { Text(n).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 8) }
        }
        // What needs acknowledging: an alert with OK, one at a time.
        .alert(notices.current?.title ?? "", isPresented: Binding(get: { notices.current != nil }, set: { if !$0 { notices.dismiss() } }),
               presenting: notices.current) { _ in
            Button("OK", role: .cancel) {}
        } message: { a in
            Text(a.message)
        }
        // Status probes (U7): while this list shows, and when the app comes back to the foreground with it showing.
        .onAppear { probes.listAppeared() }
        .onDisappear { probes.listDisappeared() }
        .onChange(of: scenePhase) { if scenePhase == .active { probes.appBecameActive() } }
        .hostUpdatePrompt(updates)
        .sheet(item: $infoHost) { h in HostInfoSheet(host: h) }
    }

    /// Known-hosts with the pairings under way; a new Mac's row is highlighted.
    private func reload() {
        hosts = pairing.rows(ConnectList.load())
        if let s = pairing.takeSelection() { highlighted = s }
    }

    private func row(_ h: PairedHost) -> some View {
        HStack(spacing: 12) {
            DeviceIconView(model: h.model, family: h.family, size: 34, png: h.icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.title).foregroundStyle(.primary)
                if let d = updates.line(h.alias) ?? h.detail() { Text(d).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if h.pairing?.inProgress == true { ProgressView() } else { HostUpdateBadge(host: h) }
        }
        .contentShape(Rectangle())
    }
}

/// Get Info for a paired Mac (long-press → Get Info): its icon and name, then short grey lines.
struct HostInfoSheet: View {
    let host: PairedHost
    var body: some View {
        VStack(spacing: 10) {
            DeviceIconView(model: host.model, family: host.family, size: 72, png: host.icon)
                .foregroundStyle(.secondary)
            Text(host.title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(host.info(), id: \.self) { r in
                    GridRow {
                        Text(r.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(r.value)
                    }
                }
            }
            .font(.footnote)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}

/// The + sheet: name or address, then the pairing code (typed, or its QR scanned) unless this device is already paired.
struct AddHostScreen: View {
    let paired: [PairedHost]
    let onCancel: () -> Void
    let onConnect: (String, String?) -> Void
    let onLink: (PairingLink) -> Void
    @State private var form = AddHostForm()
    /// Test knob MIRAGE_TEST_SCAN_LINK=<link> (with MIRAGE_TEST_OPEN_ADD): the scanner opens and takes that link as if
    /// scanned, so the sheet-to-alert hand-off can be checked in the simulator (no camera there).
    @State private var scanning = ProcessInfo.processInfo.environment["MIRAGE_TEST_SCAN_LINK"] != nil
    /// A scanned link, handed on once the scanner sheet is gone.
    @State private var scanned: PairingLink?

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
                    Button(form.needsCode(paired) ? "Pair" : "Connect") { if let r = form.request(paired) { onConnect(r.address, r.code) } }
                        .disabled(form.request(paired) == nil)
                }
            }
            .sheet(isPresented: $scanning, onDismiss: { if let l = scanned { scanned = nil; onLink(l) } }) { PairingScanSheet(onLink: { scanned = $0 }) }
        }
        .presentationDetents([.medium, .large])
    }
}
