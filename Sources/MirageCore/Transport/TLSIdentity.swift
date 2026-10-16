import Foundation
import Security
import CryptoKit

/// The host's TLS identity for QUIC. Self-signed, generated once with the system
/// openssl, kept as a PKCS#12 file and imported in-memory only (no keychain).
/// Clients never pin it; its SHA-256 fingerprint is a channel binding in the
/// Ed25519 handshake, which is what actually authenticates both sides.
public struct TLSIdentity {
    public let identity: SecIdentity
    public let certificate: SecCertificate
    public let fingerprint: Data

    public static func loadOrCreate(store: Store) throws -> TLSIdentity {
        let p12 = store.url("host-tls.p12")
        if !FileManager.default.fileExists(atPath: p12.path) {
            try generate(into: store)
        }
        return try load(p12: p12)
    }

    static func load(p12: URL) throws -> TLSIdentity {
        let data = try Data(contentsOf: p12)
        var items: CFArray?
        let options: [CFString: Any] = [
            kSecImportExportPassphrase: "mirage",
            kSecImportToMemoryOnly: true,
        ]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[CFString: Any]])?.first,
              let anyIdentity = first[kSecImportItemIdentity] else {
            throw MirageError.storage("SecPKCS12Import failed: \(status)")
        }
        let identity = anyIdentity as! SecIdentity
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else {
            throw MirageError.storage("no certificate in identity")
        }
        return TLSIdentity(identity: identity, certificate: cert, fingerprint: fingerprint(of: cert))
    }

    public static func fingerprint(of cert: SecCertificate) -> Data {
        Data(SHA256.hash(data: SecCertificateCopyData(cert) as Data))
    }

    static func generate(into store: Store) throws {
        let key = store.url("host-tls-key.pem").path
        let crt = store.url("host-tls-cert.pem").path
        let p12 = store.url("host-tls.p12").path
        let host = ProcessInfo.processInfo.hostName
        try run("/usr/bin/openssl", ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key])
        try run("/usr/bin/openssl", ["req", "-x509", "-new", "-key", key, "-out", crt, "-days", "3650",
                                      "-subj", "/CN=\(host)/O=Mirage"])
        try run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key, "-in", crt, "-out", p12,
                                      "-passout", "pass:mirage", "-name", "mirage-host"])
        for f in [key, crt, p12] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f)
        }
        try? FileManager.default.removeItem(atPath: key)
        try? FileManager.default.removeItem(atPath: crt)
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw MirageError.storage("\(tool) \(args.first ?? "") failed: \(msg)")
        }
    }
}
