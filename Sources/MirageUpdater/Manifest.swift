import Foundation
import CryptoKit
import MirageCore

/// One release as the feed describes it (DESIGN §3.10, feed and channels): `manifest.json` beside the zip, signed by
/// `manifest.sigs.json`. The signatures cover the file's exact bytes, so it is verified before it is decoded.
public struct Manifest: Codable, Equatable, Sendable {
    public var channel: UpdateChannel
    public var version: String
    public var build: Int
    public var commit: String
    /// The protocol range the build speaks.
    public var minProtocol: Int
    public var protocolVersion: Int
    /// The oldest macOS it runs on ("15.0").
    public var minOS: String
    /// Absolute, or relative to the manifest's own URL (a local feed for tests).
    public var zipURL: String
    /// Lowercase hex.
    public var zipSHA256: String
    public var zipSize: Int
    public var notes: String
    public var published: Date
    /// After this the manifest is refused: a stale or replayed one cannot freeze a host on an old build.
    public var expires: Date
    /// A new trusted public key (base64, raw Ed25519), introduced under the signature of an already trusted key.
    public var nextKey: String?

    enum CodingKeys: String, CodingKey {
        case channel, version, build, commit, minProtocol, protocolVersion = "protocol", minOS, zipURL, zipSHA256, zipSize, notes, published, expires, nextKey
    }

    public init(channel: UpdateChannel, version: String, build: Int, commit: String, minProtocol: Int, protocolVersion: Int, minOS: String,
                zipURL: String, zipSHA256: String, zipSize: Int, notes: String, published: Date, expires: Date, nextKey: String? = nil) {
        self.channel = channel; self.version = version; self.build = build; self.commit = commit
        self.minProtocol = minProtocol; self.protocolVersion = protocolVersion; self.minOS = minOS
        self.zipURL = zipURL; self.zipSHA256 = zipSHA256; self.zipSize = zipSize; self.notes = notes
        self.published = published; self.expires = expires; self.nextKey = nextKey
    }

    /// The build this manifest names, as the indicator and the version checks see it.
    public var mirageVersion: MirageVersion { MirageVersion(version: version, build: build, commit: commit, channel: channel) }

    /// The bytes the release script writes and signs: sorted keys, ISO 8601 dates.
    public func encoded() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }
    public static func decode(_ data: Data) throws -> Manifest {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(Manifest.self, from: data)
    }

    /// The zip's URL, resolved against the manifest's.
    public func zipURL(relativeTo manifestURL: URL) -> URL? { URL(string: zipURL, relativeTo: manifestURL)?.absoluteURL }
}

/// Manifest signing keys (DESIGN §3.10, manifest keys and rotation). A key's ID is the first 8 bytes of the SHA-256 of its
/// raw public key, hex.
public enum ManifestKey {
    public static func keyID(publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    public static func publicKey(base64: String) -> Curve25519.Signing.PublicKey? {
        Data(base64Encoded: base64).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }
    /// `manifest.sigs.json`: {keyID: base64 signature}, one per signing key.
    public static func sign(_ manifest: Data, with keys: [Curve25519.Signing.PrivateKey]) throws -> Data {
        var sigs: [String: String] = [:]
        for k in keys { sigs[keyID(publicKey: k.publicKey.rawRepresentation)] = try k.signature(for: manifest).base64EncodedString() }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(sigs)
    }
}

/// Which manifest keys a build trusts: the compiled `current` and `next` (TrustedKeys), plus keys learned from a verified
/// manifest's `nextKey` (kept in updates.json), minus the revoked ones, which win over everything.
public struct ManifestTrust: Equatable, Sendable {
    public var compiled: [String]
    public var learned: [String]
    /// Key IDs.
    public var revoked: Set<String>

    public init(compiled: [String] = TrustedKeys.compiled, learned: [String] = [], revoked: Set<String> = Set(TrustedKeys.revoked)) {
        self.compiled = compiled; self.learned = learned; self.revoked = revoked
    }

    /// keyID → key, revoked ones left out.
    public var trusted: [String: Curve25519.Signing.PublicKey] {
        var out: [String: Curve25519.Signing.PublicKey] = [:]
        for b in compiled + learned {
            guard let k = ManifestKey.publicKey(base64: b) else { continue }
            let id = ManifestKey.keyID(publicKey: k.rawRepresentation)
            if !revoked.contains(id) { out[id] = k }
        }
        return out
    }

    /// The learned keys without the revoked ones (a revoking build drops them from updates.json at start).
    public func prunedLearned() -> [String] {
        learned.filter { b in Data(base64Encoded: b).map { !revoked.contains(ManifestKey.keyID(publicKey: $0)) } ?? false }
    }
}

public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case noTrustedKeys
    case malformedSignatures
    case noTrustedSignature(keyIDs: [String])
    case malformed(String)
    case expired(Date)
    case wrongChannel(expected: UpdateChannel, got: UpdateChannel)

    public var description: String {
        switch self {
        case .noTrustedKeys: return "this build trusts no manifest key (TrustedKeys.compiled is empty: run scripts/release.sh keys-init)"
        case .malformedSignatures: return "manifest.sigs.json is malformed"
        case .noTrustedSignature(let ids): return "no signature by a trusted, unrevoked key (signed by \(ids.isEmpty ? "nothing" : ids.joined(separator: ", ")))"
        case .malformed(let s): return "manifest is malformed: \(s)"
        case .expired(let d): return "manifest expired at \(ISO8601DateFormatter().string(from: d))"
        case .wrongChannel(let e, let g): return "manifest is for \(g.rawValue), not \(e.rawValue)"
        }
    }
}

/// A manifest whose signature verified.
public struct VerifiedManifest: Equatable, Sendable {
    public var manifest: Manifest
    /// The trusted keys whose signature verified.
    public var signedBy: [String]
    /// The manifest's `nextKey` when it is new to this host (and not revoked): to be added to the learned keys.
    public var newKey: String?
}

public enum ManifestVerifier {
    /// At least one signature must verify under a trusted, unrevoked key; then the manifest must decode, be for `channel`
    /// (when given: a nightly manifest served as stable is refused) and not have expired.
    public static func verify(manifest data: Data, signatures sigData: Data, trust: ManifestTrust,
                              channel: UpdateChannel?, now: Date = Date()) throws -> VerifiedManifest {
        let trusted = trust.trusted
        guard !trusted.isEmpty else { throw ManifestError.noTrustedKeys }
        guard let sigs = try? JSONDecoder().decode([String: String].self, from: sigData) else { throw ManifestError.malformedSignatures }
        var ok: [String] = []
        for (id, b64) in sigs.sorted(by: { $0.key < $1.key }) {
            guard let key = trusted[id], let sig = Data(base64Encoded: b64) else { continue }
            if key.isValidSignature(sig, for: data) { ok.append(id) }
        }
        guard !ok.isEmpty else { throw ManifestError.noTrustedSignature(keyIDs: sigs.keys.sorted()) }
        let m: Manifest
        do { m = try Manifest.decode(data) } catch { throw ManifestError.malformed("\(error)") }
        if let channel, m.channel != channel { throw ManifestError.wrongChannel(expected: channel, got: m.channel) }
        guard now < m.expires else { throw ManifestError.expired(m.expires) }
        var newKey: String? = nil
        if let nk = m.nextKey, let k = ManifestKey.publicKey(base64: nk) {
            let id = ManifestKey.keyID(publicKey: k.rawRepresentation)
            if trusted[id] == nil, !trust.revoked.contains(id) { newKey = k.rawRepresentation.base64EncodedString() }
        } else if m.nextKey != nil {
            throw ManifestError.malformed("nextKey is not an Ed25519 public key")
        }
        return VerifiedManifest(manifest: m, signedBy: ok, newKey: newKey)
    }
}
