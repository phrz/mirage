import SwiftUI
import MirageCore
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// One paired Mac in the connect list (the Mac's connect window, iOS's connect screen): what known-hosts holds for it.
struct PairedHost: Identifiable, Equatable {
    /// What was typed when pairing: the key into known-hosts, and what connecting dials.
    var alias: String
    /// The host's own name ("mac-daddy").
    var name: String
    var model: String?
    var family: DeviceFamily?
    var lastConnected: Date?
    /// DESIGN §3.10: an update for it (the yellow arrow, U4), or which side to update when one refused the other.
    var update: HostUpdateState = .current
    /// It takes an update trigger from this device (U4): the prompt's Update button, else how to update it instead.
    var canTrigger = false
    /// U7, from the last Welcome (a session's or a status probe's): when it last answered, whether it does not now,
    /// whether it has the remote trigger at all (nil: never learned) and lets this device use it, and whether another
    /// device streams from it.
    var lastSeen: Date?
    var unreachable = false
    var triggerFeature: Bool?
    var viewerMayTrigger: Bool?
    var streamingElsewhere = false
    var id: String { alias }

    var title: String { name.isEmpty ? alias : name }

    /// The second line: the address when it is not just the name, and when this viewer last connected.
    func detail(now: Date = Date(), locale: Locale = .current) -> String? {
        // A version refusal says which side to update, in place of the rest: connecting cannot work until then.
        switch update {
        case .hostTooOld, .viewerTooOld, .updating: return update.note(hostName: title)
        case .current, .updateAvailable: break
        }
        var parts: [String] = []
        let bare = alias.lowercased().replacingOccurrences(of: ".local", with: "")
        if !name.isEmpty, bare != name.lowercased() { parts.append(alias) }
        let f = RelativeDateTimeFormatter(); f.locale = locale; f.unitsStyle = .full; f.dateTimeStyle = .named
        func ago(_ t: Date) -> String { now.timeIntervalSince(t) < 60 ? "just now" : f.localizedString(for: t, relativeTo: now) }
        // What it is now, as far as known: unreachable, seen (by a probe or a session), else when this device connected.
        if unreachable {
            parts.append(lastSeen.map { "Unreachable · last seen \(ago($0))" } ?? "Unreachable")
        } else if let t = lastSeen {
            parts.append("Seen \(ago(t))")
            if streamingElsewhere { parts.append("In use by another device") }
        } else if let t = lastConnected {
            parts.append("Connected \(ago(t))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The connect list's state: which Macs it shows, in what order, which one is chosen at first.
enum ConnectList {
    /// Paired Macs: this device's recent list first (most recent at the top), then the others by when they were last
    /// connected to (known-hosts), then by name.
    static func hosts(known: [String: Store.KnownHost], recent: [String]) -> [PairedHost] {
        let recentPaired = recent.filter { known[$0] != nil }
        let rest = known.keys.filter { !recentPaired.contains($0) }.sorted { a, b in
            let (x, y) = (known[a]!, known[b]!)
            let (tx, ty) = (x.lastConnected ?? .distantPast, y.lastConnected ?? .distantPast)
            if tx != ty { return tx > ty }
            return (x.hostName.lowercased(), a) < (y.hostName.lowercased(), b)
        }
        return (recentPaired + rest).map { alias in
            let h = known[alias]!
            return PairedHost(alias: alias, name: h.hostName, model: h.model, family: h.deviceFamily, lastConnected: h.lastConnected, update: h.updateState,
                              canTrigger: h.updateTrigger ?? false, lastSeen: h.lastSeen, unreachable: h.unreachableSince != nil,
                              triggerFeature: h.triggerFeature, viewerMayTrigger: h.hostPolicy?.viewerMayTrigger, streamingElsewhere: h.hostStreaming ?? false)
        }
    }

    /// From the store (MIRAGE_TEST_STORE for a throwaway one) and the recent list in `defaults`.
    static func load(store: Store? = try? Store(), defaults: UserDefaults = .standard) -> [PairedHost] {
        hosts(known: (try? store?.knownHosts()) ?? [:], recent: ViewerSettings.recentHosts(defaults))
    }

    /// The row chosen when the list opens: the Mac connected to last if it is listed, else the first one.
    static func initialSelection(_ hosts: [PairedHost], lastHost: String?) -> String? {
        if let l = lastHost, hosts.contains(where: { $0.alias == l }) { return l }
        return hosts.first?.alias
    }

    /// `HOST`, `HOST:PORT` or `[V6]:PORT`.
    static func parseAddress(_ s: String, defaultPort: UInt16 = Mirage.defaultPort) -> (host: String, port: UInt16) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
            let h = String(t[t.index(after: t.startIndex)..<close])
            let rest = t[t.index(after: close)...]
            return (h, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? defaultPort : defaultPort)
        }
        let parts = t.split(separator: ":")
        if parts.count == 2, let p = UInt16(parts[1]) { return (String(parts[0]), p) }
        return (t, defaultPort)
    }
}

/// The add sheet (the + button): a Mac by name or address, and the 6-digit code its Pair a Device… shows unless this
/// device is already paired with it.
struct AddHostForm: Equatable {
    var address = ""
    var code = ""
    var target: String { address.trimmingCharacters(in: .whitespaces) }
    func isPaired(_ paired: [PairedHost]) -> Bool {
        let host = ConnectList.parseAddress(target).host
        return !host.isEmpty && paired.contains { $0.alias == host || $0.alias == target }
    }
    func needsCode(_ paired: [PairedHost]) -> Bool { !isPaired(paired) }
    /// What Connect does: the address and the code (nil for a paired Mac), or nil while incomplete.
    func request(_ paired: [PairedHost]) -> (address: String, code: String?)? {
        guard !target.isEmpty else { return nil }
        if isPaired(paired) { return (target, nil) }
        guard let c = PairingCode.normalize(code) else { return nil }
        return (target, c)
    }
}

/// A device's icon. macOS: the system's own picture of that model (CoreTypes, through `NSWorkspace.icon(for:)`), else its
/// family's, else a generic Mac's. iOS has no CoreTypes icons: the family's SF Symbol.
struct DeviceIconView: View {
    let model: String?
    let family: DeviceFamily?
    var size: CGFloat = 32

    var body: some View {
        #if os(macOS)
        Image(nsImage: DeviceIcon.image(model: model, family: family))
            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        #else
        Image(systemName: DeviceIcon.symbolName(model: model, family: family))
            .font(.system(size: size * 0.62))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        #endif
    }
}

enum DeviceIcon {
    static func family(model: String?, family: DeviceFamily?) -> DeviceFamily { family ?? DeviceModel.family(of: model) ?? .mac }
    static func symbolName(model: String?, family: DeviceFamily?) -> String { Self.family(model: model, family: family).symbolName }

    #if os(macOS)
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    /// The system's type for this model (exact: colour and size), else for its family, else for a Mac.
    static func type(model: String?, family: DeviceFamily?) -> UTType? {
        if let m = model, !m.isEmpty, let t = UTType(tag: m, tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil), !t.isDynamic {
            return t
        }
        if let f = family ?? DeviceModel.family(of: model), let t = UTType(f.typeIdentifier) { return t }
        return UTType(DeviceFamily.mac.typeIdentifier)
    }

    static func image(model: String?, family: DeviceFamily?) -> NSImage {
        let key = "\(model ?? "")|\(family?.rawValue ?? "")"
        lock.lock(); defer { lock.unlock() }
        if let i = cache[key] { return i }
        let img = type(model: model, family: family).map { NSWorkspace.shared.icon(for: $0) }
            ?? NSImage(systemSymbolName: Self.family(model: model, family: family).symbolName, accessibilityDescription: nil)
            ?? NSImage()
        cache[key] = img
        return img
    }

    /// A copy at `points` for a menu item.
    static func menuImage(model: String?, family: DeviceFamily? = nil, points: CGFloat = 16) -> NSImage {
        let img = (image(model: model, family: family).copy() as? NSImage) ?? NSImage()
        img.size = NSSize(width: points, height: points)
        return img
    }
    #endif
}

// MARK: - Host updates from the lists (DESIGN §3.10, U4)

/// Updates triggered from this device's lists of paired Macs (DESIGN §3.10, U4): one at a time per Mac, each on a
/// connection of its own (a viewer window on that Mac is left alone; it reconnects by itself after the restart).
@MainActor
final class HostUpdateCenter: ObservableObject {
    static let shared = HostUpdateCenter()
    /// The latest step of each update in progress or just ended, by alias.
    @Published private(set) var status: [String: ControlMessage.UpdateStatus] = [:]
    /// Bumped when an update ends: the lists reload known-hosts (the new build and feed state came with the last Welcome).
    @Published private(set) var revision = 0
    /// The Mac whose update prompt is showing.
    @Published var prompt: PairedHost?

    func isRunning(_ alias: String) -> Bool { status[alias].map { !$0.isFinal } ?? false }

    func update(_ h: PairedHost) {
        guard !isRunning(h.alias), case .updateAvailable(_, let to) = h.update else { return }
        let alias = h.alias, name = h.title
        status[alias] = .init(phase: .checking, message: "Asking \(name) to update…", yours: true)
        let connect = HostConnector.connect(alias: alias, timeout: 10)
        Task.detached {
            let end = await HostUpdateTrigger.run(connect: connect, command: .update(targetBuild: to.build), hostName: name) { st in
                Task { @MainActor in HostUpdateCenter.shared.status[alias] = st }
            }
            await MainActor.run {
                HostUpdateCenter.shared.status[alias] = end
                HostUpdateCenter.shared.revision += 1
            }
        }
    }

    /// The row's line while an update runs or just ended (in place of its detail).
    func line(_ alias: String) -> String? {
        guard let s = status[alias] else { return nil }
        switch s.phase {
        case .done: return "Updated: \(s.message)"
        case .failed: return "Update failed: \(s.message)"
        case .rolledBack: return "Update rolled back: \(s.message)"
        default: return s.message
        }
    }

    /// Opens the prompt for a row; a Mac whose trigger was never learned is probed first (the prompt says "Checking…").
    func ask(_ h: PairedHost) {
        prompt = h
        guard UpdatePrompt.state(h) == .checking else { return }
        let alias = h.alias
        Task {
            await HostProbeCenter.shared.probeNow(alias)
            if prompt?.alias == alias { prompt = ConnectList.load().first { $0.alias == alias } ?? prompt }
        }
    }

    /// The prompt's text: the Mac, its current and new build and channel, and what can be done about it.
    static func promptText(_ h: PairedHost) -> String { UpdatePrompt.text(h) }
}

/// The update prompt's states (U7): never claim a Mac "doesn't take updates" from a missing or stale record.
enum UpdatePrompt: Equatable {
    /// Its trigger was never learned (no probe or session since it had one): ask it now.
    case checking
    case unreachable
    /// It has no remote trigger (a build from before U4).
    case olderHost
    /// It has one, but allows updates only on itself.
    case restricted
    case canUpdate

    static func state(_ h: PairedHost) -> UpdatePrompt {
        if h.unreachable { return .unreachable }
        if h.canTrigger { return .canUpdate }
        guard let feature = h.triggerFeature else { return .checking }
        if !feature { return .olderHost }
        if h.viewerMayTrigger == false { return .restricted }
        return .checking   // the feature, but no permission learned: ask again
    }

    static func text(_ h: PairedHost) -> String {
        guard case .updateAvailable(let from, let to) = h.update else { return "" }
        let base = "\(h.title): \(from.display) → \(to.display), \(to.channelName)"
        switch state(h) {
        case .canUpdate: return base
        case .checking: return base + "\n\nChecking \(h.title)…"
        case .unreachable: return base + "\n\n\(h.title) can't be reached right now. Try again when it is online."
        case .olderHost: return base + "\n\nThis build of Mirage on \(h.title) can't be updated from another device. Update it from its menu bar, or over SSH: miraged update --now"
        case .restricted: return base + "\n\n\(h.title) allows updates only on itself: its menu bar, or over SSH: miraged update --now"
        }
    }
}

/// A fresh authenticated session to a paired host, for the trigger and the status probe: its own connection, never a
/// viewer's.
enum HostConnector {
    static func connect(alias: String, timeout: TimeInterval) -> HostUpdateTrigger.Connect {
        let (host, port) = ConnectList.parseAddress(alias)
        return {
            let store = try Store()
            let identity = try ViewerCredentials.clientIdentity(store: store)
            let client = QUICClient(host: host, port: port)
            do { try await client.connect(timeout: timeout) } catch { client.close(); throw error }
            guard let fp = client.tlsFingerprint else { client.close(); throw MirageError.transport("no TLS fingerprint") }
            let stream: MessageStream
            do { stream = try await client.openStream() } catch { client.close(); throw MirageError.transport("\(error)") }
            return (ClientSession(identity: identity, store: store, alias: alias, tlsFingerprint: fp, stream: stream), { client.close() })
        }
    }
}

/// The device lists' status probes (U7): each paired Mac learns about the others without a screen share. One host at a
/// time, 3 s to connect, never one this device has a session with (that session's own Welcome keeps the record): when a
/// list appears or the app comes to the foreground, then every 60 s while a list shows, and (on the Mac) every 10 min in
/// the background. iOS probes only while its list shows.
@MainActor
final class HostProbeCenter: ObservableObject {
    static let shared = HostProbeCenter()
    /// Bumped after each probe: the lists reload known-hosts.
    @Published private(set) var revision = 0
    private var listsVisible = 0
    private var loop: Task<Void, Never>?
    static let visibleEvery: TimeInterval = 60
    #if os(macOS)
    static let backgroundEvery: TimeInterval? = 600
    #else
    static let backgroundEvery: TimeInterval? = nil
    #endif

    /// A session open to this alias right now (its control channel is the source then). Tests replace it.
    var sessionOpen: (String) -> Bool = { ViewerPreferences.shared.session?.host == $0 }
    /// Where the records live (tests: a throwaway store), and how a host is reached.
    var store: () -> Store? = { try? Store() }
    var connector: (String) -> HostUpdateTrigger.Connect = { HostConnector.connect(alias: $0, timeout: 3) }
    /// Probes actually made (not skipped).
    private(set) var probesRun = 0

    func listAppeared() { listsVisible += 1; restart() }
    func listDisappeared() { listsVisible = max(0, listsVisible - 1) }
    func appBecameActive() { restart() }

    private func restart() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeAll()
                guard let self, let every = self.listsVisible > 0 ? Self.visibleEvery : Self.backgroundEvery else { return }
                try? await Task.sleep(for: .seconds(every * Double.random(in: 0.9...1.1)))   // jitter
            }
        }
    }

    private func probeAll() async {
        for h in ConnectList.load(store: store()) where !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 0...400)))
            await probeNow(h.alias)
        }
    }

    /// One host now, unless a session to it is open.
    func probeNow(_ alias: String) async {
        guard !sessionOpen(alias), let store = store() else { return }
        let connect = connector(alias)
        probesRun += 1
        _ = await Task.detached { await HostProbe.probe(connect: connect, store: store, alias: alias) }.value
        revision += 1
    }
}

/// The yellow circle with an up-arrow beside a Mac with an update (DESIGN §3.10); a spinner while one runs.
struct HostUpdateBadge: View {
    let host: PairedHost
    @ObservedObject var center = HostUpdateCenter.shared
    /// On a selected row (the accent-coloured selection) the badge inverts, as the system's own list badges do: a white
    /// circle with the arrow cut out, so the selection shows through it (phrz, 2026-10-26).
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if center.isRunning(host.alias) {
            ProgressView().controlSize(.small)
                .accessibilityLabel("Updating \(host.title)")
        } else if case .updating = host.update {
            // The host is installing one already (Automatic, or another device): "updating", no offer.
            ProgressView().controlSize(.small)
                .help("Updating")
                .accessibilityLabel("\(host.title) is updating")
        } else if case .updateAvailable = host.update {
            Button { center.ask(host) } label: { UpdateArrow(selected: prominence == .increased) }
            .buttonStyle(.borderless)
            .help("Update available")
            .accessibilityLabel("Update \(host.title)")
        }
    }
}

/// The update arrow: black on a yellow circle; on a selected row, a white circle with the arrow cut out (monochrome
/// rendering knocks the arrow out of the fill), so the selection's colour shows through it.
struct UpdateArrow: View {
    var selected: Bool
    var body: some View {
        if selected {
            Image(systemName: "arrow.up.circle.fill")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .font(.system(size: 20))
        } else {
            Image(systemName: "arrow.up.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, .yellow)
                .font(.system(size: 20))
        }
    }
}

extension View {
    /// The update prompt for the rows' arrows (Update / Cancel), on the list.
    func hostUpdatePrompt(_ center: HostUpdateCenter) -> some View {
        alert(center.prompt.map { "Update \($0.title)?" } ?? "",
              isPresented: Binding(get: { center.prompt != nil }, set: { if !$0 { center.prompt = nil } }),
              presenting: center.prompt) { h in
            switch UpdatePrompt.state(h) {
            case .canUpdate:
                Button("Update") { center.update(h) }
                Button("Cancel", role: .cancel) {}
            case .checking:
                Button("Cancel", role: .cancel) {}
            case .unreachable, .olderHost, .restricted:
                Button("OK", role: .cancel) {}
            }
        } message: { h in
            Text(HostUpdateCenter.promptText(h))
        }
    }
}
