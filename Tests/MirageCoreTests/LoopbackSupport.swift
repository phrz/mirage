import XCTest
import Network
@testable import MirageCore

/// Loopback QUIC for tests, load-tolerant: the system picks the port (random ports collided across concurrent runs) and
/// every wait has a generous deadline (5 s timed out under a CPU hog); a listener that fails ends the wait at once.
enum Loopback {
    static let timeout: TimeInterval = 30

    final class ListenerState: @unchecked Sendable {
        private let lock = NSLock(); private var s: NWListener.State = .setup
        func set(_ v: NWListener.State) { lock.lock(); s = v; lock.unlock() }
        var state: NWListener.State { lock.lock(); defer { lock.unlock() }; return s }
    }

    /// A started host on a free port, ready to accept.
    static func host(tls: TLSIdentity, ctx: HostContext) async throws -> (QUICHost, UInt16) {
        let host = try QUICHost(port: 0, tls: tls)
        let st = ListenerState()
        host.start(onStream: { conn, id, remote in Task { await HostSession.handle(connection: conn, connectionID: id, remote: remote, ctx: ctx) } },
                   onState: { st.set($0) })
        try await eventually("the loopback host listening") {
            if case .failed(let e) = st.state { throw MirageError.transport("listener failed: \(e)") }
            if case .ready = st.state { return host.port != nil }
            return false
        }
        return (host, host.port!)
    }

    /// Polls `condition` every 10 ms until it holds or `timeout` passes.
    static func eventually(_ what: String, timeout: TimeInterval = Loopback.timeout, _ condition: () throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MirageError.transport("timed out after \(Int(timeout)) s waiting for \(what)")
    }
}
