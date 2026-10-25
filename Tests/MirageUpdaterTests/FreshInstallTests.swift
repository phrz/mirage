import XCTest
import CryptoKit
import MirageCore
@testable import MirageUpdater

/// DESIGN §3.10 U5: install-host.sh's Swift half (manifest for this bundle, the plan) and fleet.sh's status line.
final class FreshInstallTests: XCTestCase {
    let key = Curve25519.Signing.PrivateKey()
    var trust: ManifestTrust { ManifestTrust(compiled: [key.publicKey.rawRepresentation.base64EncodedString()], learned: [], revoked: []) }

    func signed(_ v: MirageVersion, channel: UpdateChannel = .nightly) throws -> (Data, Data) {
        let m = Manifest(channel: channel, version: v.version, build: v.build, commit: v.commit, minProtocol: 5, protocolVersion: 6, minOS: "15.0",
                         zipURL: "z.zip", zipSHA256: "", zipSize: 0, notes: "", published: Date(), expires: Date().addingTimeInterval(86_400))
        let d = try m.encoded()
        return (d, try ManifestKey.sign(d, with: [key]))
    }

    func testTheManifestMustDescribeThisBundle() throws {
        let b = ver(449, "0.1")
        let (d, s) = try signed(b)
        XCTAssertEqual(try FreshInstall.verifyManifest(d, signatures: s, channel: .nightly, bundle: b, trust: trust).build, 449)
        XCTAssertThrowsError(try FreshInstall.verifyManifest(d, signatures: s, channel: .nightly, bundle: ver(448, "0.1"), trust: trust)) {
            XCTAssertTrue("\($0)".contains("the manifest says 0.1 (449)"), "\($0)")
        }
        var other = b; other.commit = "evil"
        XCTAssertThrowsError(try FreshInstall.verifyManifest(d, signatures: s, channel: .nightly, bundle: other, trust: trust), "same build, another commit")
        XCTAssertThrowsError(try FreshInstall.verifyManifest(d, signatures: s, channel: .stable, bundle: b, trust: trust), "another channel's head")
        XCTAssertThrowsError(try FreshInstall.verifyManifest(d, signatures: s, channel: .nightly, bundle: b, trust: ManifestTrust(compiled: [], learned: [], revoked: [])),
                             "a build that trusts no key installs nothing")
        let stranger = Curve25519.Signing.PrivateKey()
        XCTAssertThrowsError(try FreshInstall.verifyManifest(d, signatures: try ManifestKey.sign(d, with: [stranger]), channel: .nightly, bundle: b, trust: trust))
    }

    func testThePlan() {
        let devID = SigningIdentity(app: "a-devid", host: "h-devid"), dev = SigningIdentity(app: "a-dev", host: "h-dev")
        let new = ver(449, "0.1")
        XCTAssertEqual(InstallPlan.decide(installed: nil, installedIdentity: nil, new: new, newIdentity: devID, force: false, allowIdentityChange: false), .fresh)
        XCTAssertEqual(InstallPlan.decide(installed: ver(440), installedIdentity: devID, new: new, newIdentity: devID, force: false, allowIdentityChange: false), .replace(from: ver(440)))
        XCTAssertEqual(InstallPlan.decide(installed: ver(449), installedIdentity: devID, new: new, newIdentity: devID, force: false, allowIdentityChange: false), .current(ver(449)))
        XCTAssertEqual(InstallPlan.decide(installed: ver(460), installedIdentity: devID, new: new, newIdentity: devID, force: false, allowIdentityChange: false), .current(ver(460)),
                       "never a downgrade unless forced")
        XCTAssertEqual(InstallPlan.decide(installed: ver(449), installedIdentity: devID, new: new, newIdentity: devID, force: true, allowIdentityChange: false), .replace(from: ver(449)))
        guard case .refuse(let why) = InstallPlan.decide(installed: ver(440), installedIdentity: dev, new: new, newIdentity: devID, force: true, allowIdentityChange: false) else {
            return XCTFail("an identity change is refused, even forced")
        }
        XCTAssertTrue(why.contains("--allow-identity-change"))
        XCTAssertEqual(InstallPlan.decide(installed: ver(440), installedIdentity: dev, new: new, newIdentity: devID, force: false, allowIdentityChange: true), .replace(from: ver(440)))
    }

    func testFleetStatusLine() {
        var s = UpdateSettings(); s.channel = .nightly; s.latest = ver(450)
        let up = FleetStatus.line(host: "mac-daddy", running: ver(449, "0.1"), settings: s, agent: .running(pid: 7, program: nil),
                                  streaming: [], grants: .init(screenRecording: true, accessibility: true))
        XCTAssertEqual(up, "mac-daddy  0.1 (449) nightly  latest 450  agent running  streaming no  grants ok  policy ask  trigger any-device")
        s.latest = ver(449); s.trigger = .thisMac
        let line = FleetStatus.line(host: "mini", running: ver(449, "0.1"), settings: s, agent: .spawnFailed("x"),
                                    streaming: ["phrz's iPhone"], grants: .init(screenRecording: false, accessibility: true))
        XCTAssertEqual(line, "mini  0.1 (449) nightly  latest 449 (current)  agent SPAWN FAILED  streaming phrz's iPhone  grants MISSING screen  policy ask  trigger this-mac")
        var u = UpdateSettings(); u.lastCheckError = "feed: HTTP 404"
        XCTAssertTrue(FleetStatus.line(host: "x", running: ver(1), settings: u, agent: .notLoaded, streaming: nil, grants: nil)
            .contains("latest ? (check failed)  agent not registered  streaming ?  grants ?"))
    }
}
