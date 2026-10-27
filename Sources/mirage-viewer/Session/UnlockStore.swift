import Foundation
import CryptoKit
import LocalAuthentication
import MirageCore

/// Unlock with biometry, the viewer's half (DESIGN §3.13): each host's account password, sealed to a Secure Enclave key of
/// this device that only its biometry unlocks (`biometryCurrentSet`: re-enrolling a finger or a face voids it), opened only
/// after the person approves, and sent only as an `unlock` message the host types at its lock screen.
///
/// Why not a Keychain item: on the Mac, the data-protection Keychain (the only one that takes biometric access control)
/// needs an application-identifier entitlement the Developer ID viewer does not have. A CryptoKit Secure Enclave key needs
/// none and gives the same guarantees: the key never leaves the Secure Enclave, its blob is useless on any other device,
/// and every use asks for biometry. What is stored (`unlock/<host id>.json` in the store, 0600) is that blob, an ephemeral
/// public key and the AES-GCM box: nothing readable without this device's Secure Enclave and its owner's biometry.
enum UnlockStore {
    /// This device's biometry as the system names it ("Touch ID", "Face ID", "Optic ID") and its SF Symbol; nil without
    /// usable biometry or a Secure Enclave (then Unlock with biometry is not offered; a Mac with only an Apple Watch is
    /// noted for later).
    struct Biometry: Equatable { var name: String; var symbol: String }
    static var biometry: Biometry? {
        guard SecureEnclave.isAvailable, let b = LAEnvironment.currentUser.state.biometry, b.isUsable else { return nil }
        return Biometry(name: b.localizedName, symbol: b.iconSystemName)
    }

    enum Failure: Error, CustomStringConvertible {
        case noStore, accessControl, sealing(String), notSaved, cancelled, opening(String)
        var description: String {
            switch self {
            case .noStore: return "the store could not be opened"
            case .accessControl: return "the biometric access control could not be made"
            case .sealing(let e): return "could not save it (\(e))"
            case .notSaved: return "no password is saved"
            case .cancelled: return "not approved"
            case .opening(let e): return "could not open the saved password (\(e))"
            }
        }
    }
    private struct Sealed: Codable { var key: Data; var ephemeral: Data; var box: Data }

    private static func url(_ hostID: String) throws -> URL {
        guard let store = try? Store() else { throw Failure.noStore }
        let dir = store.url("unlock")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let safe = hostID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return dir.appendingPathComponent("\(safe).json")
    }
    private static func symmetricKey(_ shared: SharedSecret, hostID: String) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(hostID.utf8), sharedInfo: Data("mirage unlock v1".utf8), outputByteCount: 32)
    }

    /// Saves (or replaces) the password for `hostID`: a new Secure Enclave key, the password sealed to it. The old one stays
    /// until the new one is written (a failed replace never loses a working password). Needs no approval; opening it does.
    static func save(_ password: SecretBytes, hostID: String) throws {
        var err: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &err) else {
            throw Failure.accessControl
        }
        do {
            let se = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            let eph = P256.KeyAgreement.PrivateKey()
            let key = symmetricKey(try eph.sharedSecretFromKeyAgreement(with: se.publicKey), hostID: hostID)
            guard let box = try AES.GCM.seal(Data(password.bytes), using: key).combined else { throw Failure.sealing("no box") }
            let data = try JSONEncoder().encode(Sealed(key: se.dataRepresentation, ephemeral: eph.publicKey.x963Representation, box: box))
            let file = try url(hostID)
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch let f as Failure { throw f } catch { throw Failure.sealing("\(error)") }
    }

    /// Whether a password is saved for `hostID`, without asking anyone.
    static func has(hostID: String) -> Bool { (try? url(hostID)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// The password, after the person approves with their biometry (`reason` is shown in the system's prompt; biometry only,
    /// no passcode fallback). Throws `cancelled` when not approved, `notSaved` when there is none.
    static func open(hostID: String, reason: String) async throws -> SecretBytes {
        let file = try url(hostID)
        guard let data = try? Data(contentsOf: file), let sealed = try? JSONDecoder().decode(Sealed.self, from: data) else { throw Failure.notSaved }
        let ctx = LAContext()
        do { _ = try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) }
        catch { throw Failure.cancelled }
        do {
            let se = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: sealed.key, authenticationContext: ctx)
            let key = symmetricKey(try se.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: sealed.ephemeral)), hostID: hostID)
            var plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed.box), using: key)
            return SecretBytes(taking: &plain)
        } catch { throw Failure.opening("\(error)") }
    }

    static func delete(hostID: String) { if let f = try? url(hostID) { try? FileManager.default.removeItem(at: f) } }
}
