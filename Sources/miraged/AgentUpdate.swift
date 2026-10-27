import Foundation
import CoreGraphics
import MirageCore
import MirageHost
import MirageUpdater

/// The host agent's updater for triggers (DESIGN §3.10, U4): a paired viewer's `updateHost`/`rollbackHost`, or this Mac's
/// menu bar and window bar over local control. The same `Updater` as `miraged update`, run in the agent. After the swap, a
/// one-shot job in the gui launchd domain supervises the restart (`miraged update --supervise`: restart the agent onto
/// the new build, watch it start, register it again or roll back, as from SSH). That job outlives the agent it restarts,
/// and runs the binary this agent runs (the build already proven here), never the new one.
let updateInProgress = UpdateInProgress()

/// The agent's updater: the shared AgentUpdater, whose restart is a one-shot job in the gui launchd domain running
/// `miraged update --supervise` (or `--ensure-agent` after a rollback) from the binary this agent runs (after the swap,
/// in the kept previous bundle): it outlives the agent it restarts, and is never the new, untested build.
func agentUpdater(paths: InstallPaths, ctx: HostContext, log: @escaping @Sendable (String) -> Void) -> AgentUpdater {
    AgentUpdater(paths: paths, hostName: ctx.identity.name, listeners: ctx.updateListeners, inProgress: updateInProgress,
                 feed: Feed(override: ProcessInfo.processInfo.environment["MIRAGE_UPDATE_FEED"]),
                 handOff: { h in
                     try? await Task.sleep(for: .milliseconds(500))   // the messages leave before the restart
                     let me = paths.previous.appendingPathComponent("Contents/MacOS/miraged")
                     guard FileManager.default.isExecutableFile(atPath: me.path) else {
                         log("update: no previous bundle to supervise from; restarting directly"); exit(0)   // KeepAlive starts the new build
                     }
                     if let why = AgentControl(app: paths.app, storeRoot: paths.support).runDetached([me.path, "update"] + h.supervise + ["--app", paths.app.path]) {
                         log("update: cannot start the supervisor (\(why)); restarting directly")
                         exit(0)   // KeepAlive starts the new build, which commits or rolls itself back
                     }
                 }, log: log)
}

func makeUpdateHandler(paths: InstallPaths, ctx: HostContext, log: @escaping @Sendable (String) -> Void) -> HostUpdateHandler {
    let updater = agentUpdater(paths: paths, ctx: ctx, log: log)
    return { command, requester, replyTo in
        switch command {
        case .update(let target): _ = await updater.update(target: target, requester: requester, replyTo: replyTo)
        case .rollback: await updater.rollback(requester: requester, replyTo: replyTo)
        }
    }
}

/// What the Welcome and local control say about updates: an update running now first, else the recorded outcome.
func hostUpdateInfo(paths: InstallPaths) -> HostUpdateInfo {
    var info = Updater.hostUpdateInfo(paths: paths)
    if let now = updateInProgress.current { info.lastResult = now }
    return info
}

/// The Automatic policy (U6): once a minute, when the policy is automatic and an update is available, install it at a
/// quiet moment (no viewer streaming, none suspended or having streamed in the last 10 min, no system prompt on screen,
/// nobody at this Mac for 10 min), through the same path as a trigger: the same trial, commit and rollback. The moment is
/// asked again before the swap and before the restart. Each build gets one automatic try; a transient failure (the
/// network, another update, the moment ending) gives it back.
func scheduleAutomaticUpdates(paths: InstallPaths, ctx: HostContext, handler: @escaping HostUpdateHandler, log: @escaping @Sendable (String) -> Void) {
    Task.detached {
        // The agent's own start counts as a stream's end: never right after a restart.
        let tracker = StreamTracker()
        var lastReason = ""
        @Sendable func moment() async -> AutomaticUpdate.Moment {
            let streaming = await ctx.connections.streamingDeviceIDs().count
            let suspended = await ctx.connections.suspendedSince()
            let now = Date()
            let ended = tracker.update(streaming: streaming, now: now)
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            return AutomaticUpdate.Moment(streaming: streaming, lastStreamEnded: ended, systemPrompt: !WarmPool.systemPromptWindows().isEmpty,
                                          idleSeconds: idle, now: now, suspendedRecently: AutomaticUpdate.Moment.recent(suspended, now: now))
        }
        while true {
            try? await Task.sleep(for: .seconds(AutomaticUpdate.every))
            let m = await moment()
            let settings = UpdateSettings.load(paths.settings)
            guard settings.policy == .automatic, updateInProgress.current == nil else { continue }
            switch AutomaticUpdate.decide(settings: settings, running: Installer.version(of: paths.app) ?? .current, moment: m) {
            case .wait(let why):
                if why != lastReason, !why.hasPrefix("up to date") { log("automatic update: waiting (\(why))") }
                lastReason = why
            case .install(let v):
                guard AutomaticUpdate.recordAttempt(v.build, settings: paths.settings) else {
                    log("automatic update: cannot record the attempt in \(paths.settings.path); not trying \(v.display)")
                    continue
                }
                log("automatic update: installing \(v.display) now (a quiet moment)")
                let ending = await agentUpdater(paths: paths, ctx: ctx, log: log)
                    // Exactly the build whose one try was recorded (review, 2026-10-27: "at least" could install another).
                    .update(target: v.build, exact: true, requester: UpdateRequester(name: "the Automatic policy", connectionID: nil),
                            gate: { AutomaticUpdate.gateReason(await moment()) },
                            replyTo: { st in if st.isFinal { log("automatic update: \(st.phase.rawValue): \(st.message)") } })
                if !ending.consumesTry {
                    AutomaticUpdate.releaseAttempt(v.build, settings: paths.settings)
                    log("automatic update: \(v.display) not installed (\(ending)); it will be tried again at a quiet moment")
                }
            }
        }
    }
    _ = handler
}

/// When the last stream ended, from minute samples (the agent's start counts as one).
final class StreamTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var was = false
    private var ended: Date? = Date()
    func update(streaming: Int, now: Date) -> Date? {
        lock.lock(); defer { lock.unlock() }
        if was, streaming == 0 { ended = now }
        was = streaming > 0
        return ended
    }
}
