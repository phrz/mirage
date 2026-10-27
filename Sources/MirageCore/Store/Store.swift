import Foundation

/// Persistent state under ~/Library/Application Support/Mirage.
/// Every file is created 0600; the directory 0700.
public final class Store: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default
    private let lock = NSLock()

    public init(root: URL? = nil) throws {
        if let root {
            self.root = root
        } else if let test = ProcessInfo.processInfo.environment["MIRAGE_TEST_STORE"], !test.isEmpty {
            // Test only: a throwaway host or viewer (its own identity, pairings and tunables), e.g. a loopback host for the
            // iOS Simulator that must not touch this Mac's real pairings.
            self.root = URL(fileURLWithPath: (test as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            self.root = base.appendingPathComponent("Mirage", isDirectory: true)
        }
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
    }

    public func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    // MARK: Generic JSON files

    func read<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        lock.lock(); defer { lock.unlock() }
        let u = url(name)
        guard fm.fileExists(atPath: u.path) else { return nil }
        let enc = JSONDecoder(); enc.dateDecodingStrategy = .iso8601
        return try enc.decode(type, from: Data(contentsOf: u))
    }

    func write<T: Encodable>(_ value: T, _ name: String) throws {
        lock.lock(); defer { lock.unlock() }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(value)
        let u = url(name)
        try data.write(to: u, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    }

    public func remove(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        try? fm.removeItem(at: url(name))
    }

    // MARK: Identity

    /// Loads or creates this machine's identity key. The display name is not persisted;
    /// callers pass the current one (computer name or --name) every launch.
    public func identity(role: String, name: String) throws -> DeviceIdentity {
        let file = "\(role)-identity.json"
        if let f = try read(IdentityFile.self, file) {
            return try DeviceIdentity(seed: f.seed, name: name)
        }
        let id = DeviceIdentity(name: name)
        try write(IdentityFile(seed: id.signingKey.rawRepresentation, name: nil), file)
        return id
    }

    // MARK: Host: authorized devices

    public func authorizedDevices() throws -> [DeviceRecord] {
        try read([DeviceRecord].self, "authorized-devices.json") ?? []
    }
    public func authorize(_ device: DeviceRecord) throws {
        var list = try authorizedDevices().filter { $0.id != device.id }
        list.append(device)
        try write(list, "authorized-devices.json")
    }
    /// Replaces an authorized device's record in place (its model learned at a later connection); nothing if it was revoked.
    public func updateAuthorized(_ device: DeviceRecord) throws {
        var list = try authorizedDevices()
        guard let i = list.firstIndex(where: { $0.id == device.id && $0.publicKey == device.publicKey }) else { return }
        list[i] = device
        try write(list, "authorized-devices.json")
    }
    public func revoke(idPrefix: String) throws -> [DeviceRecord] {
        let list = try authorizedDevices()
        let removed = list.filter { $0.id.hasPrefix(idPrefix) }
        try write(list.filter { !$0.id.hasPrefix(idPrefix) }, "authorized-devices.json")
        return removed
    }

    // MARK: Host: pending pairing code (written by `miraged pair`, consumed by the daemon)

    public struct PendingPairing: Codable {
        public var attemptID: String
        public var code: String
        public var expiresAt: Date
        public init(attemptID: String = UUID().uuidString, code: String, expiresAt: Date) {
            self.attemptID = attemptID; self.code = code; self.expiresAt = expiresAt
        }
    }
    public struct PairingResult: Codable {
        public var attemptID: String
        public var ok: Bool
        public var message: String
        public var at: Date
    }

    public func setPendingPairing(_ p: PendingPairing) throws { try write(p, "pending-pair.json") }
    /// Returns the pending code and removes it: one attempt per code.
    public func consumePendingPairing() throws -> PendingPairing? {
        guard let p = try read(PendingPairing.self, "pending-pair.json") else { return nil }
        remove("pending-pair.json")
        return p.expiresAt > Date() ? p : nil
    }
    public func setPairingResult(attemptID: String, ok: Bool, message: String) throws {
        try write(PairingResult(attemptID: attemptID, ok: ok, message: message, at: Date()), "pair-result.json")
    }
    /// Returns and clears the result for this attempt only, so two `pair` runs cannot steal each other's outcome.
    public func takePairingResult(attemptID: String) throws -> PairingResult? {
        guard let r = try read(PairingResult.self, "pair-result.json"), r.attemptID == attemptID else { return nil }
        remove("pair-result.json")
        return r
    }

    /// The Allow/Deny question for a pairing that `miraged pair` started (no menu-bar UI): the daemon writes the request
    /// once the device's identity is verified, the `pair` command asks its terminal and writes the decision.
    public struct PairingConfirmRequest: Codable {
        public var attemptID: String
        public var deviceName: String
        public var deviceID: String
    }
    public func setPairingConfirmRequest(_ r: PairingConfirmRequest) throws { try write(r, "pair-confirm.json") }
    public func takePairingConfirmRequest(attemptID: String) throws -> PairingConfirmRequest? {
        guard let r = try read(PairingConfirmRequest.self, "pair-confirm.json"), r.attemptID == attemptID else { return nil }
        remove("pair-confirm.json")
        return r
    }
    private struct PairingDecision: Codable { var attemptID: String; var allow: Bool }
    public func setPairingDecision(attemptID: String, allow: Bool) throws { try write(PairingDecision(attemptID: attemptID, allow: allow), "pair-decision.json") }
    public func takePairingDecision(attemptID: String) throws -> Bool? {
        guard let d = try read(PairingDecision.self, "pair-decision.json"), d.attemptID == attemptID else { return nil }
        remove("pair-decision.json")
        return d.allow
    }

    // MARK: Client: known hosts

    public struct KnownHost: Codable, Equatable {
        public var hostID: String
        public var hostName: String
        public var publicKey: Data
        public var endpoint: String
        public var pairedAt: Date
        /// The host's model identifier ("Mac15,14") and family (`DeviceFamily` raw value) as it last reported them, for
        /// its icon; nil until a connection to a host that reports them.
        public var model: String?
        public var family: String?
        /// The last time this viewer authenticated to it.
        public var lastConnected: Date?
        /// DESIGN §3.10 (the device lists' update indicator): the build its last Welcome reported, the newest build its
        /// feed check had found, and, when it refused this viewer for its version (or the reverse), which side to update
        /// (`ControlMessage.Reject.Code` raw value). Cleared by the next successful connection.
        public var hostVersion: MirageVersion?
        public var latestAvailable: MirageVersion?
        public var incompatibility: String?
        /// The host takes an update trigger from this viewer (it has U4's trigger, and does not restrict updates to itself).
        public var updateTrigger: Bool?
        /// An update the host was running at the last connection (its Welcome's updateResult, not yet final).
        public var updating: ControlMessage.UpdateStatus?
        /// U7, from the last Welcome (a session's, or a status probe's): when the host last answered, since when it has
        /// not, whether it has the remote trigger at all and its update permission, whether it streams to another device,
        /// and the protocol range it speaks.
        public var lastSeen: Date?
        public var unreachableSince: Date?
        /// Status probes in a row that got no answer (phrz, 2026-10-27: the list shows "Not reachable" only after
        /// `HostProbe.unreachableAfter` of them, so one lost packet never greys a row). nil: none since the last answer.
        public var failedProbes: Int?
        /// The host answered and refused this device (not for its version): its words ("unknown device"). nil otherwise.
        public var refusal: String?
        /// The device list's "Not reachable": no answer since `unreachableSince`, to enough probes in a row. A record from
        /// before the count was kept counts as unreachable.
        public var isUnreachable: Bool { unreachableSince != nil && (failedProbes ?? HostProbe.unreachableAfter) >= HostProbe.unreachableAfter }
        public var triggerFeature: Bool?
        public var hostPolicy: UpdatePermission?
        /// DESIGN §3.12: the host's Curtain and Lock when finished settings, from its last Welcome.
        public var hostSettings: HostSettings?
        public var hostLockFailedAt: Date?
        public var hostStreaming: Bool?
        public var hostProtocol: Int?
        public var hostMinProtocol: Int?
        /// Its update state as the device list shows it.
        public var updateState: HostUpdateState { updateState(now: Date()) }
        /// An "updating" learned more than `updatingFreshFor` ago (no newer Welcome or probe since) is stale: it never hides
        /// the Update offer behind a spinner.
        public func updateState(now: Date) -> HostUpdateState {
            let fresh = updating.flatMap { u in lastSeen.flatMap { now.timeIntervalSince($0) < Self.updatingFreshFor ? u : nil } }
            return .evaluate(hostVersion: hostVersion, latestAvailable: latestAvailable,
                             incompatibility: incompatibility.flatMap(ControlMessage.Reject.Code.init(rawValue:)), updating: fresh)
        }
        public static let updatingFreshFor: TimeInterval = 10 * 60
        public init(hostID: String, hostName: String, publicKey: Data, endpoint: String, pairedAt: Date, model: String? = nil, family: String? = nil, lastConnected: Date? = nil) {
            self.hostID = hostID; self.hostName = hostName; self.publicKey = publicKey; self.endpoint = endpoint; self.pairedAt = pairedAt
            self.model = model; self.family = family; self.lastConnected = lastConnected
        }
        /// Its family: as the host named it, else from its model identifier.
        public var deviceFamily: DeviceFamily? { family.flatMap(DeviceFamily.init(rawValue:)) ?? DeviceModel.family(of: model) }
    }
    public func knownHosts() throws -> [String: KnownHost] {
        try read([String: KnownHost].self, "known-hosts.json") ?? [:]
    }
    public func remember(host: KnownHost, as alias: String) throws {
        var hosts = try knownHosts()
        hosts[alias] = host
        try write(hosts, "known-hosts.json")
    }
    /// Forgets a paired host (the device list's Remove): its record, with the host key it pinned. True if it was known.
    @discardableResult
    public func forget(host alias: String) throws -> Bool {
        var hosts = try knownHosts()
        guard let gone = hosts.removeValue(forKey: alias) else { return false }
        try write(hosts, "known-hosts.json")
        if !hosts.values.contains(where: { $0.hostID == gone.hostID }) { removeHostIcon(hostID: gone.hostID) }
        return true
    }
    /// Changes a known host's record (what its latest Welcome said); nothing if the alias is not known.
    public func updateKnownHost(_ alias: String, _ change: (inout KnownHost) -> Void) throws {
        guard var hosts = try read([String: KnownHost].self, "known-hosts.json"), var h = hosts[alias] else { return }
        let before = h
        change(&h)
        guard h != before else { return }
        hosts[alias] = h
        try write(hosts, "known-hosts.json")
    }
}
