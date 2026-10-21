import SwiftUI
import MirageCore

/// The gear in the button bar: Connection (bitrate cap; the network throttle under Developer), Input, Display, About.
/// Every change applies at once to the session on screen.
struct SettingsSheet: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var prefs: ViewerPreferences
    @AppStorage(TouchMode.defaultsKey) private var touchMode = TouchMode.direct
    @AppStorage(ViewerSettings.keyAccessoryKey) private var accessoryRow = true
    @AppStorage(ViewerSettings.showStatsKey) private var statsOnConnect = false
    @AppStorage(ViewerSettings.startAtOneToOneKey) private var startAtOneToOne = false
    @Environment(\.dismiss) private var dismiss
    /// Pushed pages (the throttle's). Test hook: `-settingsPage throttle` opens on it.
    @State private var path: [String] = UserDefaults.standard.string(forKey: "settingsPage").map { [$0] } ?? []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                ConnectionSettingsSection(prefs: prefs)
                Section("Input") {
                    Picker("Touch", selection: $touchMode) {
                        Text(TouchMode.direct.title).tag(TouchMode.direct)
                        Text(TouchMode.trackpad.title).tag(TouchMode.trackpad)
                    }
                    Toggle("Keyboard Accessory Row", isOn: $accessoryRow)
                }
                Section {
                    Toggle("Stats Overlay", isOn: Binding(get: { model.showStats }, set: { model.showStats = $0; statsOnConnect = $0 }))
                    Picker("On Connect", selection: $startAtOneToOne) {
                        Text("Fit to Screen").tag(false)
                        Text("1:1 Pixels").tag(true)
                    }
                } header: {
                    Text("Display")
                } footer: {
                    Text("1:1 shows the Mac's pixels at their real size from its top-left corner; pinch or double-tap with two fingers to switch.")
                }
                AboutSettingsSection(model: model)
            }
            .navigationDestination(for: String.self) { route in
                if route == ThrottlePicker.route { ThrottlePicker(prefs: prefs) }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if #available(iOS 26.0, *) { Button("Done", role: .confirm) { dismiss() } } else { Button("Done") { dismiss() } }
                }
            }
        }
    }
}
