import Foundation

/// The release channel a build was published to, and the one a host follows (DESIGN §3.10).
public enum UpdateChannel: String, Codable, CaseIterable, Sendable {
    case nightly, beta, stable
}

/// What one build is (DESIGN §3.10 version identity): `version` is MARKETING_VERSION, `build` the monotonic commit count on
/// main that the release script stamps into CURRENT_PROJECT_VERSION, `commit` the short hash, `channel` the channel it was
/// published to (Info.plist `MirageChannel`; nil for a local build that was never published). Builds compare by `build`.
public struct MirageVersion: Codable, Equatable, Hashable, Sendable, Comparable {
    public var version: String
    public var build: Int
    public var commit: String
    public var channel: UpdateChannel?

    public init(version: String, build: Int, commit: String, channel: UpdateChannel?) {
        self.version = version; self.build = build; self.commit = commit; self.channel = channel
    }

    /// "0.4.0 (412)": what every indicator and prompt shows.
    public var display: String { "\(version) (\(build))" }
    /// "nightly", or "local" for a build that was never published.
    public var channelName: String { channel?.rawValue ?? "local" }

    public static func < (a: MirageVersion, b: MirageVersion) -> Bool { a.build < b.build }

    /// This process's build, from its bundle's Info.plist: the host inside Mirage.app (Bundle.main is the app for an
    /// executable in Contents/MacOS), the viewer app. A bare SwiftPM binary has no Info.plist: build 0, "unknown".
    public static let current: MirageVersion = from(infoDictionary: Bundle.main.infoDictionary ?? [:])

    /// A bundle's version from its Info.plist keys (also used on a staged bundle before it is installed).
    public static func from(infoDictionary info: [String: Any]) -> MirageVersion {
        let version = (info["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "0"
        let build = (info["CFBundleVersion"] as? String).flatMap { Int($0) } ?? (info["CFBundleVersion"] as? Int) ?? 0
        let commit = (info["MirageCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        let channel = (info["MirageChannel"] as? String).flatMap(UpdateChannel.init(rawValue:))
        return MirageVersion(version: version, build: build, commit: commit, channel: channel)
    }

    // A channel this build does not know (a later one) decodes as nil instead of failing the whole message.
    enum CodingKeys: String, CodingKey { case version, build, commit, channel }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        build = try c.decode(Int.self, forKey: .build)
        commit = try c.decodeIfPresent(String.self, forKey: .commit) ?? "unknown"
        channel = (try? c.decodeIfPresent(String.self, forKey: .channel)).flatMap { $0.flatMap(UpdateChannel.init(rawValue:)) }
    }
}

/// The phases an update reports (DESIGN §3.10): `miraged update` prints them; the host sends them to the viewer that
/// triggered it (`ControlMessage.updateStatus`) and to the Mirage app on the host Mac (local control).
public enum UpdatePhase: String, Codable, Sendable {
    case checking, downloading, verifying, installing, restarting, done, failed, rolledBack
}

/// What a trigger asks the host for.
public enum UpdateCommand: Equatable, Sendable {
    /// Install the feed's newest; `targetBuild` (from a viewer) must be the build the feed lists now.
    case update(targetBuild: Int?)
    case rollback
}

/// Whether a host takes an update trigger from a paired viewer (DESIGN §3.10, phrz 2026-10-25: any paired device, unless
/// the host restricts updates to "this Mac only"). Both policies (Ask, Automatic) take triggers: Automatic only adds
/// installing on its own at night.
public enum UpdateGate {
    /// nil: allowed; else why not, for the viewer.
    public static func refusal(permission: UpdatePermission?, canUpdate: Bool, hostName: String) -> String? {
        guard canUpdate, let p = permission else { return "\(hostName) cannot update itself from a viewer (an older or a development host): run `miraged update --now` on it" }
        guard p.viewerMayTrigger else { return "updates on \(hostName) are restricted to that Mac (its menu bar, or `miraged update --now` over SSH)" }
        return nil
    }
}

/// How a host installs updates (DESIGN §3.10, phrz 2026-10-25: only two).
public enum UpdatePolicy: String, Codable, CaseIterable, Sendable {
    /// The default: shows the indicator; installs only when someone triggers it.
    case ask
    /// Installs on its own when no stream has been open for 30 min, between 02:00 and 05:00 local time.
    case automatic
}

/// What the host tells a viewer in its Welcome about updates: the policy, and whether this viewer may trigger one.
public struct UpdatePermission: Codable, Equatable, Sendable {
    public var policy: UpdatePolicy
    /// False when the host restricts updates to "this Mac only" (menu bar or SSH).
    public var viewerMayTrigger: Bool
    public init(policy: UpdatePolicy, viewerMayTrigger: Bool) { self.policy = policy; self.viewerMayTrigger = viewerMayTrigger }
}

/// Protocol compatibility (DESIGN §3.10): the host accepts any viewer whose protocol is within
/// `Mirage.minProtocolVersion ... Mirage.protocolVersion` or newer than it (a newer viewer speaks down, and gates its newer
/// features on the host's version), unless that viewer itself needs more than this host speaks.
public enum ProtocolCompat {
    /// The host's decision on a viewer's Hello: nil = accept, else which side must be updated.
    public static func check(viewerProtocol: Int, viewerMinProtocol: Int?,
                             hostRange: ClosedRange<Int> = Mirage.minProtocolVersion...Mirage.protocolVersion) -> ControlMessage.Reject.Code? {
        if viewerProtocol < hostRange.lowerBound { return .viewerTooOld }
        if let m = viewerMinProtocol, m > hostRange.upperBound { return .hostTooOld }
        return nil
    }

    /// The version both sides speak on an accepted connection.
    public static func negotiated(viewerProtocol: Int, hostProtocol: Int) -> Int { min(viewerProtocol, hostProtocol) }

    /// The viewer's decision on a Welcome: a host that speaks less than this viewer needs is too old. `hostProtocol` nil:
    /// a host from before protocol ranges, which accepted only our exact version.
    public static func viewerCheck(hostProtocol: Int?, viewerRange: ClosedRange<Int> = Mirage.minProtocolVersion...Mirage.protocolVersion) -> ControlMessage.Reject.Code? {
        guard let h = hostProtocol else { return nil }
        return h < viewerRange.lowerBound ? .hostTooOld : nil
    }

    /// A reject without a code is from a host older than protocol ranges: its only version reject was an exact mismatch,
    /// and this viewer is newer than that host (it knows codes), so the host is the side to update.
    public static func legacyCode(reason: String) -> ControlMessage.Reject.Code? {
        reason.hasPrefix("protocol version") ? .hostTooOld : nil
    }
}

/// A paired host's update state as a device list shows it (DESIGN §3.10, the update indicator).
public enum HostUpdateState: Equatable, Sendable {
    case current
    /// The host's feed lists a newer build than it runs: the yellow arrow.
    case updateAvailable(from: MirageVersion, to: MirageVersion)
    /// The host refused this viewer, or the reverse: which side to update, in place of the arrow.
    case hostTooOld
    case viewerTooOld

    public static func evaluate(hostVersion: MirageVersion?, latestAvailable: MirageVersion?, incompatibility: ControlMessage.Reject.Code?) -> HostUpdateState {
        switch incompatibility {
        case .hostTooOld: return .hostTooOld
        case .viewerTooOld: return .viewerTooOld
        case nil: break
        }
        if let h = hostVersion, let l = latestAvailable, l.build > h.build { return .updateAvailable(from: h, to: l) }
        return .current
    }

    /// The row's line for it ("Update Mirage on mac-daddy to connect"); nil when there is nothing to say in words.
    public func note(hostName: String) -> String? {
        switch self {
        case .current: return nil
        case .updateAvailable(let from, let to): return "Update available: \(from.display) → \(to.display)"
        case .hostTooOld: return "Mirage on \(hostName) is too old for this device: update \(hostName)"
        case .viewerTooOld: return "This Mirage is too old for \(hostName): update this device"
        }
    }
}
