import Foundation
import MirageCore

/// The update the host agent is running now, if any (one at a time: the updater's lock).
public final class UpdateInProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var status: ControlMessage.UpdateStatus?
    public init() {}
    public var current: ControlMessage.UpdateStatus? { lock.lock(); defer { lock.unlock() }; return status }
    public func set(_ s: ControlMessage.UpdateStatus?) { lock.lock(); status = s; lock.unlock() }
}

extension UpdateDecision {
    /// Nothing to install, and nothing wrong: up to date, or the channel has not caught up.
    public var endsCleanly: Bool {
        switch self {
        case .upToDate, .channelBehind: return true
        case .available, .skipped, .incompatible: return false
        }
    }
}

/// The reply a running update gives: each step also becomes the host's "in progress" state (Welcome, local control),
/// with the from and to builds as soon as they are known; a final step also reaches the other listening viewers (a
/// trigger that lost the race waits on them).
final class UpdateReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var to: MirageVersion?
    let from: MirageVersion
    let replyTo: @Sendable (ControlMessage.UpdateStatus) -> Void
    let listeners: UpdateListeners
    let inProgress: UpdateInProgress
    let requester: UpdateRequester
    init(from: MirageVersion, listeners: UpdateListeners, inProgress: UpdateInProgress, requester: UpdateRequester,
         replyTo: @escaping @Sendable (ControlMessage.UpdateStatus) -> Void) {
        self.from = from; self.listeners = listeners; self.inProgress = inProgress; self.requester = requester; self.replyTo = replyTo
    }
    func learned(_ v: MirageVersion) { lock.lock(); to = v; lock.unlock() }
    var target: MirageVersion? { lock.lock(); defer { lock.unlock() }; return to }
    func reply(_ st: ControlMessage.UpdateStatus) {
        var s = st
        if s.from == nil { s.from = from }
        if s.to == nil { s.to = target }
        inProgress.set(s.isFinal ? nil : s)
        replyTo(s)
        if s.isFinal {
            var notice = s; notice.yours = false
            let listeners = self.listeners, except = requester.connectionID
            Task { await listeners.broadcast(notice, except: except) }
        }
    }
}

/// The host agent's updates (DESIGN §3.10, U4/U6): a trigger's, this Mac's, or the Automatic policy's, through the same
/// Updater as `miraged update`. After the swap, `handOff` restarts the host (the agent: a supervisor job; tests: a
/// stand-in).
public struct AgentUpdater: Sendable {
    public struct HandOff: Sendable {
        public var into: String
        public var from: MirageVersion?
        public var to: MirageVersion?
        /// `miraged update` arguments for the supervisor: ["--supervise"] after an update, ["--ensure-agent"] after a rollback.
        public var supervise: [String]
    }

    public var paths: InstallPaths
    public var hostName: String
    public var listeners: UpdateListeners
    public var inProgress: UpdateInProgress
    public var feed: Feed
    public var verifier: BundleVerifying
    public var handOff: @Sendable (HandOff) async -> Void
    public var log: @Sendable (String) -> Void

    public init(paths: InstallPaths, hostName: String, listeners: UpdateListeners, inProgress: UpdateInProgress, feed: Feed = Feed(),
                verifier: BundleVerifying = SystemBundleVerifier(), handOff: @escaping @Sendable (HandOff) async -> Void,
                log: @escaping @Sendable (String) -> Void) {
        self.paths = paths; self.hostName = hostName; self.listeners = listeners; self.inProgress = inProgress
        self.feed = feed; self.verifier = verifier; self.handOff = handOff; self.log = log
    }

    /// One update attempt; how it ended (the Automatic policy keeps or gives back its try by it). `gate`: asked before
    /// the swap and again before the restart; a reason defers the update (an undone swap if it came after it).
    public func update(target: Int?, requester: UpdateRequester, gate: (@Sendable () async -> String?)? = nil,
                       replyTo: @escaping @Sendable (ControlMessage.UpdateStatus) -> Void) async -> AutomaticUpdate.Ending {
        let running = Installer.version(of: paths.app) ?? .current
        let r = UpdateReporter(from: running, listeners: listeners, inProgress: inProgress, requester: requester, replyTo: replyTo)
        let updater = Updater(paths: paths, feed: feed, verifier: verifier, running: running,
                              report: { phase, message in r.reply(.init(phase: phase, message: message, yours: true)) })
        updater.learnedTarget = { r.learned($0) }
        let installer = Installer(paths: paths)
        let log = self.log
        func fail(_ message: String, transient: Bool) {
            log("update asked by \(requester.name) failed\(transient ? " (transient)" : ""): \(message)")
            let asked = r.target ?? MirageVersion(version: "", build: target ?? 0, commit: "", channel: nil)   // as far as known
            // Readable from the next Welcome, should this reply not reach the viewer.
            try? installer.writeResult(UpdateResult(outcome: .failed, from: running, to: asked, at: Date(), message: message))
            r.reply(.init(phase: .failed, message: message, from: running, to: asked, yours: true))
        }
        do {
            // A remote trigger never crosses a signing-identity change: that needs a person at the Mac.
            switch try await updater.install(targetBuild: target, allowIdentityChange: false, gate: gate) {
            case .nothing(let d):
                if d.endsCleanly { r.reply(.init(phase: .done, message: d.message, yours: true)); return .nothingToDo }
                fail(d.message, transient: false); return .failed(transient: false)
            case .swapped(let p, _):
                // The moment may have ended during the download: once more before the restart. Not quiet: the swap is
                // undone (the old build back, nothing pending) and the update waits.
                if let gate, let why = await gate() {
                    do {
                        try installer.rollBack(keepReplaced: false)
                        installer.clearPending()
                        log("update \(p.to.display) deferred after the swap, undone: \(why)")
                        r.reply(.init(phase: .failed, message: "deferred: \(why)", from: p.from, to: p.to, yours: true))
                        return .deferred
                    } catch {
                        log("update: could not undo the swap (\(error)); restarting into it")   // the trial and commit still guard it
                    }
                }
                log("update \(p.from.display) → \(p.to.display) asked by \(requester.name): restarting into it")
                await restart(HandOff(into: p.to.display, from: p.from, to: p.to, supervise: ["--supervise"]), verb: "an update", requester: requester, reply: r.reply)
                return .swapped
            }
        } catch UpdateError.busy {
            // Lost the race to another update: nothing written, the running one's state untouched; this viewer (a listener)
            // hears that one's restart or end.
            let now = inProgress.current
            log("update asked by \(requester.name): another update is running")
            replyTo(.init(phase: now?.phase ?? .checking, message: "\(hostName) is already updating\(now.map { ": \($0.message)" } ?? "")",
                          from: now?.from, to: now?.to, yours: false))
            return .busy
        } catch let UpdateError.notPublished(build, newest, channel) {
            // Asked before this Mac's feed shows the build: nothing failed, nothing is recorded.
            log("update asked by \(requester.name): build \(build) is not on \(channel.rawValue) yet (newest \(newest))")
            r.reply(.init(phase: .failed, message: "build \(build) is not published yet", from: running, yours: true, notPublished: true))
            return .failed(transient: true)
        } catch UpdateError.deferred(let why) {
            log("update deferred before the swap: \(why)")
            r.reply(.init(phase: .failed, message: "deferred: \(why)", yours: true))
            return .deferred
        } catch {
            let transient = (error as? UpdateError)?.isTransient ?? false
            fail("\(error)", transient: transient)
            return .failed(transient: transient)
        }
    }

    public func rollback(requester: UpdateRequester, replyTo: @escaping @Sendable (ControlMessage.UpdateStatus) -> Void) async {
        let running = Installer.version(of: paths.app) ?? .current
        let r = UpdateReporter(from: running, listeners: listeners, inProgress: inProgress, requester: requester, replyTo: replyTo)
        let updater = Updater(paths: paths, running: running)
        let installer = Installer(paths: paths)
        if requester.connectionID != nil {
            // From a viewer: only right after an update, and only to a previous build of the same signing identity.
            let change = SigningIdentity.change(from: updater.runningIdentity(), to: SigningIdentity.of(bundle: paths.previous))
            if let why = RemoteRollback.refusal(pending: installer.readPending(), lastResult: installer.readResult(), running: running,
                                                now: Date(), identityChange: change) {
                log("rollback asked by \(requester.name): refused (\(why))")
                replyTo(.init(phase: .failed, message: why, from: running, yours: true))
                return
            }
        }
        do {
            // A viewer's rollback never marks the newest build skipped; a person's (the CLI) does.
            let (from, to) = try updater.rollback(skipReplaced: requester.connectionID == nil)
            log("rollback \(from?.display ?? "?") → \(to?.display ?? "?") asked by \(requester.name)")
            if let to { r.learned(to) }
            await restart(HandOff(into: to?.display ?? "its previous build", from: from, to: to, supervise: ["--ensure-agent"]),
                          verb: "a rollback", requester: requester, reply: r.reply)
        } catch UpdateError.busy {
            replyTo(.init(phase: .failed, message: "another update is running; try the rollback when it has finished", yours: true))
        } catch {
            r.reply(.init(phase: .failed, message: "\(error)", yours: true))
        }
    }

    /// Tells the other listening viewers, then the one that asked, and hands the restart over.
    func restart(_ h: HandOff, verb: String, requester: UpdateRequester, reply: (ControlMessage.UpdateStatus) -> Void) async {
        await listeners.broadcast(.init(phase: .restarting, message: "\(hostName) is restarting into \(h.into) (\(verb) by \(requester.name))",
                                        from: h.from, to: h.to, yours: false), except: requester.connectionID)
        reply(.init(phase: .restarting, message: "\(hostName) is restarting into \(h.into)", from: h.from, to: h.to, yours: true))
        await handOff(h)
    }
}
