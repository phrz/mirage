import AppKit
import SwiftUI
import MirageCore

/// The host's permissions, as one assistant window (DESIGN §3.7a; phrz, 2026-10-27: on a new host "all the permissions
/// requests just pop up unbridled"). The grants belong to the embedded host (`miraged`), which never asks by itself: a
/// row's Allow asks it over the local control socket to raise the system's request for itself, the first time; after
/// that macOS shows no sheet, so Allow opens the exact pane in System Settings. Rows turn to a checkmark as the host
/// reports each grant. The pairing code shows here too while a pairing window is open.
@MainActor
final class PermissionsModel: ObservableObject {
    struct Grant: Identifiable, Equatable {
        var id: String          // "screenRecording", "accessibility"
        var title: String
        var why: String
        var symbol: String
        var granted: Bool
    }
    @Published var screenRecording: Bool?
    @Published var accessibility: Bool?
    @Published var restarting = false
    @Published var pairingCode: String?
    /// Why it is up now, when someone caused it ("iPhone tried to connect…").
    @Published var reason: String?
    var asked: Set<String> = []

    var grants: [Grant] {
        [Grant(id: "screenRecording", title: PrivacyPane.screenRecording, why: "So your other devices can see this Mac's screen.",
               symbol: "rectangle.dashed.badge.record", granted: screenRecording ?? false),
         Grant(id: "accessibility", title: PrivacyPane.accessibility(), why: "So your other devices can use this Mac's pointer and keyboard.",
               symbol: "hand.point.up.left", granted: accessibility ?? false)]
    }
    var allGranted: Bool { screenRecording == true && accessibility == true }
    var missingCount: Int { grants.filter { !$0.granted }.count }

    /// The first line under the title.
    var headline: String {
        switch missingCount {
        case 0: return "This Mac is ready. Your paired devices can connect."
        case 1: return "Mirage needs one more permission to share this Mac."
        default: return "Mirage needs two permissions to share this Mac."
        }
    }

    /// The pane's own address in System Settings.
    static func settingsURL(_ id: String) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(id == "screenRecording" ? "Privacy_ScreenCapture" : "Privacy_Accessibility")")!
    }

    /// What Allow does: the host's request the first time (macOS shows its sheet then), System Settings after that.
    enum AllowAction: Equatable { case request, openSettings }
    static func allowAction(for id: String, asked: Set<String>) -> AllowAction { asked.contains(id) ? .openSettings : .request }

    var request: (String) -> Void = { _ in }
    var openSettings: (URL) -> Void = { NSWorkspace.shared.open($0) }
    func allow(_ id: String) {
        switch Self.allowAction(for: id, asked: asked) {
        case .request: asked.insert(id); request(id)
        case .openSettings: openSettings(Self.settingsURL(id))   // only Settings: the host asks once
        }
    }

    func apply(_ s: LocalControl.Status) {
        screenRecording = s.screenRecording
        accessibility = s.accessibility
        restarting = s.restarting == true
        asked.formUnion(s.permissionsAsked ?? [])
        if s.pairingOpen == false { pairingCode = nil }
    }
}

struct PermissionsView: View {
    @ObservedObject var model: PermissionsModel
    var onDone: () -> Void
    var onLater: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage()).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow Mirage to Share This Mac").font(.title2).fontWeight(.semibold)
                    Text(model.headline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let r = model.reason, !model.allGranted { Text(r).fixedSize(horizontal: false, vertical: true) }
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(model.grants.enumerated()), id: \.element.id) { i, g in
                    if i > 0 { Divider().padding(.leading, 44) }
                    row(g)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
            if let code = model.pairingCode {
                HStack {
                    Text("Pairing code").foregroundStyle(.secondary)
                    Spacer()
                    Text(code).font(.system(.title3, design: .monospaced)).fontWeight(.semibold)
                }
            }
            Text("Once a month macOS asks whether Mirage may keep recording this screen without the screen picker. Choose Allow so your devices can keep connecting.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(model.allGranted ? "Done" : "Later", action: model.allGranted ? onDone : onLater)
                    .keyboardShortcut(model.allGranted ? .defaultAction : .cancelAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ g: PermissionsModel.Grant) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: g.symbol).font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.title).fontWeight(.medium)
                Text(g.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if g.granted {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green)
                    .accessibilityLabel("Allowed")
            } else if model.restarting {
                ProgressView().controlSize(.small)
            } else {
                Button("Allow") { model.allow(g.id) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// The window around it: one, titled, closable, not resizable; it closes by itself a moment after both grants arrive.
@MainActor
final class PermissionsWindow: NSObject, NSWindowDelegate {
    let model = PermissionsModel()
    private(set) var window: NSWindow?
    /// Later (persisted by the host: HostSettings.permissionsSnoozed).
    var onLater: () -> Void = {}
    /// The person closed it (Later, or the close button) this launch: only a host's request shows it again.
    private(set) var dismissed = false
    private var closing: DispatchWorkItem?

    func show(activate: Bool = true) {
        dismissed = false
        makeWindow()
        if activate { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Mirage"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentViewController = NSHostingController(rootView: PermissionsView(model: model, onDone: { [weak self] in self?.close() },
                                                                                    onLater: { [weak self] in self?.onLater(); self?.close() }))
            w.center()
            window = w
        }
    }

    var isVisible: Bool { window?.isVisible == true }

    /// New state from the host: once both grants are in, it closes a moment later.
    func update(_ s: LocalControl.Status) {
        model.apply(s)
        if model.allGranted, isVisible, closing == nil {
            let item = DispatchWorkItem { [weak self] in self?.close() }
            closing = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: item)
        } else if !model.allGranted { closing?.cancel(); closing = nil }
    }

    func close() { window?.close() }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            closing?.cancel(); closing = nil
            if !model.allGranted { dismissed = true }
        }
    }

    /// When the host's status brings the window up by itself (a launch, a status): a grant missing, this Mac shared, Later
    /// not chosen (HostSettings.permissionsSnoozed), the window not up and not closed this launch. The rest (a pairing, a
    /// refused connection, a revocation, Share This Mac turned on) come as the host's request or the switch.
    nonisolated static func shouldShow(_ s: LocalControl.Status, visible: Bool, dismissed: Bool) -> Bool {
        guard !visible, !dismissed, s.restarting != true, s.hostSettings?.shareThisMac != false, s.hostSettings?.permissionsSnoozed != true else { return false }
        return s.screenRecording == false || s.accessibility == false
    }

    /// Whether a request (the host's, or the switch) may bring it up: never while this Mac is not shared.
    nonisolated static func mayShowOnRequest(_ s: LocalControl.Status?) -> Bool {
        guard let s else { return true }
        return s.hostSettings?.shareThisMac != false && (s.screenRecording == false || s.accessibility == false)
    }

    /// `Mirage.app --render-permissions PATH screenRecording=1 accessibility=0`: the window in a sample state, drawn to a PNG
    /// (no screen capture involved), for screenshots.
    static func render(to path: String, screenRecording: Bool, accessibility: Bool) -> Bool {
        let p = PermissionsWindow()
        var s = LocalControl.Status(hostName: "this Mac", pairedDevices: 0, pairingOpen: false, screenRecording: screenRecording, accessibility: accessibility)
        s.permissionsAsked = nil
        p.model.apply(s)
        p.makeWindow()   // never put on screen: drawn offscreen
        guard let w = p.window, let frame = w.contentView?.superview else { return false }
        w.layoutIfNeeded(); w.setContentSize(w.contentView?.fittingSize ?? w.frame.size); w.displayIfNeeded()
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return false }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        p.close()
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}

/// Share This Mac, for the Settings window's switch (the menu has its own item): HostMenu keeps it and acts on it.
@MainActor
final class HostShareState: ObservableObject {
    static let shared = HostShareState()
    /// nil: this copy has no host, or it is not known yet.
    @Published var sharing: Bool?
    var set: (Bool) -> Void = { _ in }
}

/// The Settings window's "This Mac" section.
struct ShareThisMacSection: View {
    @ObservedObject var state = HostShareState.shared
    var body: some View {
        if let on = state.sharing {
            Section {
                Toggle("Share This Mac", isOn: Binding(get: { on }, set: { state.set($0) }))
            } header: {
                Text("This Mac")
            } footer: {
                Text("Your other devices can see and use this Mac. Off, Mirage only keeps itself up to date here.")
            }
        }
    }
}
