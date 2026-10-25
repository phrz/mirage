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
                    // The connection went: the host restarted into the update (a status may not have made it out first).
                    restarting = true; break
                }
                guard case .updateStatus(let st) = m else { continue }
                if st.isFinal { return final(st) }
                onStatus(st)
                if st.phase == .restarting { restarting = true }
            }
        } catch {
            return final(.init(phase: .failed, message: "could not reach \(hostName): \(error)", yours: true))
        }
        return await awaitRestart(connect: connect, command: command, from: from, hostName: hostName, timing: timing, onStatus: onStatus)
    }

    /// After the restart: connect until the host answers with the new build (done), says the update rolled back, or the time
    /// runs out.
    static func awaitRestart(connect: Connect, command: UpdateCommand, from: MirageVersion?, hostName: String, timing: Timing,
                             onStatus: @escaping @Sendable (ControlMessage.UpdateStatus) -> Void) async -> ControlMessage.UpdateStatus {
        let end = Date().addingTimeInterval(timing.reconnectFor)
        onStatus(.init(phase: .restarting, message: "\(hostName) is restarting", from: from, yours: true))
        while Date() < end {
            try? await Task.sleep(for: .seconds(timing.pollEvery))
            guard let (s, close) = try? await connect() else { continue }
            defer { close() }
            guard let w = try? await s.authenticate(features: [ControlMessage.Feature.updateStatus]) else { continue }
            if let verdict = outcome(welcome: w, command: command, from: from) { onStatus(verdict); return verdict }
        }
        let s = ControlMessage.UpdateStatus(phase: .failed, message: "\(hostName) did not come back within \(Int(timing.reconnectFor)) s", from: from, yours: true)
        onStatus(s)
        return s
    }

    /// What a Welcome after the restart says about the update: nil while the old build still answers (not restarted yet).
    public static func outcome(welcome w: ControlMessage.Welcome, command: UpdateCommand, from: MirageVersion?) -> ControlMessage.UpdateStatus? {
        if let r = w.updateResult, r.phase == .rolledBack, from == nil || r.from?.build == from?.build {
            if case .update(let t?) = command, r.to?.build != t {} else { return r }   // not an earlier update's rollback
        }
        guard let now = w.hostVersion, let was = from else { return nil }
        switch command {
        case .update(let target):
            if let t = target, now.build == t { return .init(phase: .done, message: "\(w.hostName) runs \(now.display)", from: was, to: now, yours: true) }
            if target == nil, now.build > was.build { return .init(phase: .done, message: "\(w.hostName) runs \(now.display)", from: was, to: now, yours: true) }
        case .rollback:
            if now.build != was.build { return .init(phase: .done, message: "\(w.hostName) rolled back to \(now.display)", from: was, to: now, yours: true) }
        }
        return nil
    }
}
