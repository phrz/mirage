import XCTest
import CryptoKit
import MirageCore
@testable import MirageUpdater

/// DESIGN §3.10: signed manifests and the key rotation scheme (current + next, nextKey, revokedKeys).
final class ManifestTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let current = Curve25519.Signing.PrivateKey()
    let next = Curve25519.Signing.PrivateKey()
    let stranger = Curve25519.Signing.PrivateKey()

    func b64(_ k: Curve25519.Signing.PrivateKey) -> String { k.publicKey.rawRepresentation.base64EncodedString() }
    func id(_ k: Curve25519.Signing.PrivateKey) -> String { ManifestKey.keyID(publicKey: k.publicKey.rawRepresentation) }

    func manifest(build: Int = 420, channel: UpdateChannel = .nightly, expiresIn: TimeInterval = 30 * 86_400, nextKey: String? = nil) -> Manifest {
        Manifest(channel: channel, version: "0.4.1", build: build, commit: "69bb8ba", minProtocol: 5, protocolVersion: 5, minOS: "15.0",
                 zipURL: "https://github.com/phrz/mirage/releases/download/nightly-\(build)/Mirage-0.4.1-\(build).zip",
                 zipSHA256: String(repeating: "ab", count: 32), zipSize: 1234, notes: "", published: now, expires: now.addingTimeInterval(expiresIn), nextKey: nextKey)
    }

    func signed(_ m: Manifest, by keys: [Curve25519.Signing.PrivateKey]) throws -> (Data, Data) {
        let d = try m.encoded()
        return (d, try ManifestKey.sign(d, with: keys))
    }

    var trust: ManifestTrust { ManifestTrust(compiled: [b64(current), b64(next)], learned: [], revoked: []) }

    func testKeyIDIsTheFirst8BytesOfTheKeysSHA256() {
        let pub = current.publicKey.rawRepresentation
        XCTAssertEqual(ManifestKey.keyID(publicKey: pub), SHA256.hash(data: pub).prefix(8).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(ManifestKey.keyID(publicKey: pub).count, 16)
    }

    func testAGoodManifestVerifies() throws {
        let (d, s) = try signed(manifest(), by: [current])
        let v = try ManifestVerifier.verify(manifest: d, signatures: s, trust: trust, channel: .nightly, now: now)
        XCTAssertEqual(v.manifest, manifest())
        XCTAssertEqual(v.signedBy, [id(current)])
        XCTAssertNil(v.newKey)
        XCTAssertEqual(v.manifest.mirageVersion, MirageVersion(version: "0.4.1", build: 420, commit: "69bb8ba", channel: .nightly))
        // The JSON keys are the design's, `protocol` included.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["channel", "version", "build", "commit", "minProtocol", "protocol", "minOS", "zipURL", "zipSHA256", "zipSize", "notes", "published", "expires"])
    }

    func testATamperedManifestIsRefused() throws {
        let (d, s) = try signed(manifest(), by: [current])
        var t = String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\"build\" : 420", with: "\"build\" : 9999")
        XCTAssertNotEqual(Data(t.utf8), d)
        XCTAssertThrowsError(try ManifestVerifier.verify(manifest: Data(t.utf8), signatures: s, trust: trust, channel: .nightly, now: now)) {
            XCTAssertEqual($0 as? ManifestError, .noTrustedSignature(keyIDs: [id(current)]))
        }
        // Whitespace counts too: the signature covers the exact bytes.
        t = String(decoding: d, as: UTF8.self) + "\n"
        XCTAssertThrowsError(try ManifestVerifier.verify(manifest: Data(t.utf8), signatures: s, trust: trust, channel: .nightly, now: now))
        // A tampered signature.
        var sigs = try JSONDecoder().decode([String: String].self, from: s)
        var raw = Data(base64Encoded: sigs[id(current)]!)!; raw[0] ^= 1; sigs[id(current)] = raw.base64EncodedString()
        XCTAssertThrowsError(try ManifestVerifier.verify(manifest: d, signatures: try JSONEncoder().encode(sigs), trust: trust, channel: .nightly, now: now))
        XCTAssertThrowsError(try ManifestVerifier.verify(manifest: d, signatures: Data("nope".utf8), trust: trust, channel: .nightly, now: now)) {
            XCTAssertEqual($0 as? ManifestError, .malformedSignatures)
        }
    }

    func testAnExpiredManifestIsRefused() throws {
        let (d, s) = try signed(manifest(expiresIn: 60), by: [current])
        XCTAssertNoThrow(try ManifestVerifier.verify(manifest: d, signatures: s, trust: trust, channel: .nightly, now: now.addingTimeInterval(59)))
        XCTAssertThrowsError(try ManifestVerifier.verify(manifest: d, signatures: s, trust: trust, channel: .nightly, now: now.addingTimeInterval(60))) {
            XCTAssertEqual($0 as? ManifestError, .expired(self.now.addingTimeInterval(60)))
        }
    }

    func testAWrongKeyIsRefused() throws {
        let (d, s) = try signed(manifest(), by: [stranger])
        XCTAssertThrowsError(try ManifestVerifier.verify(manifest: d, signatures: s, trust: trust, channel: .nightly, now: now)) {
            XCTAssertEqual($0 as? ManifestError, .noTrustedSignature(keyIDs: [id(stranger)]))
        }
        // A stranger's signature filed under a trusted key's ID does not verify either.
        let forged = try JSONEncoder().encode([id(current): try stranger.signature(for: d).base64EncodedString()])
        XCTAssertThrowsError(try ManifestVerifier.verify(manifest: d, signatures: forged, trust: trust, channel: .nightly, now: now))
        // A build with no compiled keys verifies nothing.
        XCTAssertThrowsError(try ManifestVerifier.verify(manifest: d, signatures: s, trust: ManifestTrust(compiled: [], learned: [], revoked: []), channel: .nightly, now: now)) {
            XCTAssertEqual($0 as? ManifestError, .noTrustedKeys)
        }
    }

    func testAnotherChannelsManifestIsRefused() throws {
        let (d, s) = try signed(manifest(channel: .nightly), by: [current])
        XCTAssertThrowsError(try ManifestVerifier.verify(manifest: d, signatures: s, trust: trust, channel: .stable, now: now)) {
            XCTAssertEqual($0 as? ManifestError, .wrongChannel(expected: .stable, got: .nightly))
        }
    }

    func testTheNextKeyIsTrustedFromTheStart() throws {
        let (d, s) = try signed(manifest(), by: [next])
        XCTAssertEqual(try ManifestVerifier.verify(manifest: d, signatures: s, trust: trust, channel: .nightly, now: now).signedBy, [id(next)])
    }

    /// Rotation without a reinstall: a manifest signed by the current key introduces a new key; once learned, releases
    /// signed by both, then by the new key alone, verify.
    func testNextKeyRotation() throws {
        let newer = Curve25519.Signing.PrivateKey()
        let (d1, s1) = try signed(manifest(build: 420, nextKey: b64(newer)), by: [current])
        let v1 = try ManifestVerifier.verify(manifest: d1, signatures: s1, trust: trust, channel: .nightly, now: now)
        XCTAssertEqual(v1.newKey, b64(newer), "the host adds it to its learned keys")
        // Before learning it, the new key alone is not trusted.
        let (d3, s3) = try signed(manifest(build: 440), by: [newer])
        XCTAssertThrowsError(try ManifestVerifier.verify(manifest: d3, signatures: s3, trust: trust, channel: .nightly, now: now))
        var learned = trust; learned.learned = [v1.newKey!]
        let (d2, s2) = try signed(manifest(build: 430), by: [current, newer])
        XCTAssertEqual(Set(try ManifestVerifier.verify(manifest: d2, signatures: s2, trust: learned, channel: .nightly, now: now).signedBy), [id(current), id(newer)])
        XCTAssertEqual(try ManifestVerifier.verify(manifest: d3, signatures: s3, trust: learned, channel: .nightly, now: now).signedBy, [id(newer)])
        // The release after that drops the old key from the compiled list: that build no longer trusts it.
        let retired = ManifestTrust(compiled: [b64(newer), b64(next)], learned: [], revoked: [])
        let (d4, s4) = try signed(manifest(build: 450), by: [current])
        XCTAssertThrowsError(try ManifestVerifier.verify(manifest: d4, signatures: s4, trust: retired, channel: .nightly, now: now))
        // A nextKey that is already trusted is nothing new; one that is not a key is malformed.
        XCTAssertNil(try ManifestVerifier.verify(manifest: d2, signatures: s2, trust: learned, channel: .nightly, now: now).newKey)
        let (d5, s5) = try signed(manifest(nextKey: "bm90IGEga2V5"), by: [current])
        XCTAssertThrowsError(try ManifestVerifier.verify(manifest: d5, signatures: s5, trust: trust, channel: .nightly, now: now))
    }

    /// The compromise procedure: a revoking build refuses a manifest signed only by the old key, whatever else it claims,
    /// accepts one the promoted key also signed, drops the old key from the learned set, and never learns it again.
    func testARevokedKeyIsRefused() throws {
        let leaked = current
        let revoking = ManifestTrust(compiled: [b64(next)], learned: [b64(leaked)], revoked: [id(leaked)])
        let (d, s) = try signed(manifest(), by: [leaked])
        XCTAssertThrowsError(try ManifestVerifier.verify(manifest: d, signatures: s, trust: revoking, channel: .nightly, now: now)) {
            XCTAssertEqual($0 as? ManifestError, .noTrustedSignature(keyIDs: [id(leaked)]))
        }
        let (d2, s2) = try signed(manifest(), by: [leaked, next])
        XCTAssertEqual(try ManifestVerifier.verify(manifest: d2, signatures: s2, trust: revoking, channel: .nightly, now: now).signedBy, [id(next)])
        XCTAssertEqual(revoking.prunedLearned(), [], "removed from the learned keys at start")
        XCTAssertNil(revoking.trusted[id(leaked)])
        // Revocation wins over the compiled list too.
        XCTAssertTrue(ManifestTrust(compiled: [b64(leaked)], learned: [], revoked: [id(leaked)]).trusted.isEmpty)
        // A manifest cannot reintroduce a revoked key through nextKey.
        let (d3, s3) = try signed(manifest(nextKey: b64(leaked)), by: [next])
        XCTAssertNil(try ManifestVerifier.verify(manifest: d3, signatures: s3, trust: revoking, channel: .nightly, now: now).newKey)
    }

    func testRelativeZipURLsResolveAgainstTheManifest() {
        var m = manifest(); m.zipURL = "Mirage-0.4.1-420.zip"
        XCTAssertEqual(m.zipURL(relativeTo: URL(fileURLWithPath: "/tmp/feed/channel-nightly/manifest.json"))?.path, "/tmp/feed/channel-nightly/Mirage-0.4.1-420.zip")
        XCTAssertEqual(manifest().zipURL(relativeTo: URL(string: "https://example.com/a/manifest.json")!)?.host, "github.com")
    }

    func testFeedURLs() {
        let f = Feed()
        XCTAssertEqual(f.manifestURL(.nightly).absoluteString, "https://github.com/phrz/mirage/releases/download/channel-nightly/manifest.json")
        XCTAssertEqual(f.signaturesURL(.stable).absoluteString, "https://github.com/phrz/mirage/releases/download/channel-stable/manifest.sigs.json")
        XCTAssertEqual(Feed(override: "/tmp/feed").manifestURL(.beta).path, "/tmp/feed/channel-beta/manifest.json")
        XCTAssertEqual(Feed(override: nil).base, Feed.github)
    }
}
