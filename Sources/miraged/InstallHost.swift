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
                   assignments: [String], force: Bool, allowIdentityChange: Bool, dryRun: Bool,
                   afterSwap: (PendingUpdate, InstallPaths, Bool) async throws -> Void) async throws {
    if let why = InstallUser.refusal(uid: getuid(), user: NSUserName(), consoleUser: InstallUser.consoleUser()) { throw UpdateError.refused(why) }
    guard let version = Installer.version(of: bundle) else { throw UpdateError.install("\(bundle.path) is not a Mirage bundle") }
    let m = try FreshInstall.verifyManifest(try Data(contentsOf: manifest), signatures: try Data(contentsOf: sigs), channel: channel, bundle: version)
    print("manifest: \(m.channel.rawValue) \(m.mirageVersion.display), signed by a key this build trusts")
    try SystemBundleVerifier().verify(app: bundle, expected: version)
    print("bundle: Developer ID team \(PinnedRequirement.team), notarized, self-test ok")

    let paths = InstallPaths(app: appPath, support: store.root)
    let installer = BundleInstaller(paths: paths, agent: SystemInstallAgent(app: appPath, storeRoot: store.root))
    let plan = try await installer.install(bundle: bundle, version: version, manifestChannel: m.channel, assignments: assignments, force: force,
                                           allowIdentityChange: allowIdentityChange, dryRun: dryRun,
                                           afterSwap: { p, changed in try await afterSwap(p, paths, changed) })
    if dryRun { return }
    if case .fresh = plan {} else if case .replace = plan {} else { return }
    print("")
    print(SigningIdentity.tccSteps())
    print("Then pair a device: Pair a Device… in Mirage's menu bar, or `\(appPath.path)/Contents/MacOS/miraged pair`.")
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
