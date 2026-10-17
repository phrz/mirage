import Foundation
import CryptoKit

/// Client-side protocol flows on an authenticated QUIC connection's control stream.
public struct ClientSession {
    public let identity: DeviceIdentity
    public let store: Store
    public let alias: String          // what the user typed, key into known-hosts
    public let tlsFingerprint: Data
    public let stream: MessageStream

    public init(identity: DeviceIdentity, store: Store, alias: String, tlsFingerprint: Data, stream: MessageStream) {
        self.identity = identity; self.store = store; self.alias = alias
        self.tlsFingerprint = tlsFingerprint; self.stream = stream
    }

    /// Runs CPace pairing with a 6-digit code and records the host.
    public func pair(code: String) async throws -> DeviceRecord {
        try await stream.send(.pairRequest(.init(protocolVersion: Mirage.protocolVersion, deviceName: identity.name)))
        let ch = try await stream.expect("pairChallenge") { if case .pairChallenge(let c) = $0 { return c } else { return nil } }
        let channel = lv(tlsFingerprint) + lv(Data(ch.hostName.utf8))
        let cpace = try CPace(password: code, channelID: channel, sid: ch.sid)
        let mine = try cpace.makeShare()
        let isk = try cpace.sessionKey(own: mine, peer: ch.share, initiatorShare: mine.publicShare, responderShare: ch.share)
        let tagA = CPace.confirmationTag(isk: isk, role: "A", initiatorShare: mine.publicShare, responderShare: ch.share)
        try await stream.send(.pairConfirm(.init(share: mine.publicShare, tag: tagA)))
        let accept = try await stream.expect("pairAccept") { if case .pairAccept(let a) = $0 { return a } else { return nil } }
        guard CPace.verifyTag(accept.tag, isk: isk, role: "B", initiatorShare: mine.publicShare, responderShare: ch.share) else {
            throw MirageError.pairingFailed("host confirmation tag invalid (wrong code or tampering)")
        }
        let key = CPace.pairingKey(isk: isk)
        try await stream.send(.pairIdentity(.init(sealed: try SealedBox.seal(identity.record, key: key))))
        let done = try await stream.expect("pairComplete") { if case .pairComplete(let c) = $0 { return c } else { return nil } }
        let host = try SealedBox.open(DeviceRecord.self, done.sealed, key: key)
        guard host.id == DeviceIdentity.id(forPublicKey: host.publicKey) else { throw MirageError.pairingFailed("malformed host identity") }
        try store.remember(host: .init(hostID: host.id, hostName: host.name, publicKey: host.publicKey, endpoint: alias, pairedAt: Date()), as: alias)
        return host
    }

    /// Mutual Ed25519 authentication, channel-bound to the TLS leaf fingerprint. `resumeToken` (from an
    /// earlier Welcome) asks the host to resume that session once this connection is authenticated.
    public func authenticate(resumeToken: Data? = nil) async throws -> ControlMessage.Welcome {
        guard let known = try store.knownHosts()[alias] else {
            throw MirageError.authenticationFailed("not paired with \(alias); run `mirage connect \(alias) --pair CODE`")
        }
        let clientNonce = DeviceIdentity.nonce()
        try await stream.send(.hello(.init(protocolVersion: Mirage.protocolVersion, deviceID: identity.id, deviceName: identity.name, clientNonce: clientNonce, resumeToken: resumeToken)))
        let ch = try await stream.expect("challenge") { if case .challenge(let c) = $0 { return c } else { return nil } }
        guard ch.hostID == known.hostID, ch.hostPublicKey == known.publicKey else {
            throw MirageError.authenticationFailed("host key for \(alias) changed (was \(known.hostID.prefix(12)), now \(ch.hostID.prefix(12))). Re-pair if this is expected.")
        }
        let hostTranscript = DeviceIdentity.hostAuthTranscript(tlsFingerprint: tlsFingerprint, clientNonce: clientNonce, hostNonce: ch.hostNonce, clientID: identity.id)
        guard DeviceIdentity.verify(signature: ch.hostSignature, message: hostTranscript, publicKey: known.publicKey) else {
            throw MirageError.authenticationFailed("host signature invalid (possible interception)")
        }
        let clientTranscript = DeviceIdentity.clientAuthTranscript(tlsFingerprint: tlsFingerprint, clientNonce: clientNonce, hostNonce: ch.hostNonce, hostID: ch.hostID)
        try await stream.send(.authenticate(.init(clientPublicKey: identity.publicKey, clientSignature: try identity.sign(clientTranscript))))
        return try await stream.expect("welcome") { if case .welcome(let w) = $0 { return w } else { return nil } }
    }

    /// Sends one stream ping and awaits its pong. Returns RTT in milliseconds.
    public func ping(seq: UInt64) async throws -> Double {
        let t0 = Clock.nowNanos()
        try await stream.send(.ping(.init(seq: seq, sentNanos: t0)))
        let pong = try await stream.expect("pong") { if case .pong(let p) = $0, p.seq == seq { return p } else { return nil } }
        _ = pong
        return Double(Clock.nowNanos() - t0) / 1e6
    }
}

/// Datagram ping format: magic(1) type(1)=ping seq(8 BE) sentNanos(8 BE) echoNanos(8 BE) padding to `size`.
/// The host echoes it with its own clock written into `echoNanos` (0 from the sender), so one small
/// datagram every 10 s gives the viewer RTT, loss and the clock offset it needs for frame age: that is
/// the session's keepalive (DESIGN §4a: sparse).
public enum DatagramPing {
    public static let minSize = 26
    public static func encode(seq: UInt64, size: Int = 32) -> Data {
        var d = Data([datagramMagic, DatagramType.ping.rawValue])
        var s = seq.bigEndian; var t = Clock.nowNanos().bigEndian; var e = UInt64(0)
        withUnsafeBytes(of: &s) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: &t) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: &e) { d.append(contentsOf: $0) }
        if d.count < size { d.append(Data(repeating: 0, count: size - d.count)) }
        return d
    }
    public static func decode(_ d: Data) -> (seq: UInt64, sentNanos: UInt64, echoNanos: UInt64)? {
        guard d.count >= 18, d[d.startIndex] == datagramMagic, d[d.startIndex+1] == DatagramType.ping.rawValue else { return nil }
        let seq = d.subdata(in: d.startIndex+2..<d.startIndex+10).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian
        let t = d.subdata(in: d.startIndex+10..<d.startIndex+18).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian
        let e = d.count >= minSize ? d.subdata(in: d.startIndex+18..<d.startIndex+26).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian : 0
        return (seq, t, e)
    }
    /// The host's reply: the ping with the responder's clock filled in.
    public static func echo(_ d: Data, now: UInt64 = Clock.nowNanos()) -> Data {
        guard d.count >= minSize else { return d }
        var out = d
        var e = now.bigEndian
        withUnsafeBytes(of: &e) { out.replaceSubrange(out.startIndex+18..<out.startIndex+26, with: $0) }
        return out
    }
}
