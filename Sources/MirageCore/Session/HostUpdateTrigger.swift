import Foundation

/// A viewer's side of the remote trigger (DESIGN §3.10, U4): connect and authenticate on a connection of its own (a stream
/// in progress is left alone), ask the host to update to the build it showed the person, follow `updateStatus` until the
/// host restarts, then reconnect until the new build answers, or the old one says it rolled back. The viewer never sends
/// code: the host fetches and verifies the build its own feed lists.
public enum HostUpdateTrigger {
    /// A fresh authenticated-to-be session and what closes its connection.
    public typealias Connect = @Sendable () async throws -> (session: ClientSession, close: @Sendable () -> Void)

    public struct Timing: Sendable {
        /// How long to keep reconnecting after the host restarts (download and verification happen before it).
        public var reconnectFor: TimeInterval = 180
        public var pollEvery: TimeInterval = 2
        public init(reconnectFor: TimeInterval = 180, pollEvery: TimeInterval = 2) { self.reconnectFor = reconnectFor; self.pollEvery = pollEvery }
    }

    /// Runs the trigger to its end and returns the final status (done, failed or rolledBack); `onStatus` hears every step.
    public static func run(connect: Connect, command: UpdateCommand, hostName: String, timing: Timing = Timing(),
                           onStatus: @escaping @Sendable (ControlMessage.UpdateStatus) -> Void) async -> ControlMessage.UpdateStatus {
        func final(_ s: ControlMessage.UpdateStatus) -> ControlMessage.UpdateStatus { onStatus(s); return s }
        let from: MirageVersion?
        do {
            let (s, close) = try await connect()
            defer { close() }
            let w = try await s.authenticate(features: [ControlMessage.Feature.updateStatus])
            from = w.hostVersion
            if !w.acceptsUpdateTrigger {
                let why = UpdateGate.refusal(permission: w.updatePolicy, canUpdate: (w.features ?? []).contains(ControlMessage.Feature.updateTrigger), hostName: w.hostName)
                return final(.init(phase: .failed, message: why ?? "\(w.hostName) does not take update triggers", from: from, yours: true))
            }
            switch command {
            case .update(let t): try await s.stream.send(.updateHost(.init(targetBuild: t ?? (w.latestAvailable?.build ?? 0))))
            case .rollback: try await s.stream.send(.rollbackHost)
            }
            onStatus(.init(phase: .checking, message: "asking \(hostName) to \(command == .rollback ? "roll back" : "update")", from: from, yours: true))
            var restarting = false
            while !restarting {
                let m: ControlMessage
                do { m = try await s.stream.receive() } catch {
                    // Lost before the host said it restarts: not known to be a restart. The host records how an update
                    // ended (Welcome.updateResult), so reconnecting learns the outcome.
                    onStatus(.init(phase: .unknown, message: "lost the connection to \(hostName); waiting for it to report how the update went", from: from, yours: true))
                    return await awaitRestart(connect: connect, command: command, from: from, hostName: hostName, timing: timing, lost: true, onStatus: onStatus)
                }
                guard case .updateStatus(let st) = m else { continue }
                if st.isFinal { return final(st) }
                onStatus(st)
                if st.phase == .restarting { restarting = true }
            }
        } catch {
            return final(.init(phase: .failed, message: "could not reach \(hostName): \(error)", yours: true))
        }
        return await awaitRestart(connect: connect, command: command, from: from, hostName: hostName, timing: timing, lost: false, onStatus: onStatus)
    }

    /// After the restart (or a lost connection): connect until the host's Welcome says the new build committed (done), it
    /// rolled back or failed, or the time runs out. A new build that answers but is still on trial is reported as such, and
    /// the polling goes on.
    static func awaitRestart(connect: Connect, command: UpdateCommand, from: MirageVersion?, hostName: String, timing: Timing, lost: Bool,
                             onStatus: @escaping @Sendable (ControlMessage.UpdateStatus) -> Void) async -> ControlMessage.UpdateStatus {
        let end = Date().addingTimeInterval(timing.reconnectFor)
        if !lost { onStatus(.init(phase: .restarting, message: "\(hostName) is restarting", from: from, yours: true)) }
        var lastTrial: ControlMessage.UpdateStatus?
        while Date() < end {
            try? await Task.sleep(for: .seconds(timing.pollEvery))
            guard let (s, close) = try? await connect() else { continue }
            defer { close() }
            guard let w = try? await s.authenticate(features: [ControlMessage.Feature.updateStatus]) else { continue }
            guard let verdict = outcome(welcome: w, command: command, from: from) else { continue }
            if verdict.isFinal { onStatus(verdict); return verdict }
            if verdict != lastTrial { onStatus(verdict); lastTrial = verdict }
        }
        let why = lastTrial != nil ? "\(hostName) runs the new build, but it has not passed its health checks within \(Int(timing.reconnectFor)) s"
            : lost ? "lost the connection to \(hostName), and it has not reported how the update went within \(Int(timing.reconnectFor)) s"
            : "\(hostName) did not come back within \(Int(timing.reconnectFor)) s"
        let s = ControlMessage.UpdateStatus(phase: .failed, message: why, from: from, yours: true)
        onStatus(s)
        return s
    }

    /// What a Welcome after the restart says about the update: nil while nothing is known yet (the old build still answers
    /// and has no outcome for it); `trial` while the new build runs uncommitted; done once it committed; rolledBack or
    /// failed as the host recorded them.
    public static func outcome(welcome w: ControlMessage.Welcome, command: UpdateCommand, from: MirageVersion?) -> ControlMessage.UpdateStatus? {
        let r = w.updateResult
        func isThisUpdate(_ r: ControlMessage.UpdateStatus) -> Bool {
            if let f = from, let rf = r.from, rf.build != f.build { return false }
            if case .update(let t?) = command, r.to?.build != t { return false }   // an earlier update's record
            return true
        }
        if let r, [.rolledBack, .failed].contains(r.phase), isThisUpdate(r) { return r }
        guard let now = w.hostVersion, let was = from else { return nil }
        let arrived: Bool
        switch command {
        case .update(let target): arrived = target.map { now.build == $0 } ?? (now.build > was.build)
        case .rollback: arrived = now.build != was.build
        }
        guard arrived else { return nil }
        if let r, r.phase == .trial, r.to?.build == now.build {
            return .init(phase: .trial, message: "\(w.hostName) runs \(now.display), checking its health", from: was, to: now, yours: true)
        }
        let verb = command == .rollback ? "rolled back to" : "runs"
        return .init(phase: .done, message: "\(w.hostName) \(verb) \(now.display)", from: was, to: now, yours: true)
    }
}
