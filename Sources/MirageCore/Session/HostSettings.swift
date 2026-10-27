import Foundation

/// The host's own settings (DESIGN §3.12), beside the update policy: `host-settings.json` in the host's store, changed from
/// the Mirage menu (over the local control socket) or by hand. Every field optional on reading; a missing or unknown one is
/// its default, so a file from another build never breaks the host.
public struct HostSettings: Codable, Equatable, Sendable {
    /// While a session streams, the host's screens show the curtain (and local input locks the Mac). Default on.
    public var curtain = true
    /// When the last session ends, lock the Mac (unless a person at it signed in during the session). Default on.
    public var lockWhenFinished = true
    /// Keep the Mac from idle system sleep so viewers can connect (on the power adapter, on a Mac with a battery); the display
    /// still sleeps. Default on. Applies at once.
    public var stayReachable = true
    /// Share This Mac (phrz, 2026-10-27): other devices can connect to it. Off (a viewer-only Mac: install-host.sh
    /// --viewer-only, or the switch), the host agent stays registered but only keeps Mirage up to date: no streams, no
    /// pairing, no capture, no curtain, no permission requests or window. Default on.
    public var shareThisMac = true
    /// The person chose Later in the permissions window: it comes back only when someone tries to share this Mac (a
    /// pairing to it, Share This Mac turned on, a connection refused for a missing grant) or a grant is revoked.
    public var permissionsSnoozed = false
    public init(curtain: Bool = true, lockWhenFinished: Bool = true, stayReachable: Bool = true, shareThisMac: Bool = true, permissionsSnoozed: Bool = false) {
        self.curtain = curtain; self.lockWhenFinished = lockWhenFinished; self.stayReachable = stayReachable
        self.shareThisMac = shareThisMac; self.permissionsSnoozed = permissionsSnoozed
    }

    enum CodingKeys: String, CodingKey { case curtain, lockWhenFinished, stayReachable, shareThisMac, permissionsSnoozed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        curtain = ((try? c.decodeIfPresent(Bool.self, forKey: .curtain)) ?? nil) ?? true
        lockWhenFinished = ((try? c.decodeIfPresent(Bool.self, forKey: .lockWhenFinished)) ?? nil) ?? true
        stayReachable = ((try? c.decodeIfPresent(Bool.self, forKey: .stayReachable)) ?? nil) ?? true
        shareThisMac = ((try? c.decodeIfPresent(Bool.self, forKey: .shareThisMac)) ?? nil) ?? true
        permissionsSnoozed = ((try? c.decodeIfPresent(Bool.self, forKey: .permissionsSnoozed)) ?? nil) ?? false
    }

    public static let fileName = "host-settings.json"

    /// A message's settings over the stored ones: keys the message leaves out (an older Mirage.app knows no
    /// shareThisMac or permissionsSnoozed) keep their stored values, instead of the defaults turning sharing back on.
    public static func merged(message: Data, over stored: HostSettings) -> HostSettings {
        guard let keys = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any],
              let sent = try? JSONDecoder().decode(HostSettings.self, from: message) else { return stored }
        var out = stored
        if keys["curtain"] != nil { out.curtain = sent.curtain }
        if keys["lockWhenFinished"] != nil { out.lockWhenFinished = sent.lockWhenFinished }
        if keys["stayReachable"] != nil { out.stayReachable = sent.stayReachable }
        if keys["shareThisMac"] != nil { out.shareThisMac = sent.shareThisMac }
        if keys["permissionsSnoozed"] != nil { out.permissionsSnoozed = sent.permissionsSnoozed }
        return out
    }
    public static func load(from url: URL) -> HostSettings {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(HostSettings.self, from: d) else { return HostSettings() }
        return s
    }
    public func save(to url: URL) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// When "Lock when finished" last failed to lock the Mac (⌃⌘Q and display sleep both left it unlocked), for the host menu
/// and the viewer's Get Info; nil once a later end lock lands. In memory: a restart forgets it.
public enum HostLockStatus {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var failed: Date?
    public static var lastFailure: Date? {
        get { lock.lock(); defer { lock.unlock() }; return failed }
        set { lock.lock(); failed = newValue; lock.unlock() }
    }
}

/// When the permissions window comes up (DESIGN §3.7a; phrz, 2026-10-27). Never while this Mac is not shared, never with
/// nothing missing. At the host's start (or the app's launch) only until the person chose Later; after that only when
/// someone tries to share this Mac, or a grant that was there is revoked.
public enum PermissionWindowRule {
    public enum Reason: Equatable, Sendable {
        case startup
        case revoked
        /// A device asked to pair (its name, when it said).
        case pairing(device: String?)
        case shareTurnedOn
        /// A device's connection was refused for a missing grant.
        case connectionRefused(device: String)
    }

    public static func shouldShow(_ r: Reason, settings: HostSettings, missing: [String]) -> Bool {
        guard settings.shareThisMac, !missing.isEmpty else { return false }
        if r == .startup { return !settings.permissionsSnoozed }
        return true
    }

    /// The window's line about why it is up now, when someone caused it.
    public static func message(_ r: Reason) -> String? {
        switch r {
        case .startup, .shareTurnedOn: return nil
        case .revoked: return "A permission Mirage had was turned off."
        case .pairing(let d): return "\(d ?? "A device") is pairing with this Mac. It can connect once these are allowed."
        case .connectionRefused(let d): return "\(d) tried to connect. It can once these are allowed."
        }
    }
}
