import Foundation
import CryptoKit
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif

/// Long-term device identity: an Ed25519 key. Hosts and clients both have one.
/// Pairing adds the client's public key to the host's authorized list and the host's
/// public key to the client's known-hosts list. TLS certificates are *not* pinned;
/// the TLS leaf fingerprint is instead folded into every signature as a channel
/// binding, so a man-in-the-middle terminating TLS cannot replay signatures.
public struct DeviceIdentity: Sendable {
    public let signingKey: Curve25519.Signing.PrivateKey
    public let name: String

    public var publicKey: Data { signingKey.publicKey.rawRepresentation }
    public var id: String { DeviceIdentity.id(forPublicKey: publicKey) }

    public static func id(forPublicKey pk: Data) -> String {
        SHA256.hash(data: pk).map { String(format: "%02x", $0) }.joined()
    }

    public init(name: String) {
        signingKey = Curve25519.Signing.PrivateKey()
        self.name = name
    }
    public init(seed: Data, name: String) throws {
        signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        self.name = name
    }

    public var record: DeviceRecord {
        DeviceRecord(id: id, name: name, publicKey: publicKey, pairedAt: Date(), model: DeviceModel.current)
    }

    // MARK: Session authentication transcript

    /// What the host signs: proves it holds the key the client paired with, bound to
    /// the TLS connection the client is actually on.
    public static func hostAuthTranscript(tlsFingerprint: Data, clientNonce: Data, hostNonce: Data, clientID: String) -> Data {
        var d = Data("\(Mirage.dsi)/auth/host".utf8)
        d += lv(tlsFingerprint); d += lv(clientNonce); d += lv(hostNonce); d += lv(Data(clientID.utf8))
        return d
    }

    public static func clientAuthTranscript(tlsFingerprint: Data, clientNonce: Data, hostNonce: Data, hostID: String) -> Data {
        var d = Data("\(Mirage.dsi)/auth/client".utf8)
        d += lv(tlsFingerprint); d += lv(clientNonce); d += lv(hostNonce); d += lv(Data(hostID.utf8))
        return d
    }

    public func sign(_ message: Data) throws -> Data {
        try signingKey.signature(for: message)
    }

    public static func verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return pk.isValidSignature(signature, for: message)
    }

    public static func nonce() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    }
}

/// On-disk form of a DeviceIdentity. File permissions are the protection for now;
/// moving the seed into the keychain / Secure Enclave is a follow-up.
struct IdentityFile: Codable {
    var seed: Data
    var name: String?   // legacy; names are no longer persisted
}

public enum DeviceNames {
    /// Set once at launch where the system has no computer name (iOS).
    nonisolated(unsafe) public static var deviceName: String?
    /// The user-facing computer name ("mac-daddy"), falling back to the host name.
    public static func current() -> String {
        #if os(macOS)
        if let n = SCDynamicStoreCopyComputerName(nil, nil) as String?, !n.isEmpty { return n }
        #else
        // iOS: the app sets the device model ("iPhone", "iPad") at launch; the user-assigned name needs an entitlement.
        if let n = deviceName, !n.isEmpty { return n }
        #endif
        return ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".localdomain", with: "")
            .replacingOccurrences(of: ".local", with: "")
    }
}
