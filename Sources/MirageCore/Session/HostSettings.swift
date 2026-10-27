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
    public init(curtain: Bool = true, lockWhenFinished: Bool = true, stayReachable: Bool = true) {
        self.curtain = curtain; self.lockWhenFinished = lockWhenFinished; self.stayReachable = stayReachable
    }

    enum CodingKeys: String, CodingKey { case curtain, lockWhenFinished, stayReachable }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        curtain = ((try? c.decodeIfPresent(Bool.self, forKey: .curtain)) ?? nil) ?? true
        lockWhenFinished = ((try? c.decodeIfPresent(Bool.self, forKey: .lockWhenFinished)) ?? nil) ?? true
        stayReachable = ((try? c.decodeIfPresent(Bool.self, forKey: .stayReachable)) ?? nil) ?? true
    }

    public static let fileName = "host-settings.json"
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
