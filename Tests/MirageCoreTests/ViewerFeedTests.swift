import XCTest
import CryptoKit
@testable import MirageCore

/// The viewers' own feed check (phrz, 2026-10-27): only a signed, unexpired head for the right channel counts, and a row
/// offers the newer of the host's report and the viewer's feed only where it applies to that host.
final class ViewerFeedTests: XCTestCase {
    let trust = FeedAPITests.trust

    func entry(_ build: Int, expires: Date = Date().addingTimeInterval(86_400), key: Curve25519.Signing.PrivateKey = FeedAPITests.key) throws -> ViewerFeed.Entry {
        let (m, s) = try FeedAPITests.manifest(build, expires: expires, key: key)
        return .init(manifest: m, signatures: s, checked: Date())
    }

    func testOnlySignedUnexpiredHeadsCount() throws {
        XCTAssertEqual(ViewerFeed.verified([.nightly: try entry(483)], trust: trust)[.nightly]?.build, 483)
        XCTAssertNil(ViewerFeed.verified([.nightly: try entry(483, key: Curve25519.Signing.PrivateKey())], trust: trust)[.nightly], "not signed by a trusted key")
        XCTAssertNil(ViewerFeed.verified([.nightly: try entry(483, expires: Date().addingTimeInterval(-60))], trust: trust)[.nightly], "expired")
        var tampered = try entry(483)
        tampered.manifest = Data(String(decoding: tampered.manifest, as: UTF8.self).replacingOccurrences(of: "483", with: "999").utf8)
        XCTAssertNil(ViewerFeed.verified([.nightly: tampered], trust: trust)[.nightly], "changed after signing")
        XCTAssertNil(ViewerFeed.verified([.beta: try entry(483)], trust: trust)[.beta], "a nightly head is not beta's")
        // Kept as read, verified again at use: it stops counting once it expires.
        let soon = try entry(483, expires: Date().addingTimeInterval(60))
        XCTAssertNotNil(ViewerFeed.verified([.nightly: soon], trust: trust, now: Date())[.nightly])
        XCTAssertNil(ViewerFeed.verified([.nightly: soon], trust: trust, now: Date().addingTimeInterval(120))[.nightly])
    }

    func host(running: Int = 475, reported: Int? = 479, trigger: Bool = true, os: String? = "26.1", channel: UpdateChannel = .nightly) -> Store.KnownHost {
        var h = Store.KnownHost(hostID: "g", hostName: "green-machine", publicKey: Data(), endpoint: "g", pairedAt: Date())
        h.hostVersion = MirageVersion(version: "0.1", build: running, commit: "a", channel: channel)
        h.latestAvailable = reported.map { MirageVersion(version: "0.1", build: $0, commit: "b", channel: channel) }
        h.updateTrigger = trigger; h.hostOS = os; h.hostProtocol = 6
        return h
    }

    func testTheRowOffersTheNewerOfTheTwo() throws {
        let feed = ViewerFeed.verified([.nightly: try entry(483)], trust: trust)
        XCTAssertEqual(ViewerFeed.latest(for: host(), feed: feed)?.build, 483, "the host said 479, the feed has 483")
        XCTAssertEqual(ViewerFeed.latest(for: host(reported: 490), feed: feed)?.build, 490, "the host knows a newer one")
        XCTAssertEqual(ViewerFeed.latest(for: host(reported: nil), feed: feed)?.build, 483, "the host has not checked yet")
        XCTAssertEqual(ViewerFeed.latest(for: host(trigger: false), feed: feed)?.build, 479, "no triggers from this device: the host's own word")
        XCTAssertEqual(ViewerFeed.latest(for: host(channel: .beta), feed: feed)?.build, 479, "another channel")
        XCTAssertEqual(ViewerFeed.latest(for: host(os: "14.6"), feed: feed)?.build, 479, "its macOS is older than the build's minOS (15.0)")
        XCTAssertEqual(ViewerFeed.latest(for: host(os: nil), feed: feed)?.build, 479, "an older host does not say its macOS: not offered")
        XCTAssertNil(ViewerFeed.latest(for: host(running: 483, reported: nil), feed: feed), "it runs that build already")
        XCTAssertEqual(ViewerFeed.applying(feed, to: host()).updateState(now: Date()),
                       .updateAvailable(from: host().hostVersion!, to: ViewerFeed.verified([.nightly: try entry(483)], trust: trust)[.nightly]!.mirageVersion))
    }

    func testTheCacheRoundTrips() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-viewerfeed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try Store(root: tmp)
        XCTAssertTrue(store.viewerFeed().isEmpty)
        let e = try entry(483)
        try store.saveViewerFeed(e, channel: .nightly)
        XCTAssertEqual(store.viewerFeed()[.nightly]?.manifest, e.manifest)
        XCTAssertEqual(store.viewerFeed()[.nightly]?.signatures, e.signatures, "kept byte for byte")
        XCTAssertEqual(ViewerFeed.osString(OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)), "26.1")
    }
}
