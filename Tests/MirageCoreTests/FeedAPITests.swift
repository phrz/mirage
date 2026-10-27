import XCTest
import CryptoKit
@testable import MirageCore

/// The feed read fresh (phrz, 2026-10-27: the download URL served the previous manifest for minutes after a publish): the
/// GitHub API first, conditional on its ETag, the download URL as the fallback, and trust from the signature either way.
final class FeedAPITests: XCTestCase {
    static let key = Curve25519.Signing.PrivateKey()
    static var trust: ManifestTrust { ManifestTrust(compiled: [key.publicKey.rawRepresentation.base64EncodedString()], learned: [], revoked: []) }

    static func manifest(_ build: Int, expires: Date = Date().addingTimeInterval(86_400), key: Curve25519.Signing.PrivateKey = key) throws -> (Data, Data) {
        let m = Manifest(channel: .nightly, version: "0.1", build: build, commit: "c\(build)", minProtocol: 5, protocolVersion: 6, minOS: "15.0",
                         zipURL: "https://example.invalid/\(build).zip", zipSHA256: String(repeating: "0", count: 64), zipSize: 1, notes: "",
                         published: Date(), expires: expires)
        let d = try m.encoded()
        return (d, try ManifestKey.sign(d, with: [key]))
    }

    /// A fake GitHub: the API's release and assets, and the download URL (possibly stale), counting requests.
    final class FakeGitHub: @unchecked Sendable {
        let lock = NSLock()
        var api: (Data, Data)
        var cdn: (Data, Data)
        var apiDown = false
        var rateLimited = false
        var etag = "\"v1\""
        var log: [String] = []
        init(api: (Data, Data), cdn: (Data, Data)) { self.api = api; self.cdn = cdn }

        func respond(_ r: URLRequest) -> (Data, HTTPURLResponse) {
            lock.lock(); defer { lock.unlock() }
            let u = r.url!.absoluteString
            log.append(u)
            func resp(_ code: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse { HTTPURLResponse(url: r.url!, statusCode: code, httpVersion: nil, headerFields: headers)! }
            if u.hasPrefix("https://api.github.com") {
                if rateLimited { return (Data(), resp(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(Int(Date().timeIntervalSince1970) + 600)"])) }
                if apiDown { return (Data(), resp(500)) }
                if u.hasSuffix("/assets/1") { return (api.0, resp(200)) }
                if u.hasSuffix("/assets/2") { return (api.1, resp(200)) }
                if r.value(forHTTPHeaderField: "If-None-Match") == etag { return (Data(), resp(304, ["ETag": etag])) }
                let body = #"{"assets":[{"id":1,"name":"manifest.json","url":"https://api.github.com/repos/phrz/mirage/releases/assets/1"},{"id":2,"name":"manifest.sigs.json","url":"https://api.github.com/repos/phrz/mirage/releases/assets/2"}]}"#
                return (Data(body.utf8), resp(200, ["ETag": etag]))
            }
            return (u.hasSuffix("manifest.sigs.json") ? cdn.1 : cdn.0, resp(200))
        }
        var transport: Feed.Transport { { r in self.respond(r) } }
        var count: Int { lock.lock(); defer { lock.unlock() }; return log.count }
    }

    /// The green-machine case: the CDN still serves 479, the API has 483: the check sees 483.
    func testTheAPIIsFresherThanTheDownloadURL() async throws {
        let gh = FakeGitHub(api: try Self.manifest(483), cdn: try Self.manifest(479))
        let feed = Feed(base: Feed.github, transport: gh.transport, api: ReleaseAPI())
        let (v, _) = try await feed.check(.nightly, trust: Self.trust)
        XCTAssertEqual(v.manifest.build, 483)
        XCTAssertFalse(gh.log.contains { $0.hasPrefix("https://github.com") }, "no download URL needed")
    }

    /// An unchanged release (304 on its ETag) reuses the assets read before: one request, no rate limit spent.
    func testAnUnchangedHeadCostsOneConditionalRequest() async throws {
        let gh = FakeGitHub(api: try Self.manifest(483), cdn: try Self.manifest(483))
        let api = ReleaseAPI()
        let feed = Feed(base: Feed.github, transport: gh.transport, api: api)
        _ = try await feed.check(.nightly, trust: Self.trust)
        XCTAssertEqual(gh.count, 3, "the release and its two assets")
        let (v, _) = try await feed.check(.nightly, trust: Self.trust)
        XCTAssertEqual(v.manifest.build, 483)
        XCTAssertEqual(gh.count, 4, "only the conditional release request")
    }

    /// Rate limited, or the API down: the download URL, as before; rate limited pauses the API until GitHub's reset.
    func testFallsBackToTheDownloadURL() async throws {
        let gh = FakeGitHub(api: try Self.manifest(483), cdn: try Self.manifest(481))
        gh.rateLimited = true
        let api = ReleaseAPI()
        let feed = Feed(base: Feed.github, transport: gh.transport, api: api)
        let (v, _) = try await feed.check(.nightly, trust: Self.trust)
        XCTAssertEqual(v.manifest.build, 481)
        let paused = await api.pausedUntil
        XCTAssertGreaterThan(paused ?? .distantPast, Date().addingTimeInterval(600))
        gh.rateLimited = false
        let before = gh.count
        _ = try await feed.check(.nightly, trust: Self.trust)
        XCTAssertFalse(gh.log[before...].contains { $0.hasPrefix("https://api.github.com") }, "no API calls while paused")
        let gh2 = FakeGitHub(api: try Self.manifest(483), cdn: try Self.manifest(481))
        gh2.apiDown = true
        let (v2, _) = try await Feed(base: Feed.github, transport: gh2.transport, api: ReleaseAPI()).check(.nightly, trust: Self.trust)
        XCTAssertEqual(v2.manifest.build, 481)
    }

    /// The source never makes a manifest trusted: a forged one through the API is passed over for the signed download.
    func testAForgedAPIHeadIsNotTrusted() async throws {
        let forged = try Self.manifest(999, key: Curve25519.Signing.PrivateKey())
        let gh = FakeGitHub(api: forged, cdn: try Self.manifest(483))
        let (v, _) = try await Feed(base: Feed.github, transport: gh.transport, api: ReleaseAPI()).check(.nightly, trust: Self.trust)
        XCTAssertEqual(v.manifest.build, 483)
        let gh2 = FakeGitHub(api: forged, cdn: forged)
        do {
            _ = try await Feed(base: Feed.github, transport: gh2.transport, api: ReleaseAPI()).check(.nightly, trust: Self.trust)
            XCTFail("unsigned by a trusted key")
        } catch { XCTAssertTrue(error is ManifestError, "\(error)") }
    }

    /// A local or test feed never calls GitHub.
    func testALocalFeedHasNoAPI() {
        XCTAssertNil(Feed(base: URL(fileURLWithPath: "/tmp/feed", isDirectory: true)).api)
        XCTAssertNotNil(Feed().api)
        XCTAssertNotNil(Feed(override: nil).api)
    }
}
