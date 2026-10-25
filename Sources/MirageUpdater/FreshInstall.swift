import Foundation
import MirageCore

/// First install on a Mac (DESIGN §3.10, U5: scripts/install-host.sh). The script checks the downloaded bundle with the
/// system's own tools (digest, the pinned code requirement, Gatekeeper's notarization assessment) before it runs
/// anything from it; then the bundle's own miraged, now known to be genuine, verifies the manifest against the keys it
/// was built with and installs itself through this logic.
public enum FreshInstall {
    /// The manifest, verified with the compiled keys only (a new Mac has learned none), for this channel, and describing
    /// exactly this bundle.
    public static func verifyManifest(_ manifest: Data, signatures: Data, channel: UpdateChannel?, bundle: MirageVersion,
                                      trust: ManifestTrust = ManifestTrust(), now: Date = Date()) throws -> Manifest {
        let v: VerifiedManifest
        do { v = try ManifestVerifier.verify(manifest: manifest, signatures: signatures, trust: trust, channel: channel, now: now) }
        catch let e as ManifestError { throw UpdateError.manifest(e) }
        let m = v.manifest.mirageVersion
        guard m.version == bundle.version, m.build == bundle.build, m.commit == bundle.commit else {
            throw UpdateError.verification("the bundle is \(bundle.display) \(bundle.commit), the manifest says \(m.display) \(m.commit)")
        }
        return v.manifest
    }
}

/// What installing a verified bundle at /Applications/Mirage.app means here.
public enum InstallPlan: Equatable, Sendable {
    /// Nothing installed yet.
    case fresh
    /// An older build of the same identity: swapped in (the old one kept as the previous bundle).
    case replace(from: MirageVersion)
    /// This build or a newer one is installed: nothing to do (`--force` reinstalls).
    case current(MirageVersion)
    case refuse(String)

    public static func decide(installed: MirageVersion?, installedIdentity: SigningIdentity?, new: MirageVersion, newIdentity: SigningIdentity,
                              force: Bool, allowIdentityChange: Bool) -> InstallPlan {
        guard let installed else { return .fresh }
        if let id = installedIdentity, let change = SigningIdentity.change(from: id, to: newIdentity), !allowIdentityChange {
            return .refuse("\(change). The grants and the agent registration need a person at this Mac: run install-host.sh here with --allow-identity-change")
        }
        if installed.build >= new.build, !force {
            return .current(installed)
        }
        return .replace(from: installed)
    }

    public var description: String {
        switch self {
        case .fresh: return "install"
        case .replace(let f): return "replace \(f.display)"
        case .current(let v): return "already installed: \(v.display)"
        case .refuse(let why): return "refused: \(why)"
        }
    }
}

/// One line per host for scripts/fleet.sh (DESIGN §3.10):
/// `mac-daddy  0.4.0 (412) nightly  latest 420  agent running  streaming no  grants ok  policy ask  trigger any-device`.
public enum FleetStatus {
    public struct Grants: Equatable, Sendable {
        public var screenRecording: Bool?
        public var accessibility: Bool?
        public init(screenRecording: Bool?, accessibility: Bool?) { self.screenRecording = screenRecording; self.accessibility = accessibility }
    }

    public static func line(host: String, running: MirageVersion, settings: UpdateSettings, agent: AgentStatus,
                            streaming: [String]?, grants: Grants?) -> String {
        let latest: String
        if let l = settings.latest { latest = l.build > running.build ? "latest \(l.build)" : "latest \(l.build) (current)" }
        else { latest = settings.lastCheckError != nil ? "latest ? (check failed)" : "latest ?" }
        let agentText: String
        switch agent {
        case .running: agentText = "agent running"
        case .spawnFailed: agentText = "agent SPAWN FAILED"
        case .notLoaded: agentText = "agent not registered"
        case .notRunning: agentText = "agent not running"
        }
        let stream = streaming.map { $0.isEmpty ? "streaming no" : "streaming \($0.joined(separator: ","))" } ?? "streaming ?"
        let g: String
        if let grants, let s = grants.screenRecording, let a = grants.accessibility {
            g = s && a ? "grants ok" : "grants MISSING \([s ? nil : "screen", a ? nil : "accessibility"].compactMap { $0 }.joined(separator: "+"))"
        } else { g = "grants ?" }
        return [host, "\(running.display) \(running.channelName)", latest, agentText, stream, g,
                "policy \(settings.policy.rawValue)", "trigger \(settings.trigger.rawValue)"].joined(separator: "  ")
    }
}
