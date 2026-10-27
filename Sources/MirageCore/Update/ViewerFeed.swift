import Foundation

/// The viewers' own feed check (phrz, 2026-10-27: an update badge waited for each host's hourly check). A viewer reads
/// each channel its paired hosts follow, verifies it exactly as a host does (signature by a trusted key, channel, expiry),
/// and keeps the signed bytes; every use verifies them again, so an expired manifest stops counting by itself.
///
/// What a host's row offers is the newer of what the host reported and what the viewer verified, and the viewer's only
/// when it applies to that host: same channel, the host takes triggers from this device, its macOS meets the build's
/// minOS (unknown: not offered), and the build still speaks the host's protocol.
public enum ViewerFeed {
    /// One channel head as read: the manifest and its signatures, byte for byte, and when.
    public struct Entry: Codable, Equatable, Sendable {
        public var manifest: Data
        public var signatures: Data
        public var checked: Date
        public init(manifest: Data, signatures: Data, checked: Date) { self.manifest = manifest; self.signatures = signatures; self.checked = checked }
    }

    /// The verified manifests by channel; anything unsigned, expired or for another channel is left out.
    public static func verified(_ entries: [UpdateChannel: Entry], trust: ManifestTrust = ManifestTrust(), now: Date = Date()) -> [UpdateChannel: Manifest] {
        var out: [UpdateChannel: Manifest] = [:]
        for (ch, e) in entries {
            if let v = try? ManifestVerifier.verify(manifest: e.manifest, signatures: e.signatures, trust: trust, channel: ch, now: now) { out[ch] = v.manifest }
        }
        return out
    }

    /// The build a host's row offers: the newer of the host's report and the viewer's verified feed, when it applies.
    public static func latest(for h: Store.KnownHost, feed: [UpdateChannel: Manifest]) -> MirageVersion? {
        let reported = h.latestAvailable
        guard let running = h.hostVersion, let ch = running.channel, let m = feed[ch], h.updateTrigger == true,
              let os = h.hostOS.flatMap(parseOS), let need = parseOS(m.minOS), atLeast(os, need),
              m.minProtocol <= (h.hostProtocol ?? Mirage.protocolVersion),
              m.build > running.build else { return reported }
        let mine = m.mirageVersion
        return (reported?.build ?? 0) >= mine.build ? reported : mine
    }

    /// The record with `latestAvailable` as the row offers it.
    public static func applying(_ feed: [UpdateChannel: Manifest], to h: Store.KnownHost) -> Store.KnownHost {
        var h = h
        h.latestAvailable = latest(for: h, feed: feed)
        return h
    }

    public static func osString(_ v: OperatingSystemVersion) -> String { "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "") }
    static func parseOS(_ s: String) -> [Int]? {
        let p = s.split(separator: ".").compactMap { Int($0) }
        return p.isEmpty ? nil : p
    }
    static func atLeast(_ a: [Int], _ b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }
}

extension Store {
    private static let viewerFeedFile = "viewer-feed.json"
    /// The channel heads this viewer read, as read (verified again at each use).
    public func viewerFeed() -> [UpdateChannel: ViewerFeed.Entry] {
        ((try? read([String: ViewerFeed.Entry].self, Self.viewerFeedFile)) ?? nil)?
            .reduce(into: [:]) { out, kv in if let c = UpdateChannel(rawValue: kv.key) { out[c] = kv.value } } ?? [:]
    }
    public func saveViewerFeed(_ entry: ViewerFeed.Entry, channel: UpdateChannel) throws {
        var all = ((try? read([String: ViewerFeed.Entry].self, Self.viewerFeedFile)) ?? nil) ?? [:]
        all[channel.rawValue] = entry
        try write(all, Self.viewerFeedFile)
    }
}
