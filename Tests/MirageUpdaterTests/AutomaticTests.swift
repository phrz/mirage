import XCTest
import MirageCore
@testable import MirageUpdater

/// DESIGN §3.10 U6: the Automatic policy's quiet-moment gate and its once-per-build record; the Homebrew cask's bump.
final class AutomaticTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var auto: UpdateSettings { var s = UpdateSettings(); s.policy = .automatic; s.channel = .nightly; s.latest = ver(450); return s }
    var quiet: AutomaticUpdate.Moment { .init(streaming: 0, lastStreamEnded: now.addingTimeInterval(-3600), systemPrompt: false, idleSeconds: 3600, now: now) }

    func testAQuietMomentInstalls() {
        XCTAssertEqual(AutomaticUpdate.decide(settings: auto, running: ver(449), moment: quiet), .install(ver(450)))
        var m = quiet; m.lastStreamEnded = nil
        XCTAssertEqual(AutomaticUpdate.decide(settings: auto, running: ver(449), moment: m), .install(ver(450)), "no stream at all")
    }

    func testTheGateWaits() {
        func waits(_ s: UpdateSettings, _ m: AutomaticUpdate.Moment, _ contains: String, file: StaticString = #filePath, line: UInt = #line) {
            guard case .wait(let why) = AutomaticUpdate.decide(settings: s, running: ver(449), moment: m) else { return XCTFail("must wait", file: file, line: line) }
            XCTAssertTrue(why.contains(contains), why, file: file, line: line)
        }
        var ask = auto; ask.policy = .ask
        waits(ask, quiet, "policy is ask")
        var none = auto; none.latest = ver(449)
        waits(none, quiet, "up to date")
        var m = quiet
        m.streaming = 1; waits(auto, m, "1 viewer is streaming")
        m = quiet; m.lastStreamEnded = now.addingTimeInterval(-300); waits(auto, m, "a stream ended 300 s ago")
        m = quiet; m.systemPrompt = true; waits(auto, m, "system prompt")
        m = quiet; m.idleSeconds = 599; waits(auto, m, "used 599 s ago")
        m = quiet; m.idleSeconds = 600
        XCTAssertEqual(AutomaticUpdate.decide(settings: auto, running: ver(449), moment: m), .install(ver(450)), "10 min exactly is quiet")
        var skipped = auto; skipped.skippedBuilds = [450]
        waits(skipped, quiet, "rolled back")
    }

    /// Each build is tried once on its own: the record is written before the attempt and survives a reload; a newer build
    /// is tried again.
    func testABuildIsNotRetried() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-auto-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("updates.json")
        try auto.save(url)
        AutomaticUpdate.recordAttempt(450, settings: url)
        AutomaticUpdate.recordAttempt(450, settings: url)
        let s = UpdateSettings.load(url)
        XCTAssertEqual(s.automaticTried, [450])
        guard case .wait(let why) = AutomaticUpdate.decide(settings: s, running: ver(449), moment: quiet) else { return XCTFail() }
        XCTAssertTrue(why.contains("not again on its own"), why)
        var newer = s; newer.latest = ver(451)
        XCTAssertEqual(AutomaticUpdate.decide(settings: newer, running: ver(449), moment: quiet), .install(ver(451)))
        XCTAssertEqual(UpdateSettings.load(dir.appendingPathComponent("none.json")).automaticTried, [])
    }

    func testTheIndicatorSaysUpdating() {
        let running = ControlMessage.UpdateStatus(phase: .downloading, message: "downloading", to: ver(450))
        XCTAssertEqual(HostUpdateState.evaluate(hostVersion: ver(449), latestAvailable: ver(450), incompatibility: nil, updating: running), .updating(to: ver(450)),
                       "not an Update offer while the host installs one")
        XCTAssertEqual(HostUpdateState.evaluate(hostVersion: ver(449), latestAvailable: ver(450), incompatibility: nil,
                                                updating: .init(phase: .done, message: "")), .updateAvailable(from: ver(449), to: ver(450)))
        XCTAssertEqual(HostUpdateState.updating(to: ver(450)).note(hostName: "m"), "Updating to 0.4.0 (450)…")
    }

    /// release.sh's Homebrew step: version "VERSION,BUILD", the SHA-256 and the URL; stable and beta only.
    func testTheCaskBump() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-cask-\(UUID().uuidString).rb")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: repo.appendingPathComponent("homebrew/Casks/mirage.rb"), to: copy)
        func run(_ args: [String]) -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [repo.appendingPathComponent("scripts/release.sh").path, "cask-bump"] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit(); return p.terminationStatus
        }
        let sha = String(repeating: "ab", count: 32)
        XCTAssertEqual(run(["stable", "0.2.0", "470", sha, "https://github.com/phrz/mirage/releases/download/v0.2.0/Mirage-0.2.0-470.zip", copy.path]), 0)
        let text = try String(contentsOf: copy, encoding: .utf8)
        XCTAssertTrue(text.contains("  version \"0.2.0,470\"\n"))
        XCTAssertTrue(text.contains("  sha256 \"\(sha)\"\n"))
        XCTAssertTrue(text.contains("  url \"https://github.com/phrz/mirage/releases/download/v0.2.0/Mirage-0.2.0-470.zip\"\n"))
        XCTAssertTrue(text.contains("auto_updates true"), "never fights the updater")
        XCTAssertNotEqual(run(["nightly", "0.2.0", "470", sha, "https://x", copy.path]), 0, "nightlies never go to Homebrew")
        XCTAssertNotEqual(run(["stable", "0.2.0", "470", "nothex", "https://x", copy.path]), 0)
    }
}
