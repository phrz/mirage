import Foundation

/// The host's local control interface (DESIGN §3.1 pairing): how the Mirage app on the host Mac drives the headless
/// `miraged` — open a pairing window, receive its rotating code and link, answer Allow / Deny. A Unix domain socket in the
/// store directory (`control.sock`, the directory 0700, the socket 0600, the peer's uid checked), carrying one JSON object
/// per line. The same path and user hold when `miraged` later runs as Mirage.app's login-item helper (SMAppService), so the
/// interface survives that move unchanged.
public enum LocalControl {
    public static let version = 1
    public static let socketName = "control.sock"

    /// The app's requests.
    public enum Request: Codable, Equatable {
        case hello(version: Int, client: String)
        /// Opens (or keeps) a pairing window; the host answers with `pairing` events until it closes.
        case openPairing
        case closePairing
        /// The answer to a `confirm` event.
        case decide(requestID: String, allow: Bool)
        case status
    }

    /// The host's events.
    public enum Event: Codable, Equatable {
        case hello(version: Int, hostName: String, hostID: String)
        /// The pairing window's current code and link (sent on opening and on every rotation).
        case pairing(Pairing)
        case pairingClosed(reason: String)
        /// A device finished the exchange and waits for Allow / Deny (answer with `decide`).
        case confirm(Confirm)
        case paired(deviceName: String)
        case status(Status)
    }

    public struct Pairing: Codable, Equatable {
        public var code: String
        public var link: String
        public var rotatesAt: Date
        public var closesAt: Date
        public var hostName: String
        public var address: String
        public init(code: String, link: String, rotatesAt: Date, closesAt: Date, hostName: String, address: String) {
            self.code = code; self.link = link; self.rotatesAt = rotatesAt; self.closesAt = closesAt; self.hostName = hostName; self.address = address
        }
    }
    public struct Confirm: Codable, Equatable {
        public var requestID: String
        public var deviceName: String
        public var deviceID: String
        public init(requestID: String, deviceName: String, deviceID: String) { self.requestID = requestID; self.deviceName = deviceName; self.deviceID = deviceID }
    }
    public struct Status: Codable, Equatable {
        public var hostName: String
        public var pairedDevices: Int
        public var pairingOpen: Bool
        public init(hostName: String, pairedDevices: Int, pairingOpen: Bool) { self.hostName = hostName; self.pairedDevices = pairedDevices; self.pairingOpen = pairingOpen }
    }

    /// One line of the wire format.
    public static func encodeLine<T: Encodable>(_ v: T) throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        var d = try e.encode(v); d.append(0x0A); return d
    }
    public static func decode<T: Decodable>(_ type: T.Type, line: Data) throws -> T {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return try d.decode(type, from: line)
    }

    /// Splits complete lines off a receive buffer.
    public static func takeLines(_ buffer: inout Data) -> [Data] {
        var out: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            out.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return out
    }
}

/// The app's end of the control socket: connects, reads events on its own thread, sends requests. Reconnects are the
/// caller's (the host may start later, or restart).
public final class LocalControlClient: @unchecked Sendable {
    public let path: String
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var reader: Thread?
    public var onEvent: ((LocalControl.Event) -> Void)?
    public var onClose: (() -> Void)?

    public init(path: String) { self.path = path }
    public convenience init(store: Store) { self.init(path: store.url(LocalControl.socketName).path) }

    public var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return fd >= 0 }

    /// Connects (throws if no host is listening).
    public func connect(client: String) throws {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw MirageError.transport("control socket: \(String(cString: strerror(errno)))") }
        var addr = sockaddr_un.make(path)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { let e = String(cString: strerror(errno)); close(s); throw MirageError.transport("no local host (\(e))") }
        lock.lock(); fd = s; lock.unlock()
        let t = Thread { [weak self] in self?.readLoop(s) }
        t.name = "mirage.local-control"
        reader = t
        t.start()
        try send(.hello(version: LocalControl.version, client: client))
    }

    public func send(_ r: LocalControl.Request) throws {
        let line = try LocalControl.encodeLine(r)
        lock.lock(); let s = fd; lock.unlock()
        guard s >= 0 else { throw MirageError.transport("control socket closed") }
        let n = line.withUnsafeBytes { write(s, $0.baseAddress, $0.count) }
        guard n == line.count else { throw MirageError.transport("control socket write failed") }
    }

    public func disconnect() {
        lock.lock(); let s = fd; fd = -1; lock.unlock()
        if s >= 0 { shutdown(s, SHUT_RDWR); close(s) }
    }

    private func readLoop(_ s: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(s, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            for line in LocalControl.takeLines(&buffer) {
                if let e = try? LocalControl.decode(LocalControl.Event.self, line: line) { onEvent?(e) }
            }
        }
        lock.lock(); let mine = fd == s; if mine { fd = -1 }; lock.unlock()
        if mine { close(s) }
        onClose?()
    }
}

extension sockaddr_un {
    /// A Unix socket address for `path` (at most 103 bytes).
    public static func make(_ path: String) -> sockaddr_un {
        var a = sockaddr_un()
        a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(103))
        withUnsafeMutableBytes(of: &a.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return a
    }
}
