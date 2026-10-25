import Foundation
import Security
import MirageCore

/// Checks a staged bundle before anything is replaced (DESIGN §3.10, verification steps 3–5). A protocol so the swap and
/// rollback can be exercised on throwaway bundles in tests; the host always uses `SystemBundleVerifier`.
public protocol BundleVerifying: Sendable {
    func verify(app: URL, expected: MirageVersion) throws
}

/// The code-signing requirements pinned in the running binary: Apple-anchored, this identifier, team M8MME6Q9DA.
public enum PinnedRequirement {
    public static let team = "M8MME6Q9DA"
    public static let app = #"anchor apple generic and identifier "com.paulherz.mirage" and certificate leaf[subject.OU] = "M8MME6Q9DA""#
    public static let host = #"anchor apple generic and identifier "com.paulherz.mirage.host" and certificate leaf[subject.OU] = "M8MME6Q9DA""#
}

public struct SystemBundleVerifier: BundleVerifying {
    public init() {}

    public func verify(app: URL, expected: MirageVersion) throws {
        let host = app.appendingPathComponent("Contents/MacOS/miraged")
        try Self.checkSignature(app, requirement: PinnedRequirement.app)
        try Self.checkSignature(host, requirement: PinnedRequirement.host)
        try Self.checkNotarized(app)
        try Self.selfTest(host, expected: expected)
    }

    /// Step 3: `SecStaticCodeCheckValidity` with all architectures and strict validation, against the pinned requirement.
    public static func checkSignature(_ url: URL, requirement: String) throws {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code)
        guard status == errSecSuccess, let code else { throw UpdateError.verification("\(url.lastPathComponent): no code signature (\(status))") }
        var req: SecRequirement?
        status = SecRequirementCreateWithString(requirement as CFString, SecCSFlags(), &req)
        guard status == errSecSuccess, let req else { throw UpdateError.verification("bad pinned requirement (\(status))") }
        var err: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        status = SecStaticCodeCheckValidityWithErrors(code, flags, req, &err)
        guard status == errSecSuccess else {
            let why = err?.takeRetainedValue().localizedDescription ?? "status \(status)"
            throw UpdateError.verification("\(url.lastPathComponent) does not satisfy \(requirement): \(why)")
        }
    }

    /// Step 4: notarization. The design names `SecAssessmentCreate`, but this SDK (Xcode 27.1) no longer ships its header,
    /// so calling it would mean declaring an unpublished symbol ourselves. Instead, both public: the code-signing
    /// requirement `notarized` (the stapled ticket, checked by Security), and Gatekeeper's own assessment for execution
    /// through `spctl` (present on every Mac), which must report a notarized Developer ID source.
    public static func checkNotarized(_ app: URL) throws {
        let ticket = app.appendingPathComponent("Contents/CodeResources")
        guard FileManager.default.fileExists(atPath: ticket.path) else {
            throw UpdateError.verification("\(app.lastPathComponent) has no stapled notarization ticket")
        }
        try checkSignature(app, requirement: "notarized")
        let (out, code, _) = run(URL(fileURLWithPath: "/usr/sbin/spctl"), ["--assess", "--type", "execute", "-vv", app.path], timeout: 60)
        guard code == 0, out.contains("source=Notarized Developer ID") else {
            throw UpdateError.verification("Gatekeeper rejects \(app.lastPathComponent): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Step 5: `miraged --self-test` must exit 0 within 10 s and print the manifest's version.
    public static func selfTest(_ host: URL, expected: MirageVersion) throws {
        let (out, code, timedOut) = run(host, ["--self-test"], timeout: SelfTest.timeout)
        if let why = SelfTest.judge(output: out, exitCode: code, timedOut: timedOut, expected: expected) {
            throw UpdateError.verification(why)
        }
    }

    /// Runs a tool, its output (stdout and stderr) and exit status; kills it at the timeout.
    public static func run(_ tool: URL, _ args: [String], timeout: TimeInterval) -> (String, Int32?, Bool) {
        let p = Process(); p.executableURL = tool; p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return ("\(error)", nil, false) }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut { timedOut = true; p.terminate(); _ = done.wait(timeout: .now() + 2) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(decoding: data, as: UTF8.self), timedOut ? nil : p.terminationStatus, timedOut)
    }
}
