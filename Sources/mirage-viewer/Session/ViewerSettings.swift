import Foundation
import SwiftUI
import MirageCore

/// The viewer's settings as kept in UserDefaults (iOS settings sheet, Mac Settings window).
/// - The bitrate cap persists (0 or absent = automatic). A `-bitrate N` launch argument (simctl, scripts) overrides it for
///   that launch.
/// - The network throttle is for testing: it lasts until the app quits unless the person pins it, and only a pinned one
///   comes back at the next launch. The custom profile's numbers are kept either way (they are not a throttle by themselves).
enum ViewerSettings {
    static let bitrateKey = "bitrateCapKbps"
    static let throttleKey = "pinnedThrottle"
    static let customThrottleKey = "customThrottle"
    static let showStatsKey = "showStatsOnConnect"
    static let startAtOneToOneKey = "startAtOneToOne"
    static let keyAccessoryKey = "keyboardAccessoryRow"

    /// The caps offered besides Automatic, kbit/s.
    static let capChoices = [300, 500, 800, 1_000, 2_000, 5_000, 10_000, 20_000, 50_000]

    static func bitrate(_ d: UserDefaults = .standard) -> Int {
        if let launch = d.volatileDomain(forName: UserDefaults.argumentDomain)["bitrate"] { return (launch as? Int) ?? Int("\(launch)") ?? 0 }
        return max(0, d.integer(forKey: bitrateKey))
    }
    static func setBitrate(_ kbps: Int, _ d: UserDefaults = .standard) { if kbps > 0 { d.set(kbps, forKey: bitrateKey) } else { d.removeObject(forKey: bitrateKey) } }

    /// The pinned throttle, if any (what a launch starts with).
    static func pinnedThrottle(_ d: UserDefaults = .standard) -> NetworkThrottle? {
        d.data(forKey: throttleKey).flatMap { try? JSONDecoder().decode(NetworkThrottle.self, from: $0) }
    }
    static func pin(_ t: NetworkThrottle?, _ d: UserDefaults = .standard) {
        if let t, let data = try? JSONEncoder().encode(t) { d.set(data, forKey: throttleKey) } else { d.removeObject(forKey: throttleKey) }
    }
    static func customThrottle(_ d: UserDefaults = .standard) -> NetworkThrottle {
        d.data(forKey: customThrottleKey).flatMap { try? JSONDecoder().decode(NetworkThrottle.self, from: $0) }
            ?? NetworkThrottle(name: NetworkThrottle.customName, downKbps: 1000, upKbps: 500, rttMs: 300, lossPercent: 1)
    }
    static func setCustomThrottle(_ t: NetworkThrottle, _ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(t) { d.set(data, forKey: customThrottleKey) }
    }

    static func formatCap(_ kbps: Int) -> String {
        kbps <= 0 ? "Automatic" : kbps >= 1000 ? String(format: "%g Mbps", Double(kbps) / 1000) : "\(kbps) kbps"
    }

    /// This app's version and build ("0.1 (1), built 2026-10-21 14:03Z").
    static var appBuild: String { BuildInfo.current }
}

/// The app-wide connection preferences the settings screens edit: the bitrate cap and the network throttle. A change
/// applies to the session that is connected (a new stream request; the throttle's upstream at once) and to every later
/// one. One instance per app.
@MainActor
final class ViewerPreferences: ObservableObject {
    static let shared = ViewerPreferences()

    /// kbit/s, 0 = automatic. Persisted.
    @Published var bitrateKbps: Int { didSet { guard bitrateKbps != oldValue else { return }; ViewerSettings.setBitrate(bitrateKbps); session?.setBitrate(bitrateKbps) } }
    /// nil = the real link. Persisted only while pinned.
    @Published var throttle: NetworkThrottle? { didSet { guard throttle != oldValue else { return }; if pinned { ViewerSettings.pin(throttle) }; session?.setThrottle(throttle) } }
    /// Keep the throttle after a relaunch.
    @Published var pinned: Bool { didSet { ViewerSettings.pin(pinned ? throttle : nil) } }
    /// The custom profile's numbers (kept; they only throttle while Custom is chosen).
    @Published var custom: NetworkThrottle { didSet { ViewerSettings.setCustomThrottle(custom); if throttle?.name == NetworkThrottle.customName { throttle = custom } } }

    /// The connected session, which the changes go to.
    weak var session: ViewerSession?

    init(defaults d: UserDefaults = .standard) {
        bitrateKbps = ViewerSettings.bitrate(d)
        let pinnedThrottle = ViewerSettings.pinnedThrottle(d)
        throttle = pinnedThrottle; pinned = pinnedThrottle != nil
        custom = ViewerSettings.customThrottle(d)
        // Test hook: `-throttle "Slow 4G"` as a launch argument (simctl) throttles this launch only.
        if let name = d.volatileDomain(forName: UserDefaults.argumentDomain)["throttle"] as? String {
            throttle = NetworkThrottle.presets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// The picker's choice: "" = off, a preset's name, or Custom.
    var throttleChoice: String {
        get { throttle?.name ?? "" }
        set {
            if newValue.isEmpty { throttle = nil }
            else if newValue == NetworkThrottle.customName { throttle = custom }
            else { throttle = NetworkThrottle.presets.first { $0.name == newValue } }
        }
    }
}

/// The Connection settings, shared by the iOS sheet and the Mac Settings window: the bitrate cap, and the network throttle
/// under a Developer disclosure (off by default; for testing, not kept after a relaunch unless pinned).
struct ConnectionSettingsSection: View {
    @ObservedObject var prefs: ViewerPreferences
    @State private var developerOpen: Bool

    init(prefs: ViewerPreferences) {
        self.prefs = prefs
        _developerOpen = State(initialValue: prefs.throttle != nil)
    }

    var body: some View {
        Section {
            Picker("Bitrate Cap", selection: $prefs.bitrateKbps) {
                Text("Automatic").tag(0)
                ForEach(ViewerSettings.capChoices, id: \.self) { Text(ViewerSettings.formatCap($0)).tag($0) }
            }
            DisclosureGroup("Developer", isExpanded: $developerOpen) {
                #if os(iOS)
                // A page of its own (as Settings does), pushed by the sheet's NavigationStack.
                NavigationLink(value: ThrottlePicker.route) {
                    LabeledContent("Network Throttle", value: prefs.throttle?.name ?? "Off")
                }
                #else
                Picker("Network Throttle", selection: Binding(get: { prefs.throttleChoice }, set: { prefs.throttleChoice = $0 })) {
                    Text("Off").tag("")
                    ForEach(NetworkThrottle.presets, id: \.name) { p in
                        throttleRow(p.name, p.summary).tag(p.name)
                    }
                    throttleRow(NetworkThrottle.customName, prefs.custom.summary).tag(NetworkThrottle.customName)
                }
                if prefs.throttle?.name == NetworkThrottle.customName {
                    CustomThrottleFields(custom: $prefs.custom)
                }
                if prefs.throttle != nil {
                    Toggle("Keep After Relaunch", isOn: $prefs.pinned)
                }
                #endif
            }
        } header: {
            Text("Connection")
        } footer: {
            Text(prefs.throttle.map { "Throttled: \($0.name), \($0.summary). The host slows what it sends and this device what it sends back, so the rate control sees a real link of that kind. \(prefs.pinned ? "Kept after relaunch." : "Off again after relaunch.")" }
                 ?? "Automatic lets the host find the fastest rate the link sustains. A cap holds it at or below the value.")
        }
    }

    private func throttleRow(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Down and up kbit/s, added round trip and loss for the Custom throttle.
struct CustomThrottleFields: View {
    @Binding var custom: NetworkThrottle
    var body: some View {
        field("Download", value: Binding(get: { Double(custom.downKbps) }, set: { custom.downKbps = max(0, Int($0)) }), unit: "kbps")
        field("Upload", value: Binding(get: { Double(custom.upKbps) }, set: { custom.upKbps = max(0, Int($0)) }), unit: "kbps")
        field("Added Round Trip", value: Binding(get: { custom.rttMs }, set: { custom.rttMs = max(0, min(10_000, $0)) }), unit: "ms")
        field("Loss", value: Binding(get: { custom.lossPercent }, set: { custom.lossPercent = max(0, min(50, $0)) }), unit: "%")
    }
    private func field(_ title: String, value: Binding<Double>, unit: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: value, format: .number)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .frame(maxWidth: 110)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}

/// The network throttle's choices as a page (iOS): Off, Chrome DevTools' presets, recorded links, Custom; each with its
/// numbers, the choice checked.
struct ThrottlePicker: View {
    static let route = "throttle"
    @ObservedObject var prefs: ViewerPreferences

    var body: some View {
        Form {
            Section {
                row("Off", detail: "The real link", choice: "")
            }
            Section {
                ForEach([NetworkThrottle.fast4G, .slow4G, .threeG], id: \.name) { row($0.name, detail: $0.summary, choice: $0.name) }
            } header: { Text("Chrome DevTools Presets") } footer: { Text("Chrome's own bandwidth and latency numbers.") }
            Section {
                row(NetworkThrottle.japanBus4G.name, detail: NetworkThrottle.japanBus4G.summary, choice: NetworkThrottle.japanBus4G.name)
                row(NetworkThrottle.extreme.name, detail: NetworkThrottle.extreme.summary, choice: NetworkThrottle.extreme.name)
            } header: { Text("Recorded and Worst Case") } footer: { Text("Japan bus 4G: the medians of a trace recorded on a moving bus in rural Japan to a Mac in Dallas.") }
            Section {
                row(NetworkThrottle.customName, detail: prefs.custom.summary, choice: NetworkThrottle.customName)
                if prefs.throttle?.name == NetworkThrottle.customName { CustomThrottleFields(custom: $prefs.custom) }
            }
            if prefs.throttle != nil {
                Section {
                    Toggle("Keep After Relaunch", isOn: $prefs.pinned)
                } footer: {
                    Text("For testing. Unless kept, the throttle is off again the next time Mirage starts.")
                }
            }
        }
        .navigationTitle("Network Throttle")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func row(_ name: String, detail: String, choice: String) -> some View {
        Button { prefs.throttleChoice = choice } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if prefs.throttleChoice == choice { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(prefs.throttleChoice == choice ? .isSelected : [])
    }
}
