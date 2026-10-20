import Foundation
import CryptoKit

/// Base64url without padding (RFC 4648 §5): what pairing links carry.
public enum Base64URL {
    public static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

/// A pairing link (DESIGN §3.1 pairing): what the host's "Pair a Device…" window shows as a QR code.
/// `miragerd://pair?host=<tailnet name>&addr=<tailnet IP>&port=<port>&key=<host key hash>&secret=<128-bit>&exp=<unix time>`.
/// The secret is a high-entropy CPace password (the same exchange as the 6-digit code); the key hash pins the host's
/// Ed25519 key, so a viewer that scanned the code refuses any other host.
public struct PairingLink: Equatable, Sendable {
    public static let scheme = "miragerd"
    public var hostName: String
    public var address: String
    public var port: UInt16
    /// SHA-256 of the host's Ed25519 public key (the host's id, raw).
    public var keyHash: Data
    /// 128 random bits.
    public var secret: Data
    public var expires: Date

    public init(hostName: String, address: String, port: UInt16, keyHash: Data, secret: Data, expires: Date) {
        self.hostName = hostName; self.address = address; self.port = port; self.keyHash = keyHash; self.secret = secret; self.expires = expires
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme; c.host = "pair"
        c.queryItems = [
            .init(name: "host", value: hostName), .init(name: "addr", value: address), .init(name: "port", value: String(port)),
            .init(name: "key", value: Base64URL.encode(keyHash)), .init(name: "secret", value: Base64URL.encode(secret)),
            .init(name: "exp", value: String(Int(expires.timeIntervalSince1970))),
        ]
        return c.url!
    }

    /// Parses a scanned or opened link; nil if it is not a well-formed pairing link.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func q(_ n: String) -> String? { items.first(where: { $0.name == n })?.value }
        guard let host = q("host"), !host.isEmpty, let addr = q("addr"), !addr.isEmpty,
              let port = q("port").flatMap(UInt16.init), port > 0,
              let key = q("key").flatMap(Base64URL.decode), key.count == 32,
              let secret = q("secret").flatMap(Base64URL.decode), secret.count == 16,
              let exp = q("exp").flatMap(TimeInterval.init) else { return nil }
        self.init(hostName: host, address: addr, port: port, keyHash: key, secret: secret, expires: Date(timeIntervalSince1970: exp))
    }
    public init?(string: String) { guard let u = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }; self.init(url: u) }

    public func isExpired(now: Date = Date()) -> Bool { now >= expires }
    /// The CPace password this link stands for.
    public var password: String { Base64URL.encode(secret) }
    /// Whether a host's Ed25519 public key is the one this link pins.
    public func pins(publicKey: Data) -> Bool { Self.keyHash(forPublicKey: publicKey) == keyHash }

    public static func keyHash(forPublicKey pk: Data) -> Data { Data(SHA256.hash(data: pk)) }
    /// The key hash as people compare it: the first 16 bytes in hex, groups of four ("a1b2 c3d4 …").
    public static func fingerprintText(_ keyHash: Data) -> String {
        let hex = keyHash.prefix(16).map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { i in
            let s = hex.index(hex.startIndex, offsetBy: i); return String(hex[s..<hex.index(s, offsetBy: 4)])
        }.joined(separator: " ")
    }
}

/// The host's open "Pair a Device…" window: a 6-digit code and a link secret, both fresh every 30 s while the window is
/// open, each good for one attempt (taking it rotates both at once, so a code never survives a guess), the window closing
/// after 5 min. Pure logic; the menu-bar UI shows `current(now:)` and the host session takes passwords from it.
public final class PairingWindow: @unchecked Sendable {
    public static let rotation: TimeInterval = 30
    public static let lifetime: TimeInterval = 300

    public struct Credentials: Equatable, Sendable {
        public let code: String
        public let secret: Data
        public let issued: Date
        public var rotatesAt: Date { issued.addingTimeInterval(PairingWindow.rotation) }
    }

    private let lock = NSLock()
    private var creds: Credentials
    private var isClosed = false
    public let opened: Date
    public var closesAt: Date { opened.addingTimeInterval(Self.lifetime) }

    public init(now: Date = Date()) {
        opened = now
        creds = Self.fresh(now)
    }

    private static func fresh(_ now: Date) -> Credentials {
        let secret = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        return Credentials(code: PairingCode.generate(), secret: secret, issued: now)
    }

    public func isOpen(now: Date = Date()) -> Bool { lock.lock(); defer { lock.unlock() }; return !isClosed && now < closesAt }

    /// What the window shows now (rotated if 30 s have passed).
    public func current(now: Date = Date()) -> Credentials {
        lock.lock(); defer { lock.unlock() }
        if now >= creds.rotatesAt { creds = Self.fresh(now) }
        return creds
    }

    /// The password for one pairing attempt: the current code, or the current link secret (base64url). Taking it rotates
    /// both (single use). nil when the window is closed.
    public func takePassword(secret: Bool, now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed, now < closesAt else { return nil }
        if now >= creds.rotatesAt { creds = Self.fresh(now) }
        let p = secret ? Base64URL.encode(creds.secret) : creds.code
        creds = Self.fresh(now)
        return p
    }

    public func close() { lock.lock(); isClosed = true; lock.unlock() }

    /// The link for the current credentials.
    public func link(hostName: String, address: String, port: UInt16, hostPublicKey: Data, now: Date = Date()) -> PairingLink {
        let c = current(now: now)
        return PairingLink(hostName: hostName, address: address, port: port, keyHash: PairingLink.keyHash(forPublicKey: hostPublicKey), secret: c.secret, expires: c.rotatesAt)
    }
}

/// The host's pairing hooks, set by whatever UI the host has (the menu-bar item in `miraged serve`): the open window, and
/// the Allow/Deny question asked before a device is authorized (code or link alike). Without a question hook, a pairing
/// started by `miraged pair` asks that terminal (Store's confirm handshake); a window without a hook cannot exist.
public final class PairingSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var _window: PairingWindow?
    private var _confirm: (@Sendable (DeviceRecord) async -> Bool)?
    private var _paired: (@Sendable (DeviceRecord) -> Void)?
    public init() {}
    public var window: PairingWindow? {
        get { lock.lock(); defer { lock.unlock() }; return _window }
        set { lock.lock(); _window = newValue; lock.unlock() }
    }
    public var confirm: (@Sendable (DeviceRecord) async -> Bool)? {
        get { lock.lock(); defer { lock.unlock() }; return _confirm }
        set { lock.lock(); _confirm = newValue; lock.unlock() }
    }
    /// Called after a device was authorized (the window closes on success).
    public var paired: (@Sendable (DeviceRecord) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _paired }
        set { lock.lock(); _paired = newValue; lock.unlock() }
    }
}
