import Foundation
import CryptoKit
import ArgumentParser
import MirageCore
import MirageUpdater

/// scripts/release.sh's helper (DESIGN §3.10): manifest keys, writing a manifest, signing it, and verifying it with the same
/// code a host runs. Private keys travel only through stdin and stdout, never as arguments (which `ps` shows).
@main
struct MirageRelease: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mirage-release",
        abstract: "Mirage release helper: manifest keys, manifests and their signatures.",
        subcommands: [Keygen.self, KeyID.self, WriteManifest.self, Sign.self, Verify.self])
}

struct Keygen: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a new Ed25519 manifest key pair as JSON {keyID, publicKey, privateKey} (base64 raw).")
    func run() throws {
        let k = Curve25519.Signing.PrivateKey()
        let pub = k.publicKey.rawRepresentation
        let out = ["keyID": ManifestKey.keyID(publicKey: pub), "publicKey": pub.base64EncodedString(), "privateKey": k.rawRepresentation.base64EncodedString()]
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try e.encode(out), as: UTF8.self))
    }
}

struct KeyID: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "keyid", abstract: "Print the key ID of a base64 public key.")
    @Argument var publicKey: String
    func run() throws {
        guard let k = ManifestKey.publicKey(base64: publicKey) else { throw ValidationError("not a base64 Ed25519 public key") }
        print(ManifestKey.keyID(publicKey: k.rawRepresentation))
    }
}

struct WriteManifest: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "manifest", abstract: "Write manifest.json for a release zip.")
    @Option var channel: UpdateChannel
    @Option var version: String
    @Option var build: Int
    @Option var commit: String
    @Option(help: "The zip (its SHA-256 and size go in the manifest).") var zip: String
    @Option(help: "The zip's URL: absolute, or relative to the manifest's.") var zipURL: String
    @Option var minOS: String = "15.0"
    @Option var notes: String = ""
    @Option(help: "Days until the manifest expires (default: 30 for nightly, 90 for beta, 365 for stable).") var expiresDays: Int?
    @Option(help: "A new public key (base64) to introduce for rotation.") var nextKey: String?
    @Option var out: String

    func run() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: zip))
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let now = Date()
        let days = expiresDays ?? [.nightly: 30, .beta: 90, .stable: 365][channel]!
        if let nk = nextKey, ManifestKey.publicKey(base64: nk) == nil { throw ValidationError("--next-key is not a base64 Ed25519 public key") }
        let m = Manifest(channel: channel, version: version, build: build, commit: commit,
                         minProtocol: Mirage.minProtocolVersion, protocolVersion: Mirage.protocolVersion, minOS: minOS,
                         zipURL: zipURL, zipSHA256: sha, zipSize: data.count, notes: notes,
                         published: now, expires: now.addingTimeInterval(TimeInterval(days) * 86_400), nextKey: nextKey)
        try m.encoded().write(to: URL(fileURLWithPath: out), options: .atomic)
        print("\(out): \(channel.rawValue) \(version) (\(build)) \(commit), zip \(data.count) bytes sha256 \(sha.prefix(16))…, expires in \(days) days")
    }
}

extension UpdateChannel: ExpressibleByArgument {}

struct Sign: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Sign a manifest's bytes with the private keys on stdin (base64, one per line); write manifest.sigs.json.")
    @Option var manifest: String
    @Option var out: String
    func run() throws {
        var keys: [Curve25519.Signing.PrivateKey] = []
        while let line = readLine() {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            guard let raw = Data(base64Encoded: t), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
                throw ValidationError("stdin line \(keys.count + 1) is not a base64 Ed25519 private key")
            }
            keys.append(k)
        }
        guard !keys.isEmpty else { throw ValidationError("no private key on stdin") }
        let data = try Data(contentsOf: URL(fileURLWithPath: manifest))
        try ManifestKey.sign(data, with: keys).write(to: URL(fileURLWithPath: out), options: .atomic)
        print("\(out): signed by \(keys.map { ManifestKey.keyID(publicKey: $0.publicKey.rawRepresentation) }.joined(separator: ", "))")
    }
}

struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Verify a manifest as a host built from this tree would (its compiled trusted keys).")
    @Option var manifest: String
    @Option var sigs: String
    @Option var channel: UpdateChannel?
    func run() throws {
        let trust = ManifestTrust()
        do {
            let v = try ManifestVerifier.verify(manifest: try Data(contentsOf: URL(fileURLWithPath: manifest)),
                                                signatures: try Data(contentsOf: URL(fileURLWithPath: sigs)), trust: trust, channel: channel)
            print("ok: \(v.manifest.channel.rawValue) \(v.manifest.mirageVersion.display) signed by \(v.signedBy.joined(separator: ", "))\(v.newKey != nil ? "; introduces a new key" : "")")
        } catch {
            print("error: \(error)")
            throw ExitCode(1)
        }
    }
}
