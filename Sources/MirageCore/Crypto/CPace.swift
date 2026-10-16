import Foundation
import CryptoKit

/// Balanced PAKE in the shape of CPace (draft-irtf-cfrg-cpace) instantiated on X25519,
/// which is the only elliptic-curve scalar multiplication CryptoKit exposes on an
/// arbitrary point. The 6-digit pairing code is the password (PRS).
///
/// Deviation from the draft, deliberately: the generator is derived by hashing
/// (DSI, PRS, CI, sid) straight to a u-coordinate instead of through Elligator2.
/// X25519's Montgomery ladder evaluates on both the curve and its (twist-secure)
/// quadratic twist, and the generators for different passwords have no known
/// discrete-log relation, which is the property the PAKE needs. Low-order outputs
/// are rejected by CryptoKit (all-zero shared secret throws).
///
/// Flow (client = initiator A, host = responder B):
///   host   -> sid, Yb
///   client -> Ya, Ta = MAC(ISK, "A" || transcript)
///   host   -> Tb = MAC(ISK, "B" || transcript)      (only after Ta verified)
/// The host burns the code after one failed Ta, so a 6-digit code allows exactly
/// one online guess.
public struct CPace {
    public struct Share {
        fileprivate let scalar: Curve25519.KeyAgreement.PrivateKey
        public let publicShare: Data
    }

    public let sid: Data
    private let generator: Curve25519.KeyAgreement.PublicKey

    /// - Parameters:
    ///   - password: the pairing code as typed (digits only).
    ///   - channelID: channel binding; here the host TLS leaf fingerprint plus host name.
    ///   - sid: 16 random bytes chosen by the host for this attempt.
    public init(password: String, channelID: Data, sid: Data) throws {
        self.sid = sid
        var h = SHA512()
        h.update(data: Data("\(Mirage.dsi)/cpace-x25519/generator".utf8))
        h.update(data: lv(Data(password.utf8)))
        h.update(data: lv(channelID))
        h.update(data: lv(sid))
        var u = Data(h.finalize().prefix(32))
        u[31] &= 0x7f
        generator = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: u)
    }

    public static func newSessionID() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    }

    public func makeShare() throws -> Share {
        let scalar = Curve25519.KeyAgreement.PrivateKey()
        let y = try scalar.sharedSecretFromKeyAgreement(with: generator)
        return Share(scalar: scalar, publicShare: y.withUnsafeBytes { Data($0) })
    }

    /// Derives the intermediate session key ISK from our scalar and the peer's share.
    /// `initiatorShare`/`responderShare` fix the transcript order regardless of role.
    public func sessionKey(own: Share, peer: Data, initiatorShare: Data, responderShare: Data) throws -> SymmetricKey {
        guard peer.count == 32 else { throw MirageError.pairingFailed("bad share length") }
        let peerPoint = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer)
        let k: SharedSecret
        do { k = try own.scalar.sharedSecretFromKeyAgreement(with: peerPoint) }
        catch { throw MirageError.pairingFailed("low-order share") }
        var h = SHA512()
        h.update(data: Data("\(Mirage.dsi)/cpace-x25519/isk".utf8))
        h.update(data: lv(sid))
        k.withUnsafeBytes { h.update(data: lv(Data($0))) }
        h.update(data: lv(initiatorShare))
        h.update(data: lv(responderShare))
        return SymmetricKey(data: h.finalize())
    }

    public static func confirmationTag(isk: SymmetricKey, role: String, initiatorShare: Data, responderShare: Data) -> Data {
        var mac = HMAC<SHA256>(key: isk)
        mac.update(data: Data("\(Mirage.dsi)/cpace-x25519/confirm/\(role)".utf8))
        mac.update(data: lv(initiatorShare))
        mac.update(data: lv(responderShare))
        return Data(mac.finalize())
    }

    public static func verifyTag(_ tag: Data, isk: SymmetricKey, role: String, initiatorShare: Data, responderShare: Data) -> Bool {
        let expected = confirmationTag(isk: isk, role: role, initiatorShare: initiatorShare, responderShare: responderShare)
        guard expected.count == tag.count else { return false }
        // Constant-time compare.
        var diff: UInt8 = 0
        for (a, b) in zip(expected, tag) { diff |= a ^ b }
        return diff == 0
    }

    /// Key for sealing identity records after confirmation.
    public static func pairingKey(isk: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: isk,
                               info: Data("\(Mirage.dsi)/cpace-x25519/pairing-key".utf8),
                               outputByteCount: 32)
    }
}

/// Length-prefixed encoding used inside hashes so fields cannot shift into each other.
func lv(_ d: Data) -> Data {
    var out = Data(capacity: 4 + d.count)
    var n = UInt32(d.count).bigEndian
    withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
    out.append(d)
    return out
}

public enum PairingCode {
    /// Six digits, uniformly random, zero-padded.
    public static func generate() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }
    public static func normalize(_ s: String) -> String? {
        let digits = s.filter(\.isNumber)
        return digits.count == 6 ? digits : nil
    }
}

public enum SealedBox {
    public static func seal<T: Encodable>(_ value: T, key: SymmetricKey) throws -> Data {
        let plain = try JSONEncoder().encode(value)
        return try ChaChaPoly.seal(plain, using: key).combined
    }
    public static func open<T: Decodable>(_ type: T.Type, _ sealed: Data, key: SymmetricKey) throws -> T {
        let box = try ChaChaPoly.SealedBox(combined: sealed)
        let plain = try ChaChaPoly.open(box, using: key)
        return try JSONDecoder().decode(type, from: plain)
    }
}
