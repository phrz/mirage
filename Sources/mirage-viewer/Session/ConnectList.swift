import SwiftUI
import MirageCore
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#else
import UIKit
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
    /// A pairing under way from this device (phrz, 2026-10-26): no Connect until the Mac allows it.
    var pairing: PairingPhase?
    /// For Get Info (phrz, 2026-10-26: shown on request, never in the row): its build and channel, and its update policy.
    var hostVersion: MirageVersion?
    var policy: UpdatePolicy?
    /// DESIGN §3.12: its Curtain and Lock when finished settings, as of its last Welcome.
    var hostSettings: HostSettings?
    var lockFailedAt: Date?
    /// The Mac's own icon (PNG, its model and colour), when it sent one.
    var icon: Data?
    var id: String { alias }
    /// Connect is offered (double-click, Return, a tap): not while the Mac has yet to allow this device.
    var canConnect: Bool { !(pairing?.inProgress ?? false) }

    var title: String { name.isEmpty ? alias : name }

    /// Whether the address says more than the name.
    private var addressDiffers: Bool {
        let bare = alias.lowercased().replacingOccurrences(of: ".local", with: "")
        return !name.isEmpty && bare != name.lowercased()
    }

    private static func ago(_ t: Date, now: Date, locale: Locale) -> String {
        let f = RelativeDateTimeFormatter(); f.locale = locale; f.unitsStyle = .full; f.dateTimeStyle = .named
        return now.timeIntervalSince(t) < 60 ? "just now" : f.localizedString(for: t, relativeTo: now)
    }

    /// The second line: one short status (phrz, 2026-10-26: no build or policy here, no separators). A pairing or a
    /// version refusal first, then unreachable, in use elsewhere, seen, connected; else the address when it says more.
    func detail(now: Date = Date(), locale: Locale = .current) -> String? {
        if let p = pairing, let line = p.line { return line }
        // A version refusal says which side to update, in place of the rest: connecting cannot work until then.
        switch update {
        case .hostTooOld, .viewerTooOld, .updating: return update.note(hostName: title)
        case .current, .updateAvailable: break
        }
        if unreachable { return "Unreachable" }
        if lastSeen != nil, streamingElsewhere { return "In use by another device" }
        if let t = lastSeen { return "Seen \(Self.ago(t, now: now, locale: locale))" }
        if let t = lastConnected { return "Connected \(Self.ago(t, now: now, locale: locale))" }
        return addressDiffers ? alias : nil
    }

    /// One Get Info row: a label and its value.
    struct InfoRow: Equatable, Hashable { var label: String; var value: String }

    /// Get Info (the Mac's info window, iOS's info sheet): what is known about it, as label and value; nothing unknown.
    func info(now: Date = Date(), locale: Locale = .current) -> [InfoRow] {
        var rows: [InfoRow] = []
        if let v = hostVersion {
            rows.append(.init(label: "Version", value: "Mirage \(v.display)"))
            rows.append(.init(label: "Channel", value: v.channel.map { $0.rawValue.capitalized } ?? "Local build"))
        }
        switch policy {
        case .automatic?: rows.append(.init(label: "Updates", value: "Automatically"))
        case .ask?: rows.append(.init(label: "Updates", value: "When asked"))
        case nil: break
        }
        if let hs = hostSettings {
            rows.append(.init(label: "Curtain", value: hs.curtain ? "On" : "Off"))
            let failed = lockFailedAt.map { ", but couldn't lock it \(Self.ago($0, now: now, locale: locale))" } ?? ""
            rows.append(.init(label: "Lock when finished", value: hs.lockWhenFinished ? "On\(failed)" : "Off"))
            rows.append(.init(label: "Stay reachable", value: hs.stayReachable ? "On" : "Off"))
        }
        if let m = model, !m.isEmpty { rows.append(.init(label: "Model", value: m)) }
        if let t = lastSeen { rows.append(.init(label: "Last seen", value: Self.ago(t, now: now, locale: locale))) }
        else if let t = lastConnected { rows.append(.init(label: "Last connected", value: Self.ago(t, now: now, locale: locale))) }
        if unreachable { rows.append(.init(label: "Status", value: "Not answering")) }
        else if streamingElsewhere { rows.append(.init(label: "Status", value: "In use by another device")) }
        if addressDiffers || name.isEmpty { rows.append(.init(label: "Address", value: alias)) }
        return rows
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
                              triggerFeature: h.triggerFeature, viewerMayTrigger: h.hostPolicy?.viewerMayTrigger, streamingElsewhere: h.hostStreaming ?? false,
                              hostVersion: h.hostVersion, policy: h.hostPolicy?.policy, hostSettings: h.hostSettings, lockFailedAt: h.hostLockFailedAt)
        }
    }

    /// From the store (MIRAGE_TEST_STORE for a throwaway one) and the recent list in `defaults`, with each Mac's own icon.
    static func load(store: Store? = try? Store(), defaults: UserDefaults = .standard) -> [PairedHost] {
        let known = (try? store?.knownHosts()) ?? [:]
        return hosts(known: known, recent: ViewerSettings.recentHosts(defaults)).map { h in
            var h = h
            if let id = known[h.alias]?.hostID, let icon = store?.hostIcon(hostID: id) { h.icon = icon.png256 ?? icon.png128 }
            return h
        }
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
    /// The Mac's own icon (PNG), when it sent one: drawn in place of the system's generic one.
    var png: Data? = nil

    var body: some View {
        #if os(macOS)
        Image(nsImage: png.flatMap(DeviceIcon.decoded) ?? DeviceIcon.image(model: model, family: family))
            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        #else
        if let img = png.flatMap(DeviceIcon.decoded) {
            Image(uiImage: img)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: DeviceIcon.symbolName(model: model, family: family))
                .font(.system(size: size * 0.62))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
        #endif
    }
}

enum DeviceIcon {
    static func family(model: String?, family: DeviceFamily?) -> DeviceFamily { family ?? DeviceModel.family(of: model) ?? .mac }

    #if os(macOS)
    typealias PlatformImage = NSImage
    #else
    typealias PlatformImage = UIImage
    #endif
    nonisolated(unsafe) private static var decodedCache: [Data: PlatformImage] = [:]
    private static let decodedLock = NSLock()
    /// A host's PNG icon, decoded once.
    static func decoded(_ png: Data) -> PlatformImage? {
        decodedLock.lock(); defer { decodedLock.unlock() }
        if let i = decodedCache[png] { return i }
        guard let i = PlatformImage(data: png) else { return nil }
        if decodedCache.count > 32 { decodedCache.removeAll() }
        decodedCache[png] = i
        return i
    }
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
                HostUpdateCenter.shared.finish(alias, name: name, end)
            }
        }
    }

    /// How an update from here ended: the row goes back to its own status; a passing note when it worked, an alert when
    /// it failed or rolled back (phrz, 2026-10-26: no result line stays in the list).
    func finish(_ alias: String, name: String, _ end: ControlMessage.UpdateStatus) {
        status[alias] = nil
        revision += 1
        if end.notPublished == true {
            ListNotices.shared.flash("\(name) doesn't see that build yet. Try again in a few minutes.")
            return
        }
        switch end.phase {
        case .done: ListNotices.shared.flash("Updated \(name): \(end.message)")
        case .failed: ListNotices.shared.alert(ListAlert(title: "\(name) did not update", message: end.message))
        case .rolledBack: ListNotices.shared.alert(ListAlert(title: "\(name) rolled back its update", message: end.message))
        default: break
        }
    }

    /// The row's line while an update runs (in place of its detail).
    func line(_ alias: String) -> String? {
        guard let s = status[alias], !s.isFinal else { return nil }
        return s.message
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

// MARK: - Removing a paired Mac (phrz, 2026-10-26)

/// The device lists' Remove (iOS: swipe to delete; Mac: right-click or Delete, with a confirmation): an open session to
/// that Mac ends first; the Mac is asked to forget this device (best effort, a control-only connection); then this
/// device forgets it: its record and pinned key, its resume token, and its place in the recent list.
@MainActor
final class HostRemovalCenter: ObservableObject {
    static let shared = HostRemovalCenter()
    /// Bumped after a removal: the lists reload.
    @Published private(set) var revision = 0
    /// Ends this app's session to an alias, if one is open (set by the app shells).
    var endSession: (String) -> Void = { _ in }
    var store: () -> Store? = { try? Store() }
    var connector: (String) -> HostUpdateTrigger.Connect = { HostConnector.connect(alias: $0, timeout: 3) }
    var defaults: UserDefaults = .standard

    func remove(_ h: PairedHost) async {
        let alias = h.alias, name = h.title
        endSession(alias)   // never forget a Mac with a session still open to it
        let connect = connector(alias)
        let outcome = await Task.detached { await HostUnpair.unpair(connect: connect) }.value
        Self.forgetLocally(alias: alias, store: store(), defaults: defaults)
        // phrz, 2026-10-26: no footer text. The row going is the success; a Mac that still lists this device is an alert.
        if let a = Self.alert(outcome, name: name) { ListNotices.shared.alert(a) }
        revision += 1
    }

    /// This device's side, whatever the host said.
    nonisolated static func forgetLocally(alias: String, store: Store?, defaults: UserDefaults) {
        _ = try? store?.forget(host: alias)
        let (host, port) = ConnectList.parseAddress(alias)
        Keychain.delete("resume-\(host):\(port)")
        defaults.set(ViewerSettings.recentHosts(defaults).filter { $0 != alias }, forKey: ViewerSettings.recentHostsKey)
        if defaults.string(forKey: "lastHost") == alias { defaults.removeObject(forKey: "lastHost") }
    }

    /// What needs acknowledging: nothing when the Mac forgot this device too.
    nonisolated static func alert(_ o: HostUnpair.Outcome, name: String) -> ListAlert? {
        switch o {
        case .unpaired: return nil
        case .notSupported:
            return ListAlert(title: "Removed \(name) from this device.",
                             message: "Its Mirage is too old to forget this device, so it still lists this device until you revoke it in its menu bar.")
        case .unreachable:
            return ListAlert(title: "Removed \(name) from this device.",
                             message: "It couldn't be reached, so it still lists this device until you revoke it in its menu bar.")
        }
    }

    /// The Mac's confirmation text.
    nonisolated static func confirmation(_ name: String) -> (title: String, message: String) {
        ("Remove \(name)?", "This device will need to pair again to connect.")
    }
}

// MARK: - Pairing without connecting (phrz, 2026-10-26)

/// One pairing from this device, as its row shows it. Adding a Mac pairs and returns to the list; it never opens a
/// session (the window stayed black until the Mac's Allow). The Mac's Allow comes as the end of the pairing exchange;
/// a status probe then checks that it takes this device, every few seconds for the first minute.
enum PairingPhase: Equatable {
    /// The code (or link) is out; the Mac asks its user to Allow or Deny. No Connect.
    case pending(hostName: String)
    /// The Mac allowed it and is recorded; checking that it takes this device. No Connect yet.
    case accepted(hostName: String)
    /// A normal row. `answered`: the check got through (else the minute ran out, and connecting will tell).
    case connectable(hostName: String, answered: Bool)
    /// Denied, a wrong code, an expired link, no answer: nothing was recorded.
    case refused(hostName: String, reason: String)

    enum Event: Equatable {
        /// The host's name, from its challenge (the code was right).
        case awaiting(String)
        /// The Mac allowed this device (its name, from its identity).
        case allowed(String)
        /// A status probe authenticated.
        case answered
        /// The minute of checks ran out.
        case gaveUp
        case failed(String)
    }

    var hostName: String {
        switch self {
        case .pending(let n), .accepted(let n), .connectable(let n, _), .refused(let n, _): return n
        }
    }
    var inProgress: Bool {
        switch self { case .pending, .accepted: return true; case .connectable, .refused: return false }
    }

    func next(_ e: Event) -> PairingPhase {
        switch (self, e) {
        case (.pending, .awaiting(let n)): return .pending(hostName: n)
        case (.pending, .allowed(let n)): return .accepted(hostName: n)
        case (.pending(let n), .failed(let why)): return .refused(hostName: n, reason: why)
        case (.accepted(let n), .answered): return .connectable(hostName: n, answered: true)
        case (.accepted(let n), .gaveUp): return .connectable(hostName: n, answered: false)
        default: return self   // a late or out-of-order event changes nothing
        }
    }

    /// The row's second line while in progress.
    var line: String? {
        switch self {
        case .pending(let n): return "Waiting for \(n) to accept…"
        case .accepted(let n): return "Checking \(n)…"
        case .connectable, .refused: return nil
        }
    }

    /// The note under the list once it ends.
    func note(connectHint: String) -> String? {
        switch self {
        case .pending, .accepted: return nil
        case .connectable(let n, true): return "\(n) is ready. \(connectHint)"
        case .connectable(let n, false): return "Paired with \(n). It hasn't answered since; connect when it's online."
        case .refused(let n, let why): return "Not paired with \(n): \(why)"
        }
    }
}

/// How a pairing runs: given the callback for "the Mac is asking", the host's record once it allowed this device.
enum HostPairing {
    typealias Run = @Sendable (_ awaiting: @escaping @Sendable (String) -> Void) async throws -> DeviceRecord

    /// The Mac's question waits for its user: it says no after 120 s itself; this side gives up a little later.
    static let answerWithin: TimeInterval = 150

    /// Pairing on a connection of its own (never a viewer's), closed when it ends; recorded under `alias`.
    static func run(host: String, port: UInt16, alias: String, code: String?, link: PairingLink?, within: TimeInterval = answerWithin) -> Run {
        return { awaiting in
            let store = try Store()
            let identity = try ViewerCredentials.clientIdentity(store: store)
            let client = QUICClient(host: host, port: port)
            defer { client.close() }
            try await client.connect(timeout: 15)
            guard let fp = client.tlsFingerprint else { throw MirageError.transport("no TLS fingerprint") }
            let stream = try await client.openStream()
            let session = ClientSession(identity: identity, store: store, alias: alias, tlsFingerprint: fp, stream: stream)
            final class Deadline: @unchecked Sendable { let lock = NSLock(); var fired = false }
            let timer = Deadline()
            return try await withThrowingTaskGroup(of: DeviceRecord?.self) { g in
                g.addTask {
                    if let link { return try await session.pair(link: link, onAwaitingHost: awaiting) }
                    guard let c = PairingCode.normalize(code ?? "") else { throw MirageError.pairingFailed("the code needs 6 digits") }
                    return try await session.pair(code: c, onAwaitingHost: awaiting)
                }
                g.addTask {
                    try await Task.sleep(for: .seconds(within))
                    timer.lock.withLock { timer.fired = true }
                    client.close()   // the pairing's receive returns
                    return nil
                }
                defer { g.cancelAll() }
                do {
                    if let r = try await g.next() ?? nil { return r }
                } catch {
                    let fired = timer.lock.withLock { timer.fired }
                    if !fired { throw error }
                }
                throw MirageError.pairingFailed("no answer from the Mac")
            }
        }
    }

    /// The reason a pairing ended, for the note: the host's own words when it sent some.
    static func reason(_ error: Error) -> String {
        switch error as? MirageError {
        case .pairingFailed(let s)?: return s
        case .authenticationFailed(let s)?: return s.hasPrefix("host rejected: ") ? String(s.dropFirst("host rejected: ".count)) : s
        case .transport?: return "it couldn't be reached"
        default: return "\(error)"
        }
    }
}

/// The device lists' pairings (Mac and iOS): the new row shows at once, selected, "Waiting for <Mac> to accept…" with no
/// Connect; once the Mac allows it a status probe checks that it takes this device (every few seconds, for a minute);
/// then it is a normal row and a note says it is ready. A refusal says why; nothing is recorded then.
@MainActor
final class HostPairingCenter: ObservableObject {
    static let shared = HostPairingCenter()
    @Published private(set) var phases: [String: PairingPhase] = [:]
    /// Bumped on every change: the lists reload.
    @Published private(set) var revision = 0
    /// The row to select (the new one): the lists take it and clear it.
    @Published var selectRequest: String?

    #if os(macOS)
    static let connectHint = "Double-click it to connect."
    #else
    static let connectHint = "Tap it to connect."
    #endif
    /// Whether a recorded host takes this device now (tests replace it).
    var check: (String) -> @Sendable () async -> Bool = { alias in
        let connect = HostConnector.connect(alias: alias, timeout: 3)
        return { await HostPairingCenter.authenticates(connect) }
    }
    var checkEvery: Duration = .seconds(3)
    var checkWindow: TimeInterval = 60
    var defaults: UserDefaults = .standard
    private var tasks: [String: Task<Void, Never>] = [:]

    /// A 6-digit code typed for a Mac by name or address.
    func pair(address: String, code: String) {
        let (host, port) = ConnectList.parseAddress(address)
        pair(alias: host, hostName: nil, run: HostPairing.run(host: host, port: port, alias: host, code: code, link: nil))
    }
    /// A scanned or opened link, after "Pair with <Mac>?".
    func pair(link: PairingLink) {
        pair(alias: link.address, hostName: link.hostName, run: HostPairing.run(host: link.address, port: link.port, alias: link.address, code: nil, link: link))
    }

    /// Starts one; the returned task ends with it (tests wait for it).
    @discardableResult
    func pair(alias: String, hostName: String?, run: @escaping HostPairing.Run) -> Task<Void, Never> {
        tasks[alias]?.cancel()
        phases[alias] = .pending(hostName: hostName ?? alias)
        selectRequest = alias
        revision += 1
        let check = self.check(alias), every = checkEvery, window = checkWindow
        let t = Task { [weak self] in
            // `run` and `check` are nonisolated: they run off the main actor, and a cancel (pairing the same Mac again) reaches them.
            let record: DeviceRecord
            do {
                record = try await run { name in Task { @MainActor in self?.apply(alias, .awaiting(name)) } }
            } catch {
                if !Task.isCancelled { self?.apply(alias, .failed(HostPairing.reason(error))) }
                return
            }
            guard !Task.isCancelled else { return }
            self?.apply(alias, .allowed(record.name))
            let deadline = Date().addingTimeInterval(window)
            while !Task.isCancelled {
                if await check() { self?.apply(alias, .answered); return }
                if Date() >= deadline { self?.apply(alias, .gaveUp); return }
                try? await Task.sleep(for: every)
            }
        }
        tasks[alias] = t
        return t
    }

    func apply(_ alias: String, _ e: PairingPhase.Event) {
        guard let now = phases[alias] else { return }
        let next = now.next(e)
        guard next != now else { return }
        phases[alias] = next
        if case .accepted = next { ViewerSettings.noteConnected(alias, defaults) }   // the new Mac first in the list
        // How it ended: a passing note when it worked, an alert when it did not (phrz, 2026-10-26: nothing stays).
        switch next {
        case .connectable:
            if let n = next.note(connectHint: Self.connectHint) { ListNotices.shared.flash(n) }
            selectRequest = alias
            tasks[alias] = nil
        case .refused(let n, let why):
            ListNotices.shared.alert(ListAlert(title: "Not paired with \(n)", message: why.prefix(1).uppercased() + why.dropFirst() + "."))
            tasks[alias] = nil
        case .pending, .accepted:
            break
        }
        revision += 1
    }

    /// The list with the pairings in progress: a Mac not recorded yet shows first; a recorded one carries its phase.
    func rows(_ hosts: [PairedHost]) -> [PairedHost] {
        var out = hosts
        var new: [PairedHost] = []
        for (alias, phase) in phases.sorted(by: { $0.key < $1.key }) where phase.inProgress {
            if let i = out.firstIndex(where: { $0.alias == alias }) { out[i].pairing = phase }
            else { new.append(PairedHost(alias: alias, name: phase.hostName, pairing: phase)) }
        }
        return new + out
    }

    /// Takes the row to select, once.
    func takeSelection() -> String? {
        defer { selectRequest = nil }
        return selectRequest
    }

    /// A status probe that authenticated (a refusal or no answer is "not yet").
    nonisolated static func authenticates(_ connect: HostUpdateTrigger.Connect) async -> Bool {
        do {
            let (s, close) = try await connect()
            defer { close() }
            _ = try await s.authenticate(features: [ControlMessage.Feature.updateStatus, ControlMessage.Feature.probe], probe: true)
            return true
        } catch { return false }
    }
}

// MARK: - Notes and alerts under the device lists (phrz, 2026-10-26)

/// Something to acknowledge: an alert with OK (NSAlert on the Mac, .alert on iOS).
struct ListAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    static func == (a: ListAlert, b: ListAlert) -> Bool { a.title == b.title && a.message == b.message }
}

/// The device lists' outcomes: nothing stays under a list. A passing note clears itself after a few seconds; what needs
/// acknowledging is an alert, one at a time. The rows' own status (Seen, Unreachable, Updating) is not here.
@MainActor
final class ListNotices: ObservableObject {
    static let shared = ListNotices()
    @Published private(set) var note: String?
    @Published private(set) var alerts: [ListAlert] = []
    var lifetime: Duration = .seconds(8)
    private var clearing: Task<Void, Never>?

    /// A note under the list for `lifetime`, then gone.
    func flash(_ text: String) {
        note = text
        clearing?.cancel()
        let lifetime = self.lifetime
        clearing = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, self?.note == text else { return }
            self?.note = nil
        }
    }

    func alert(_ a: ListAlert) { if !alerts.contains(a) { alerts.append(a) } }
    /// The alert showing now.
    var current: ListAlert? { alerts.first }
    func dismiss() { if !alerts.isEmpty { alerts.removeFirst() } }
    /// Tests: nothing showing.
    func reset() { clearing?.cancel(); note = nil; alerts = [] }
}
