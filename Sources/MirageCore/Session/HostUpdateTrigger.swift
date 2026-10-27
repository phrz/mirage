import Foundation

/// A viewer's side of the remote trigger (DESIGN §3.10, U4): connect and authenticate on a connection of its own (a stream
/// in progress is left alone), ask the host to update to the build it showed the person, follow `updateStatus` until the
/// host restarts, then reconnect until the new build answers, or the old one says it rolled back. The viewer never sends
/// code: the host fetches and verifies the build its own feed lists.
public enum HostUpdateTrigger {
    /// A fresh authenticated-to-be session and what closes its connection.
    public typealias Connect = @Sendable () async throws -> (session: ClientSession, close: @Sendable () -> Void)

    public struct Timing: Sendable {
        /// How long to keep reconnecting after the host restarts: past the host's own commit window (5 min, then it rolls
        /// back by itself), so the wait ends with the host's verdict rather than a guess (green-machine, 2026-10-27: 180 s
        /// ran out while its trial waited for a capture with the display asleep).
        public var reconnectFor: TimeInterval = 6.5 * 60
        public var pollEvery: TimeInterval = 3
        public init(reconnectFor: TimeInterval = 6.5 * 60, pollEvery: TimeInterval = 3) { self.reconnectFor = reconnectFor; self.pollEvery = pollEvery }
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
            case .update(let t):
                let n = t ?? (w.latestAvailable?.build ?? 0)
                try await s.stream.send(.updateHost(.init(targetBuild: n, minimumBuild: n)))   // older hosts read targetBuild
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
        // The host's own words when it answered (its trial status says what it waits for); else nothing is known: no
        // verdict, and the list keeps quiet (the row shows the host as it is, Not reachable or updating).
        if let t = lastTrial {
            let s = ControlMessage.UpdateStatus(phase: .unknown, message: t.message, from: from, to: t.to, yours: true)
            onStatus(s)
            return s
        }
        let why = lost ? "lost the connection to \(hostName); it has not said how the update went" : "\(hostName) has not answered since it restarted"
        let s = ControlMessage.UpdateStatus(phase: .unknown, message: why, from: from, yours: true, unanswered: true)
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
            if case .update(let t?) = command, (r.to?.build ?? 0) < t { return false }   // an earlier update's record
            return true
        }
        if let r, [.rolledBack, .failed].contains(r.phase), isThisUpdate(r) { return r }
        guard let now = w.hostVersion, let was = from else { return nil }
        let arrived: Bool
        switch command {
        // At least the build asked for: exactly it, or a newer one that replaced the build running before.
        case .update(let target): arrived = target.map { now.build == $0 || (now.build > $0 && now.build > was.build) } ?? (now.build > was.build)
        case .rollback: arrived = now.build != was.build
        }
        guard arrived else { return nil }
        if let r, r.phase == .trial, r.to?.build == now.build {
            let waiting = r.message.range(of: "waiting for ").map { " (" + r.message[$0.lowerBound...] + ")" } ?? ""
            return .init(phase: .trial, message: "\(w.hostName) runs \(now.display), checking its health\(waiting)", from: was, to: now, yours: true)
        }
        let verb = command == .rollback ? "rolled back to" : "runs"
        // What the commit noted: a grant missing at the Mac, or the capture check deferred while the display slept.
        let note = r.flatMap { $0.phase == .done && $0.to?.build == now.build ? $0.message.split(separator: ";", maxSplits: 1).dropFirst().first : nil }
            .map { ";" + $0 } ?? ""
        return .init(phase: .done, message: "\(w.hostName) \(verb) \(now.display)\(note)", from: was, to: now, yours: true)
    }
}
