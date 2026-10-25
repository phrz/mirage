import Foundation
import ArgumentParser
import MirageCore
import MirageUpdater

/// `miraged update --install-bundle PATH --manifest M --sigs S` (U5): the second half of scripts/install-host.sh, run
/// from the downloaded bundle once the script has checked it with the system's tools. Verifies the manifest with this
/// build's compiled keys and that it describes this bundle, checks the bundle again as the updater does, decides
/// (fresh, replace, current, refuse: never a silent signing-identity change), installs at the app path, applies the
/// settings, turns the host on, and prints the grant steps.
func MirageUpdate_installBundle(_ bundle: URL, manifest: URL, sigs: URL, channel: UpdateChannel?, appPath: URL, store: Store,
                   assignments: [String], force: Bool, allowIdentityChange: Bool, dryRun: Bool) async throws {
    guard let version = Installer.version(of: bundle) else { throw UpdateError.install("\(bundle.path) is not a Mirage bundle") }
    let m = try FreshInstall.verifyManifest(try Data(contentsOf: manifest), signatures: try Data(contentsOf: sigs), channel: channel, bundle: version)
    print("manifest: \(m.channel.rawValue) \(m.mirageVersion.display), signed by a key this build trusts")
    try SystemBundleVerifier().verify(app: bundle, expected: version)
    print("bundle: Developer ID team \(PinnedRequirement.team), notarized, self-test ok")

    let paths = InstallPaths(app: appPath, support: store.root)
    let installed = Installer.version(of: appPath)
    let plan = InstallPlan.decide(installed: installed, installedIdentity: installed != nil ? SigningIdentity.of(bundle: appPath) : nil,
                                  new: version, newIdentity: SigningIdentity.of(bundle: bundle), force: force, allowIdentityChange: allowIdentityChange)
    print("plan: \(plan.description) → \(appPath.path)")
    var settings = UpdateSettings.load(paths.settings)
    if !assignments.contains(where: { $0.lowercased().hasPrefix("channel") }) { try settings.apply("channel=\(m.channel.rawValue)") }
    for a in assignments { try settings.apply(a) }
    print("settings: channel \(settings.channel.rawValue), policy \(settings.policy.rawValue), trigger \(settings.trigger.rawValue)")
    if case .refuse(let why) = plan { print("error: \(why)"); throw ExitCode(1) }
    if dryRun { print("dry run: nothing changed"); return }
    try settings.save(paths.settings)
    if case .current = plan { print("nothing to install"); return }

    // Staged beside the app path (same volume), then one rename: fresh, or the swap that keeps the old as the previous one.
    let staged = appPath.deletingLastPathComponent().appendingPathComponent(".Mirage-staged.app", isDirectory: true)
    try? FileManager.default.removeItem(at: staged)
    let copy = SystemBundleVerifier.run(URL(fileURLWithPath: "/usr/bin/ditto"), [bundle.path, staged.path], timeout: 300)
    guard copy.1 == 0 else { throw UpdateError.install("copying to \(staged.path): \(copy.0)") }
    let agent = AgentControl(app: appPath, storeRoot: store.root)
    switch plan {
    case .fresh:
        guard rename(staged.path, appPath.path) == 0 else { throw UpdateError.install("installing \(appPath.path): \(String(cString: strerror(errno)))") }
        print("installed \(version.display) at \(appPath.path)")
        let (v, how) = agent.allowConnections()
        print("host: \(how)")
        report(v)
    case .replace(let from):
        try Installer(paths: paths).swapIn(staged)
        print("replaced \(from.display) with \(version.display) (the old build is kept as the previous one)")
        report(agent.belongsToApp() ? agent.ensureRunning(restart: true, log: { print($0) }) : agent.allowConnections().0)
    case .current, .refuse: break
    }
    print("")
    print(SigningIdentity.tccSteps())
    print("Then pair a device: Pair a Device… in Mirage's menu bar, or `\(appPath.path)/Contents/MacOS/miraged pair`.")

    func report(_ v: AgentWatch.Verdict) {
        switch v {
        case .started: print("host agent: running")
        case .cannotSpawn(let why): print("host agent: not running (\(why))")
        case .keepWaiting: break
        }
    }
}

/// `miraged update --status-line` (U5, scripts/fleet.sh): this Mac in one line.
func MirageUpdate_statusLine(paths: InstallPaths, store: Store) -> String {
    let running = Installer.version(of: paths.app) ?? .current
    var streaming: [String]?
    var grants: FleetStatus.Grants?
    // The host's own view, over local control, when it answers within 2 s.
    let client = LocalControlClient(store: store)
    let got = DispatchSemaphore(value: 0)
    let lock = NSLock(); var status: LocalControl.Status?
    client.onEvent = { e in if case .status(let s) = e { lock.lock(); if status == nil { status = s; got.signal() }; lock.unlock() } }
    if (try? client.connect(client: "miraged update --status-line")) != nil {
        try? client.send(.status)
        if got.wait(timeout: .now() + 2) == .success, let s = (lock.withLock { status }) {
            streaming = s.connected ?? []
            grants = .init(screenRecording: s.screenRecording, accessibility: s.accessibility)
        }
        client.disconnect()
    }
    return FleetStatus.line(host: DeviceNames.current(), running: running, settings: UpdateSettings.load(paths.settings),
                            agent: HostAgent.currentStatus(), streaming: streaming, grants: grants)
}
