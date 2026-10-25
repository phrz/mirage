import Foundation
import MirageCore

/// Who may start an update (DESIGN §3.10, phrz 2026-10-25: any paired device by default).
public enum UpdateTrigger: String, Codable, CaseIterable, Sendable {
    /// Any paired device: pairing already grants full control of the Mac, so installing a signed newer build adds no power.
    case anyDevice = "any-device"
    /// Only on this Mac: its menu bar or SSH.
    case thisMac = "this-mac"
}

/// The host's update settings and memory: `updates.json` in Application Support/Mirage (the menu bar and
/// `miraged update --set` edit it).
public struct UpdateSettings: Codable, Equatable, Sendable {
    public var channel: UpdateChannel = .stable
    public var policy: UpdatePolicy = .ask
    public var trigger: UpdateTrigger = .anyDevice
    /// Manifest keys learned from a verified manifest's `nextKey` (base64), minus revoked ones.
    public var learnedKeys: [String] = []
    /// Builds that rolled back: not offered again until a newer one appears.
    public var skippedBuilds: [Int] = []
    /// The last feed check: when, the newest build it found on `channel` (verified), or why it failed.
    public var lastCheck: Date?
    public var latest: MirageVersion?
    public var lastCheckError: String?

    public init() {}

    enum CodingKeys: String, CodingKey { case channel, policy, trigger, learnedKeys, skippedBuilds, lastCheck, latest, lastCheckError }
    /// Every field optional, and a value this build does not know falls back to the default: a settings file from a newer
    /// build never stops an older one from updating.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func opt<T: Decodable>(_ t: T.Type, _ k: CodingKeys) -> T? { (try? c.decodeIfPresent(t, forKey: k)) ?? nil }
        channel = opt(UpdateChannel.self, .channel) ?? .stable
        policy = opt(UpdatePolicy.self, .policy) ?? .ask
        trigger = opt(UpdateTrigger.self, .trigger) ?? .anyDevice
        learnedKeys = opt([String].self, .learnedKeys) ?? []
        skippedBuilds = opt([Int].self, .skippedBuilds) ?? []
        lastCheck = opt(Date.self, .lastCheck)
        latest = opt(MirageVersion.self, .latest)
        lastCheckError = opt(String.self, .lastCheckError)
    }

    public var trust: ManifestTrust { ManifestTrust(learned: learnedKeys) }

    /// What the Welcome says (U1's update fields): the newest build found, and what a viewer may do.
    public var hostUpdateInfo: HostUpdateInfo {
        HostUpdateInfo(latestAvailable: latest, permission: UpdatePermission(policy: policy, viewerMayTrigger: trigger == .anyDevice))
    }

    /// `miraged update --set key=value`: channel=stable|beta|nightly, policy=ask|automatic, trigger=any-device|this-mac.
    public mutating func apply(_ assignment: String) throws {
        let parts = assignment.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { throw UpdateError.refused("--set takes key=value, not \(assignment)") }
        let (k, v) = (parts[0].lowercased(), parts[1].lowercased())
        func bad(_ allowed: [String]) -> UpdateError { .refused("\(k) is one of \(allowed.joined(separator: ", ")), not \(v)") }
        switch k {
        case "channel":
            guard let c = UpdateChannel(rawValue: v) else { throw bad(UpdateChannel.allCases.map(\.rawValue)) }
            // Switching channel changes which feed is read, never what runs: the newest found so far was another channel's.
            if c != channel { latest = nil; lastCheck = nil; lastCheckError = nil }
            channel = c
        case "policy":
            guard let p = UpdatePolicy(rawValue: v) else { throw bad(UpdatePolicy.allCases.map(\.rawValue)) }
            policy = p
        case "trigger":
            guard let t = UpdateTrigger(rawValue: v) else { throw bad(UpdateTrigger.allCases.map(\.rawValue)) }
            trigger = t
        default:
            throw UpdateError.refused("unknown setting \(k): channel, policy or trigger")
        }
    }

    // MARK: File

    public static func load(_ url: URL) -> UpdateSettings {
        guard let data = try? Data(contentsOf: url) else { return UpdateSettings() }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        var s = (try? d.decode(UpdateSettings.self, from: data)) ?? UpdateSettings()
        // A revoking build drops revoked keys from the learned set at start (the compromise procedure).
        s.learnedKeys = s.trust.prunedLearned()
        return s
    }

    public func save(_ url: URL) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(self).write(to: url, options: .atomic)
    }
}

/// Whether a manifest is an update for this host (DESIGN §3.10, verification step 1 and the channel rules).
public enum UpdateDecision: Equatable, Sendable {
    case available(from: MirageVersion, to: MirageVersion)
    case upToDate(MirageVersion)
    /// The channel's newest is older than what runs (the host moved to a slower channel): it stays until the channel
    /// publishes a greater build. Switching channel never downgrades.
    case channelBehind(running: MirageVersion, channelHead: MirageVersion, channel: UpdateChannel)
    /// It rolled back on this host before.
    case skipped(MirageVersion)
    /// It cannot run here: macOS too old, or it would drop the protocol this host's viewers speak.
    case incompatible(MirageVersion, String)

    public static func decide(running: MirageVersion, manifest: Manifest, channel: UpdateChannel, skipped: [Int],
                              os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                              runningProtocol: Int = Mirage.protocolVersion) -> UpdateDecision {
        let m = manifest.mirageVersion
        if m.build == running.build { return .upToDate(running) }
        if m.build < running.build { return .channelBehind(running: running, channelHead: m, channel: channel) }
        if skipped.contains(m.build) { return .skipped(m) }
        if let need = parseOS(manifest.minOS), !osAtLeast(os, need) {
            return .incompatible(m, "needs macOS \(manifest.minOS); this Mac has \(os.majorVersion).\(os.minorVersion)")
        }
        if manifest.minProtocol > runningProtocol {
            return .incompatible(m, "it drops protocol \(runningProtocol), which this host's viewers speak (it needs \(manifest.minProtocol)); update the viewers first")
        }
        return .available(from: running, to: m)
    }

    public var isAvailable: Bool { if case .available = self { return true }; return false }

    /// What `miraged update --check`, the menu bar and the viewer's host row say.
    public var message: String {
        switch self {
        case .available(let f, let t): return "Update available: \(f.display) → \(t.display) (\(t.channelName))"
        case .upToDate(let r): return "Up to date: \(r.display) (\(r.channelName))"
        case .channelBehind(let r, let h, let c):
            let name = c.rawValue.prefix(1).uppercased() + c.rawValue.dropFirst()
            return "\(name) catches up at build ≥ \(r.build + 1) (its newest is \(h.display)); staying on \(r.channelName) \(r.display) until then."
        case .skipped(let m): return "\(m.display) rolled back on this Mac: skipped until a newer build appears"
        case .incompatible(let m, let why): return "\(m.display) cannot be installed: \(why)"
        }
    }

    static func parseOS(_ s: String) -> OperatingSystemVersion? {
        let p = s.split(separator: ".").map { Int($0) }
        guard let major = p.first ?? nil else { return nil }
        return OperatingSystemVersion(majorVersion: major, minorVersion: p.count > 1 ? (p[1] ?? 0) : 0, patchVersion: p.count > 2 ? (p[2] ?? 0) : 0)
    }
    static func osAtLeast(_ a: OperatingSystemVersion, _ b: OperatingSystemVersion) -> Bool {
        (a.majorVersion, a.minorVersion, a.patchVersion) >= (b.majorVersion, b.minorVersion, b.patchVersion)
    }
}
