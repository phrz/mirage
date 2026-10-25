import Foundation
import MirageCore
import MirageUpdater

/// The host agent's updater for triggers (DESIGN §3.10, U4): a paired viewer's `updateHost`/`rollbackHost`, or this Mac's
/// menu bar and window bar over local control. The same `Updater` as `miraged update`, run in the agent; after the swap,
/// a one-shot job in the gui launchd domain runs `miraged update --supervise`, which restarts the agent onto the new build
/// and watches it start (registering it again, or rolling back, as from SSH). That job outlives the agent it restarts.
func makeUpdateHandler(paths: InstallPaths, ctx: HostContext, log: @escaping @Sendable (String) -> Void) -> HostUpdateHandler {
    { command, requester, reply in
        let host = ctx.identity.name
        let updater = Updater(paths: paths, feed: Feed(override: ProcessInfo.processInfo.environment["MIRAGE_UPDATE_FEED"]),
                              running: Installer.version(of: paths.app) ?? .current,
                              report: { phase, message in reply(.init(phase: phase, message: message, yours: true)) })
        let supervisor = paths.app.appendingPathComponent("Contents/MacOS/miraged").path
        switch command {
        case .update(let target):
            do {
                // A remote trigger never crosses a signing-identity change: that needs a person at the Mac.
                switch try await updater.install(targetBuild: target, allowIdentityChange: false) {
                case .nothing(let d):
                    reply(.init(phase: d.endsCleanly ? .done : .failed, message: d.message, from: updater.running, yours: true))
                case .swapped(let p, _):
                    log("update \(p.from.display) → \(p.to.display) asked by \(requester.name): restarting into it")
                    await ctx.updateListeners.broadcast(.init(phase: .restarting, message: "\(host) is restarting into \(p.to.display) (an update from \(requester.name))",
                                                              from: p.from, to: p.to, yours: false), except: requester.connectionID)
                    reply(.init(phase: .restarting, message: "\(host) is restarting into \(p.to.display)", from: p.from, to: p.to, yours: true))
                    try? await Task.sleep(for: .milliseconds(500))   // the messages leave before the restart
                    if let why = AgentControl(app: paths.app, storeRoot: paths.support).runDetached([supervisor, "update", "--supervise", "--app", paths.app.path]) {
                        log("update: cannot start the supervisor (\(why)); restarting directly")
                        exit(0)   // KeepAlive starts the new build, which commits or rolls itself back
                    }
                }
            } catch {
                log("update asked by \(requester.name) failed: \(error)")
                reply(.init(phase: .failed, message: "\(error)", from: updater.running, yours: true))
            }
        case .rollback:
            do {
                let (from, to) = try updater.rollback()
                log("rollback \(from?.display ?? "?") → \(to?.display ?? "?") asked by \(requester.name)")
                await ctx.updateListeners.broadcast(.init(phase: .restarting, message: "\(host) is restarting into \(to?.display ?? "its previous build") (a rollback by \(requester.name))",
                                                          from: from, to: to, yours: false), except: requester.connectionID)
                reply(.init(phase: .restarting, message: "\(host) is restarting into \(to?.display ?? "its previous build")", from: from, to: to, yours: true))
                try? await Task.sleep(for: .milliseconds(500))
                if AgentControl(app: paths.app, storeRoot: paths.support).runDetached([supervisor, "update", "--ensure-agent", "--app", paths.app.path]) != nil { exit(0) }
            } catch {
                reply(.init(phase: .failed, message: "\(error)", yours: true))
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
