import Foundation
import MirageCore

/// The update feed (DESIGN §3.10): GitHub Releases on the public phrz/mirage. Each channel's head is a small rolling release
/// (`channel-stable`, `channel-beta`, `channel-nightly`) whose only assets are the current manifest and its signatures, so
/// a check is one unauthenticated GET with no API rate limit.
public struct Feed: Sendable {
    /// Where the channel heads live: `<base>/channel-<name>/manifest.json`.
    public var base: URL
    public static let github = URL(string: "https://github.com/phrz/mirage/releases/download/")!

    public init(base: URL = Feed.github) { self.base = base }

    /// A feed from `--feed` or `MIRAGE_UPDATE_FEED` (a local directory or another server, for tests). Any feed is as safe as
    /// the real one: what it serves must still be signed by a trusted key.
    public init(override: String?) {
        if let o = override, !o.isEmpty {
            base = o.hasPrefix("/") ? URL(fileURLWithPath: o, isDirectory: true) : (URL(string: o) ?? Feed.github)
        } else { base = Feed.github }
    }

    public func manifestURL(_ channel: UpdateChannel) -> URL {
        base.appendingPathComponent("channel-\(channel.rawValue)", isDirectory: true).appendingPathComponent("manifest.json")
    }
    public func signaturesURL(_ channel: UpdateChannel) -> URL {
        base.appendingPathComponent("channel-\(channel.rawValue)", isDirectory: true).appendingPathComponent("manifest.sigs.json")
    }

    /// The channel head, verified.
    public func check(_ channel: UpdateChannel, trust: ManifestTrust, now: Date = Date()) async throws -> (VerifiedManifest, URL) {
        let mu = manifestURL(channel)
        async let m = Feed.fetch(mu)
        async let s = Feed.fetch(signaturesURL(channel))
        return (try ManifestVerifier.verify(manifest: try await m, signatures: try await s, trust: trust, channel: channel, now: now), mu)
    }

    /// A small file over HTTPS (or file:// for a local feed). No cache: a check must see the current head.
    public static func fetch(_ url: URL, limit: Int = 1 << 20) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        req.setValue("Mirage-Updater", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw UpdateError.feed("\(url.lastPathComponent): HTTP \(h.statusCode)") }
        guard data.count <= limit else { throw UpdateError.feed("\(url.lastPathComponent) is larger than \(limit) bytes") }
        return data
    }
}

/// Every way an update stops, in words a person at the terminal or in a viewer can act on.
public enum UpdateError: Error, CustomStringConvertible, Equatable {
    case feed(String)
    case manifest(ManifestError)
    case refused(String)
    case download(String)
    case verification(String)
    case install(String)
    case busy
    /// Not now (the Automatic policy's quiet moment ended): nothing was replaced; try again later.
    case deferred(String)

    /// A failure that says nothing about the build (the network, another update running, a moment that was not quiet):
    /// it does not use up the build's one automatic try.
    public var isTransient: Bool {
        switch self {
        case .feed, .download, .busy, .deferred: return true
        case .manifest, .refused, .verification, .install: return false
        }
    }

    public var description: String {
        switch self {
        case .feed(let s): return "feed: \(s)"
        case .manifest(let e): return "manifest: \(e)"
        case .refused(let s): return s
        case .download(let s): return "download: \(s)"
        case .verification(let s): return "verification failed: \(s)"
        case .install(let s): return "install: \(s)"
        case .busy: return "another update is in progress"
        case .deferred(let s): return "deferred: \(s)"
        }
    }
}
