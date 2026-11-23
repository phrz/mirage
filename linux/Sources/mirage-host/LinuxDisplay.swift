import Foundation
import ArgumentParser
import MirageCore
import CMirageDesktop

/// Dynamic Resolution on Linux where there is no virtual monitor (VirtualScreen: the login and lock screens, desktops
/// other than GNOME): the screen's mode nearest a viewer's window (a monitor's own modes; GNOME's display settings,
/// temporarily), and the layout before put back when the stream ends or the viewer turns it off.
///
/// GNOME's display settings live on the session bus of whoever has the screen (the login screen's or a user's), so the
/// system service asks through `mirage-host display` run as that user.
///
/// One for the process: every streamer's requests go through one queue, in order, and only the streamer that fitted the
/// display (its owner) resizes it again or puts it back, so a second viewer, or a session started over, never saves a
/// fitted mode as the layout to return to.
final class DisplayFitter: @unchecked Sendable {
    static let shared = DisplayFitter()
    var log: @Sendable (String) -> Void = { _ in }
    private let lock = NSLock()
    private var saved: (user: SessionUser?, layout: String)?
    private var last: ControlMessage.FitDisplay?
    private var owner: ObjectIdentifier?

    private let queue = DispatchQueue(label: "mirage-display")

    /// Makes the display fit for `owner` (nil: puts it back), in the order asked, without waiting for GNOME.
    func request(_ fit: ControlMessage.FitDisplay?, owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        queue.async { self.apply(fit, owner: id) }
    }

    /// Puts the display back now (the service is stopping or restarting into an update).
    func restoreNow() { queue.sync { lock.lock(); restoreLocked(); owner = nil; lock.unlock() } }

    /// As `request`, waiting until it is done (VirtualScreen: the real monitor's mode back before a virtual one is made).
    func apply(_ fit: ControlMessage.FitDisplay?, ownerID id: ObjectIdentifier) { queue.sync { apply(fit, owner: id) } }

    private func apply(_ fit: ControlMessage.FitDisplay?, owner id: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        if let o = owner, o != id { return }   // another viewer's window sets the size
        guard let fit else { restoreLocked(); owner = nil; return }
        guard fit != last, fit.width > 0, fit.height > 0 else { return }
        owner = id
        let user = geteuid() == 0 ? SessionUser.onScreen() : nil
        if geteuid() == 0, user == nil { log("display: no graphical session to resize"); return }
        // A layout saved for a session that is gone (the login screen, before signing in) is not put back on another.
        if let s = saved, s.user != user { saved = nil }
        guard let out = run(user, ["fit", "\(fit.width)x\(fit.height)"]) else { if saved == nil { owner = nil }; return }
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return }
        last = fit
        if saved == nil { saved = (user, lines[0]) }
        log("display: \(lines[1]) for a \(fit.width)x\(fit.height) window")
    }

    private func restoreLocked() {
        last = nil
        guard let s = saved else { return }
        saved = nil
        guard geteuid() != 0 || SessionUser.onScreen() == s.user else { return }   // that session is gone, and its layout with it
        if run(s.user, ["restore", s.layout]) != nil { log("display: back as it was") }
    }

    /// `mirage-host display …` as the session's user (in this process when it is that user).
    private func run(_ user: SessionUser?, _ args: [String]) -> String? {
        let p = Process()
        if let user {
            // setpriv, not runuser: no PAM session (and its journal lines) for each change.
            p.executableURL = URL(fileURLWithPath: "/usr/bin/setpriv")
            p.arguments = ["--reuid=\(user.uid)", "--regid=\(user.gid)", "--init-groups", "--", "/usr/bin/env",
                           "HOME=\(user.home)", "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\(user.uid)/bus",
                           "XDG_RUNTIME_DIR=/run/user/\(user.uid)", LinuxUpdater.binary, "display"] + args
        } else {
            p.executableURL = URL(fileURLWithPath: LinuxUpdater.binary)
            p.arguments = ["display"] + args
        }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { log("display: \(error)"); return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            log("display: \(String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))"); return nil
        }
        return String(decoding: d, as: UTF8.self)
    }
}

/// The user whose graphical session shows on the screen (seat0's active one: GDM's greeter or a person's desktop).
struct SessionUser: Equatable {
    let name: String
    let uid: UInt32
    var gid: UInt32 { getpwuid(uid).map { $0.pointee.pw_gid } ?? uid }
    var home: String { getpwuid(uid).map { String(cString: $0.pointee.pw_dir) } ?? "/" }

    /// The signed-in desktop on the screen, unlocked: where GNOME makes remote-desktop sessions (not at GDM's login
    /// screen, nor while locked). When this process is not root, only its own user's.
    static func desktop() -> SessionUser? {
        guard let seat = TrayLauncher.run("/usr/bin/loginctl", ["show-seat", "seat0", "-p", "ActiveSession", "--value"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !seat.isEmpty,
              let props = TrayLauncher.run("/usr/bin/loginctl", ["show-session", seat, "-p", "Name", "-p", "User", "-p", "Type",
                                                                 "-p", "Class", "-p", "LockedHint"]) else { return nil }
        var p: [String: String] = [:]
        for l in props.split(separator: "\n") { let kv = l.split(separator: "=", maxSplits: 1); if kv.count == 2 { p[String(kv[0])] = String(kv[1]) } }
        guard p["Type"] == "wayland", p["Class"] == "user", p["LockedHint"] != "yes", let name = p["Name"],
              let uid = p["User"].flatMap(UInt32.init), geteuid() == 0 || geteuid() == uid else { return nil }
        return SessionUser(name: name, uid: uid)
    }

    static func onScreen() -> SessionUser? {
        guard let seat = TrayLauncher.run("/usr/bin/loginctl", ["show-seat", "seat0", "-p", "ActiveSession", "--value"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !seat.isEmpty,
              let props = TrayLauncher.run("/usr/bin/loginctl", ["show-session", seat, "-p", "Name", "-p", "User", "-p", "Type"]) else { return nil }
        var p: [String: String] = [:]
        for l in props.split(separator: "\n") { let kv = l.split(separator: "=", maxSplits: 1); if kv.count == 2 { p[String(kv[0])] = String(kv[1]) } }
        guard ["wayland", "x11"].contains(p["Type"] ?? ""), let name = p["Name"], let uid = p["User"].flatMap(UInt32.init) else { return nil }
        return SessionUser(name: name, uid: uid)
    }
}

struct Display: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Change GNOME's display mode for Dynamic Resolution (run by the host).",
                                                    shouldDisplay: false)
    @Argument(help: "fit WxH (points), or restore LAYOUT") var action: String
    @Argument var value: String

    func run() throws {
        var err = [CChar](repeating: 0, count: 512)
        switch action {
        case "fit":
            let p = value.split(separator: "x").compactMap { Int32($0) }
            guard p.count == 2 else { throw ValidationError("expected WxH") }
            var saved = [CChar](repeating: 0, count: 2048), chosen = [CChar](repeating: 0, count: 64)
            guard md_display_fit(p[0], p[1], &saved, saved.count, &chosen, chosen.count, &err, err.count) == 0 else {
                throw ValidationError(String(cString: err))
            }
            print(String(cString: saved)); print(String(cString: chosen))
        case "restore":
            guard md_display_restore(value, &err, err.count) == 0 else { throw ValidationError(String(cString: err)) }
        default:
            throw ValidationError("expected fit or restore")
        }
    }
}
