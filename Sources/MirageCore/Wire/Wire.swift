import Foundation

/// Protocol constants shared by host and clients.
public enum Mirage {
    public static let protocolVersion = 1
    public static let alpn = "mirage/1"
    public static let defaultPort: UInt16 = 7799
    /// Domain-separation prefix for every hash/signature in the protocol.
    public static let dsi = "mirage-v1"
}

/// Length-prefixed JSON frames on a reliable QUIC stream.
/// [u32 big-endian payload length][JSON payload]
public enum Frame {
    public static let maxLength = 1 << 20

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder().encode(value)
        precondition(body.count <= maxLength)
        var out = Data(capacity: 4 + body.count)
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    public static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }

    public static func length(from header: Data) -> Int {
        precondition(header.count == 4)
        return Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
    }
}

/// Every message on the control stream. JSON is fine for the control plane;
/// pixel data will get its own binary framing on other streams.
public enum ControlMessage: Codable, Equatable {
    // Session authentication (paired devices).
    case hello(Hello)
    case challenge(Challenge)
    case authenticate(Authenticate)
    case welcome(Welcome)
    case reject(Reject)

    // Pairing (CPace over X25519, see Crypto/CPace.swift).
    case pairRequest(PairRequest)
    case pairChallenge(PairChallenge)
    case pairConfirm(PairConfirm)
    case pairAccept(PairAccept)
    case pairIdentity(PairIdentity)
    case pairComplete(PairComplete)

    // Liveness / latency.
    case ping(Ping)
    case pong(Ping)

    public struct Hello: Codable, Equatable {
        public var protocolVersion: Int
        /// SHA-256 of the client's Ed25519 public key, hex.
        public var deviceID: String
        public var deviceName: String
        public var clientNonce: Data
        public init(protocolVersion: Int, deviceID: String, deviceName: String, clientNonce: Data) {
            self.protocolVersion = protocolVersion; self.deviceID = deviceID
            self.deviceName = deviceName; self.clientNonce = clientNonce
        }
    }
    public struct Challenge: Codable, Equatable {
        public var hostID: String
        public var hostName: String
        public var hostPublicKey: Data
        public var hostNonce: Data
        /// Ed25519 over the auth transcript, which includes the TLS leaf fingerprint
        /// the client observed (channel binding).
        public var hostSignature: Data
        public init(hostID: String, hostName: String, hostPublicKey: Data, hostNonce: Data, hostSignature: Data) {
            self.hostID = hostID; self.hostName = hostName; self.hostPublicKey = hostPublicKey
            self.hostNonce = hostNonce; self.hostSignature = hostSignature
        }
    }
    public struct Authenticate: Codable, Equatable {
        public var clientPublicKey: Data
        public var clientSignature: Data
        public init(clientPublicKey: Data, clientSignature: Data) {
            self.clientPublicKey = clientPublicKey; self.clientSignature = clientSignature
        }
    }
    public struct Welcome: Codable, Equatable {
        public var hostName: String
        public var sessionID: String
        public init(hostName: String, sessionID: String) { self.hostName = hostName; self.sessionID = sessionID }
    }
    public struct Reject: Codable, Equatable {
        public var reason: String
        public init(reason: String) { self.reason = reason }
    }

    public struct PairRequest: Codable, Equatable {
        public var protocolVersion: Int
        public var deviceName: String
        public init(protocolVersion: Int, deviceName: String) { self.protocolVersion = protocolVersion; self.deviceName = deviceName }
    }
    public struct PairChallenge: Codable, Equatable {
        public var sid: Data
        public var hostName: String
        /// Host's CPace public share Yb (32 bytes).
        public var share: Data
        public init(sid: Data, hostName: String, share: Data) { self.sid = sid; self.hostName = hostName; self.share = share }
    }
    public struct PairConfirm: Codable, Equatable {
        /// Client's CPace public share Ya (32 bytes).
        public var share: Data
        /// Client's explicit key confirmation tag.
        public var tag: Data
        public init(share: Data, tag: Data) { self.share = share; self.tag = tag }
    }
    public struct PairAccept: Codable, Equatable {
        /// Host's explicit key confirmation tag.
        public var tag: Data
        public init(tag: Data) { self.tag = tag }
    }
    public struct PairIdentity: Codable, Equatable {
        /// ChaChaPoly sealed box (nonce||ciphertext||tag) of a JSON `DeviceRecord`,
        /// keyed from the CPace session key.
        public var sealed: Data
        public init(sealed: Data) { self.sealed = sealed }
    }
    public struct PairComplete: Codable, Equatable {
        public var sealed: Data
        public init(sealed: Data) { self.sealed = sealed }
    }

    public struct Ping: Codable, Equatable {
        public var seq: UInt64
        /// Sender's monotonic clock in nanoseconds; echoed back verbatim.
        public var sentNanos: UInt64
        public init(seq: UInt64, sentNanos: UInt64) { self.seq = seq; self.sentNanos = sentNanos }
    }
}

/// A paired device as stored on disk and exchanged during pairing.
public struct DeviceRecord: Codable, Equatable, Sendable {
    public var id: String          // SHA-256(publicKey) hex
    public var name: String
    public var publicKey: Data     // Ed25519 raw, 32 bytes
    public var pairedAt: Date
    public init(id: String, name: String, publicKey: Data, pairedAt: Date) {
        self.id = id; self.name = name; self.publicKey = publicKey; self.pairedAt = pairedAt
    }
}

public enum MirageError: Error, CustomStringConvertible {
    case protocolViolation(String)
    case authenticationFailed(String)
    case pairingFailed(String)
    case transport(String)
    case storage(String)

    public var description: String {
        switch self {
        case .protocolViolation(let s): return "protocol violation: \(s)"
        case .authenticationFailed(let s): return "authentication failed: \(s)"
        case .pairingFailed(let s): return "pairing failed: \(s)"
        case .transport(let s): return "transport: \(s)"
        case .storage(let s): return "storage: \(s)"
        }
    }
}

public enum Clock {
    /// Monotonic nanoseconds; safe to difference, meaningless across machines.
    public static func nowNanos() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }
}
