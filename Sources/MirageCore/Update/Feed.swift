import Foundation

/// The update feed (DESIGN §3.10): GitHub Releases on the public phrz/mirage. Each channel's head is a small rolling release
/// (`channel-stable`, `channel-beta`, `channel-nightly`) whose only assets are the current manifest and its signatures.
///
/// Read fresh (phrz, 2026-10-27: the download URL served the previous manifest for minutes after a publish, from GitHub's
/// CDN): on the real feed the release's assets come through the GitHub API (`ReleaseAPI`), conditional on the release's
/// ETag so an unchanged head costs no rate limit; the download URL is the fallback. Hosts and viewers share this code
/// (MirageCore). The source does not matter to trust: what is read must be signed by a trusted key.
public struct Feed: Sendable {
    /// Where the channel heads live: `<base>/channel-<name>/manifest.json`.
    public var base: URL
    public static let github = URL(string: "https://github.com/phrz/mirage/releases/download/")!
    /// One HTTP exchange (tests: a stand-in).
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public var transport: Transport
    /// The API reader for the real feed (nil: a local or test feed, read at `base` only).
    public var api: ReleaseAPI?

    public init(base: URL = Feed.github, transport: @escaping Transport = Feed.urlSession, api: ReleaseAPI? = nil) {
        self.base = base; self.transport = transport
        self.api = api ?? (base == Feed.github ? ReleaseAPI.shared : nil)
    }

    public static let urlSession: Transport = { req in
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let h = resp as? HTTPURLResponse else { throw UpdateError.feed("\(req.url?.lastPathComponent ?? "?"): not HTTP") }
        return (data, h)
    }

    /// A feed from `--feed` or `MIRAGE_UPDATE_FEED` (a local directory or another server, for tests). Any feed is as safe as
    /// the real one: what it serves must still be signed by a trusted key.
    public init(override: String?) {
        if let o = override, !o.isEmpty {
            base = o.hasPrefix("/") ? URL(fileURLWithPath: o, isDirectory: true) : (URL(string: o) ?? Feed.github)
        } else { base = Feed.github }
        transport = Feed.urlSession
        api = base == Feed.github ? ReleaseAPI.shared : nil
    }

    public func manifestURL(_ channel: UpdateChannel) -> URL {
        base.appendingPathComponent("channel-\(channel.rawValue)", isDirectory: true).appendingPathComponent("manifest.json")
    }
    public func signaturesURL(_ channel: UpdateChannel) -> URL {
        base.appendingPathComponent("channel-\(channel.rawValue)", isDirectory: true).appendingPathComponent("manifest.sigs.json")
    }

    /// The channel head, verified: through the API first (fresh), else the download URL. A head from the API that does not
    /// verify is not trusted either: the download URL is tried before giving up.
    public func check(_ channel: UpdateChannel, trust: ManifestTrust, now: Date = Date()) async throws -> (VerifiedManifest, URL) {
        let (v, url, _, _) = try await checkWithBytes(channel, trust: trust, now: now)
        return (v, url)
    }

    /// `check`, with the bytes that verified (a viewer keeps them and verifies them again at each use).
    public func checkWithBytes(_ channel: UpdateChannel, trust: ManifestTrust, now: Date = Date()) async throws -> (VerifiedManifest, URL, Data, Data) {
        let mu = manifestURL(channel)
        if let api, let files = try? await api.files(channel: channel, names: ["manifest.json", "manifest.sigs.json"], transport: transport),
           let m = files["manifest.json"], let sg = files["manifest.sigs.json"],
           let v = try? ManifestVerifier.verify(manifest: m, signatures: sg, trust: trust, channel: channel, now: now) {
            return (v, mu, m, sg)
        }
        async let m = Feed.fetch(mu, transport: transport)
        async let s = Feed.fetch(signaturesURL(channel), transport: transport)
        let (md, sd) = (try await m, try await s)
        return (try ManifestVerifier.verify(manifest: md, signatures: sd, trust: trust, channel: channel, now: now), mu, md, sd)
    }

    /// A small file over HTTPS (or file:// for a local feed). No cache: a check must see the current head.
    public static func fetch(_ url: URL, limit: Int = 1 << 20, transport: Transport = Feed.urlSession) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        req.setValue("Mirage-Updater", forHTTPHeaderField: "User-Agent")
        let (data, h) = try await transport(req)
        if h.statusCode != 200 { throw UpdateError.feed("\(url.lastPathComponent): HTTP \(h.statusCode)") }
        guard data.count <= limit else { throw UpdateError.feed("\(url.lastPathComponent) is larger than \(limit) bytes") }
        return data
    }
}

/// A channel head's assets through the GitHub API: `GET /repos/phrz/mirage/releases/tags/channel-<ch>`, then each asset's
/// API URL with `Accept: application/octet-stream`. Fresh where the download URL can lag behind a publish.
///
/// Unauthenticated API calls are limited to 60 an hour per IP address, shared by every Mac and viewer behind it, so: the
/// release is asked for with its last ETag (a 304 costs nothing and reuses the assets already read, which never change
/// under an asset id); a rate-limit answer stops API use until GitHub's reset time plus a jitter; any failure falls back to
/// the download URL, the path hosts used before.
public actor ReleaseAPI {
    public static let shared = ReleaseAPI()
    public static let base = URL(string: "https://api.github.com/repos/phrz/mirage/releases/tags/")!

    struct Asset: Decodable { var id: Int; var name: String; var url: String; var size: Int? }
    struct Release: Decodable { var assets: [Asset] }
    private var etags: [UpdateChannel: String] = [:]
    private var assets: [UpdateChannel: [Asset]] = [:]
    private var bytes: [Int: Data] = [:]
    /// No API calls before this (rate limited).
    public private(set) var pausedUntil: Date?
    /// API requests actually made (tests).
    public private(set) var requests = 0

    public init() {}

    public func files(channel: UpdateChannel, names: [String], transport: Feed.Transport, now: Date = Date()) async throws -> [String: Data] {
        if let p = pausedUntil, now < p { throw UpdateError.feed("GitHub API rate limit: paused until \(ISO8601DateFormatter().string(from: p))") }
        var req = Self.request(Self.base.appendingPathComponent("channel-\(channel.rawValue)"), accept: "application/vnd.github+json")
        if let e = etags[channel], assets[channel] != nil { req.setValue(e, forHTTPHeaderField: "If-None-Match") }
        requests += 1
        let (data, h) = try await transport(req)
        try checkLimit(h, now: now)
        switch h.statusCode {
        case 304: break
        case 200:
            assets[channel] = try JSONDecoder().decode(Release.self, from: data).assets
            etags[channel] = h.value(forHTTPHeaderField: "ETag")
        default: throw UpdateError.feed("GitHub API: HTTP \(h.statusCode)")
        }
        let listed = assets[channel] ?? []
        var out: [String: Data] = [:]
        for name in names {
            guard let a = listed.first(where: { $0.name == name }), let u = URL(string: a.url) else { throw UpdateError.feed("GitHub API: no \(name) on channel-\(channel.rawValue)") }
            if let b = bytes[a.id] { out[name] = b; continue }
            requests += 1
            let (d, ah) = try await transport(Self.request(u, accept: "application/octet-stream"))
            try checkLimit(ah, now: now)
            guard ah.statusCode == 200 else { throw UpdateError.feed("GitHub API: \(name): HTTP \(ah.statusCode)") }
            guard d.count <= 1 << 20 else { throw UpdateError.feed("\(name) is larger than 1 MB") }
            bytes[a.id] = d
            out[name] = d
        }
        // Only the assets still listed are kept.
        let live = Set(assets.values.flatMap { $0.map(\.id) })
        bytes = bytes.filter { live.contains($0.key) }
        return out
    }

    private func checkLimit(_ h: HTTPURLResponse, now: Date) throws {
        let remaining = h.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        guard h.statusCode == 403 || h.statusCode == 429 || remaining == 0 else { return }
        let reset = h.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            ?? now.addingTimeInterval(3600)
        pausedUntil = max(reset, now).addingTimeInterval(TimeInterval.random(in: 30...300))
        if h.statusCode == 403 || h.statusCode == 429 { throw UpdateError.feed("GitHub API rate limit") }
    }

    static func request(_ url: URL, accept: String) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        r.setValue("Mirage-Updater", forHTTPHeaderField: "User-Agent")
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return r
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
    /// A trigger asked for at least `build`, and the feed's newest is older: not published yet (or not yet visible here).
    case notPublished(build: Int, newest: Int, channel: UpdateChannel)

    /// A failure that says nothing about the build (the network, another update running, a moment that was not quiet):
    /// it does not use up the build's one automatic try.
    public var isTransient: Bool {
        switch self {
        case .feed, .download, .busy, .deferred, .notPublished: return true
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
        case .notPublished(let b, let n, let c): return "build \(b) is not published on \(c.rawValue) yet (its newest is \(n))"
        }
    }
}
