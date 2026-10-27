import Foundation

/// A host's metadata (DESIGN §3.10, U7; phrz, 2026-10-27: "the icon is host metadata and belongs to the status/metadata
/// protocol, not to connections"). One record, the authenticated Welcome. A status probe receives it (a control-only
/// connection: Hello with `Feature.probe`, mutual authentication, the Welcome, closed; no stream, no session), and a
/// session's connection receives the same one. The viewer keeps it through one path (`apply`), whichever brought it.
///
/// What it holds: the name, model and family, macOS version, build and the newest its feed check found, update policy,
/// channel and trigger, features (unlock, agent sessions, unpair), whether it streams to another device, its protocol
/// range, its settings (Curtain, Lock When Finished, Stay Reachable, Share This Mac), when Lock When Finished last failed,
/// the grants it lacks, whether it is shared, and its icon. The icon is fetched by hash: the viewer's Hello says the hash
/// of the copy it keeps (`Hello.hostIconHash`), and the record carries the icon only when the host's differs (at most 30
/// KB). Reachability is the viewer's own (a probe that got no answer), kept beside it.
///
/// Compatibility: on the wire this is the Welcome's flat fields, as before; an older host leaves fields out, and what it
/// does not say keeps what was known (model, family, macOS, channel) or reads as unknown.
public struct HostMetadata: Equatable, Sendable {
    public var name: String
    public var model: String?
    public var family: String?
    public var os: String?
    public var version: MirageVersion?
    public var latestAvailable: MirageVersion?
    public var permission: UpdatePermission?
    public var channel: UpdateChannel?
    public var features: [String]
    public var acceptsUpdateTrigger: Bool
    public var updating: ControlMessage.UpdateStatus?
    public var streaming: Bool?
    public var protocolVersion: Int?
    public var minProtocolVersion: Int?
    public var settings: HostSettings?
    public var lockFailedAt: Date?
    public var needsPermissions: [String]?
    public var shared: Bool?
    public var icon: HostIcon?

    public init(welcome w: ControlMessage.Welcome) {
        name = w.hostName
        model = w.hostModel
        family = w.hostFamily ?? DeviceModel.family(of: w.hostModel)?.rawValue
        os = w.hostOS
        version = w.hostVersion
        latestAvailable = w.latestAvailable
        permission = w.updatePolicy
        channel = w.updateChannel
        features = w.features ?? []
        acceptsUpdateTrigger = w.acceptsUpdateTrigger
        updating = w.updateResult.flatMap { $0.isFinal ? nil : $0 }
        streaming = w.hostStreaming
        protocolVersion = w.protocolVersion
        minProtocolVersion = w.minProtocolVersion
        settings = w.hostSettings
        lockFailedAt = w.lockFailedAt
        needsPermissions = w.needsPermissions
        shared = w.shared
        icon = w.hostIcon
    }

    /// The one cache path: the record onto what this viewer knows of the host, and its icon into the store. `seenAt`: when
    /// it answered (also clears unreachability and a refusal); `connected`: a session's, not a probe's.
    public func apply(to h: inout Store.KnownHost, seenAt now: Date, incompatibility: ControlMessage.Reject.Code?, connected: Bool) {
        if !name.isEmpty { h.hostName = name }
        if let model { h.model = model }
        if let family { h.family = family }
        if let os { h.hostOS = os }
        if let channel { h.hostChannel = channel }
        h.hostVersion = version
        h.latestAvailable = latestAvailable
        h.updateTrigger = acceptsUpdateTrigger
        h.updating = updating
        h.incompatibility = incompatibility?.rawValue
        h.lastSeen = now; h.unreachableSince = nil; h.failedProbes = nil; h.lastProbeFailure = nil; h.refusal = nil
        h.triggerFeature = features.contains(ControlMessage.Feature.updateTrigger)
        h.hostUnlock = features.contains(ControlMessage.Feature.unlock)
        h.hostPolicy = permission
        h.hostNeedsPermissions = needsPermissions
        h.hostShared = shared
        h.hostSettings = settings; h.hostLockFailedAt = lockFailedAt   // (nil from an older host: unknown)
        h.hostStreaming = streaming
        h.hostProtocol = protocolVersion; h.hostMinProtocol = minProtocolVersion
        if incompatibility == nil, connected { h.lastConnected = now }
    }

    /// Into the store: the icon by the host's id, the record by the alias.
    public func save(store: Store, alias: String, hostID: String, incompatibility: ControlMessage.Reject.Code?, connected: Bool, now: Date = Date()) {
        if let icon { try? store.saveHostIcon(icon, hostID: hostID) }
        try? store.updateKnownHost(alias) { h in apply(to: &h, seenAt: now, incompatibility: incompatibility, connected: connected) }
    }
}
