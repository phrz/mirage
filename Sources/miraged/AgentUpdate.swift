import Foundation
import MirageCore
import MirageUpdater

/// The host agent's updater for triggers (DESIGN §3.10, U4): a paired viewer's `updateHost`/`rollbackHost`, or this Mac's
/// menu bar and window bar over local control. The same `Updater` as `miraged update`, run in the agent. After the swap, a
/// one-shot job in the gui launchd domain supervises the restart (`miraged update --supervise`: restart the agent onto
/// the new build, watch it start, register it again or roll back, as from SSH). That job outlives the agent it restarts,
/// and runs the binary this agent runs (the build already proven here), never the new one.
func makeUpdateHandler(paths: InstallPaths, ctx: HostContext, log: @escaping @Sendable (String) -> Void) -> HostUpdateHandler {
    { command, requester, reply in
        let host = ctx.identity.name
        let running = Installer.version(of: paths.app) ?? .current
        let updater = Updater(paths: paths, feed: Feed(override: ProcessInfo.processInfo.environment["MIRAGE_UPDATE_FEED"]),
                              running: running, report: { phase, message in reply(.init(phase: phase, message: message, yours: true)) })
        let installer = Installer(paths: paths)
        /// A failure the viewer can read back from the next Welcome, should this reply not reach it.
        func fail(_ message: String, target: Int?) {
            log("update asked by \(requester.name) failed: \(message)")
            let asked = MirageVersion(version: "", build: target ?? 0, commit: "", channel: nil)   // the build asked for, as far as known
            try? installer.writeResult(UpdateResult(outcome: .failed, from: running, to: asked, at: Date(), message: message))
            reply(.init(phase: .failed, message: message, from: running, to: target.map { _ in asked }, yours: true))
        }
        switch command {
        case .update(let target):
            do {
                // A remote trigger never crosses a signing-identity change: that needs a person at the Mac.
                switch try await updater.install(targetBuild: target, allowIdentityChange: false) {
                case .nothing(let d):
                    if d.endsCleanly { reply(.init(phase: .done, message: d.message, from: running, yours: true)) }
                    else { fail(d.message, target: target) }
                case .swapped(let p, _):
                    log("update \(p.from.display) → \(p.to.display) asked by \(requester.name): restarting into it")
                    await restart(into: p.to.display, from: p.from, to: p.to, verb: "an update", supervise: ["--supervise"])
                }
            } catch {
                fail("\(error)", target: target)
            }
        case .rollback:
            if requester.connectionID != nil {
                // From a viewer: only right after an update, and only to a previous build of the same signing identity.
                let change = SigningIdentity.change(from: updater.runningIdentity(), to: SigningIdentity.of(bundle: paths.previous))
                if let why = RemoteRollback.refusal(pending: installer.readPending(), lastResult: installer.readResult(), running: running,
                                                    now: Date(), identityChange: change) {
                    log("rollback asked by \(requester.name): refused (\(why))")
                    reply(.init(phase: .failed, message: why, from: running, yours: true))
                    return
                }
            }
            do {
                // A viewer's rollback never marks the newest build skipped; a person's (the CLI) does.
                let (from, to) = try updater.rollback(skipReplaced: requester.connectionID == nil)
                log("rollback \(from?.display ?? "?") → \(to?.display ?? "?") asked by \(requester.name)")
                await restart(into: to?.display ?? "its previous build", from: from, to: to, verb: "a rollback", supervise: ["--ensure-agent"])
            } catch {
                reply(.init(phase: .failed, message: "\(error)", from: running, yours: true))
            }
        }

        /// Tells the other listening viewers, then this one, and hands the restart to the supervisor.
        func restart(into name: String, from: MirageVersion?, to: MirageVersion?, verb: String, supervise: [String]) async {
            await ctx.updateListeners.broadcast(.init(phase: .restarting, message: "\(host) is restarting into \(name) (\(verb) by \(requester.name))",
                                                      from: from, to: to, yours: false), except: requester.connectionID)
            reply(.init(phase: .restarting, message: "\(host) is restarting into \(name)", from: from, to: to, yours: true))
            try? await Task.sleep(for: .milliseconds(500))   // the messages leave before the restart
            // The running binary: after the swap its bundle is the kept previous one.
            let me = paths.previous.appendingPathComponent("Contents/MacOS/miraged")
            guard FileManager.default.isExecutableFile(atPath: me.path) else {
                log("update: no previous bundle to supervise from; restarting directly"); exit(0)   // KeepAlive starts the new build
            }
            if let why = AgentControl(app: paths.app, storeRoot: paths.support).runDetached([me.path, "update"] + supervise + ["--app", paths.app.path]) {
                log("update: cannot start the supervisor (\(why)); restarting directly")
                exit(0)   // KeepAlive starts the new build, which commits or rolls itself back
            }
        }
    }
}

extension UpdateDecision {
    /// Nothing to install, and nothing wrong: up to date, or the channel has not caught up.
    var endsCleanly: Bool {
        switch self {
        case .upToDate, .channelBehind: return true
        case .available, .skipped, .incompatible: return false
        }
    }
}
