import SwiftUI
import MirageCore

/// Get Info's Unlock with biometry part (DESIGN §3.13), the Mac's info window and iOS's info sheet alike: whether a password
/// is saved for this Mac, Forget, and a field to enter (or replace) it. Shown only where the Mac types an `unlock` and this
/// device has biometry. Saving needs no approval; using it does.
struct UnlockInfoSection: View {
    let host: PairedHost
    @State private var saved = false
    @State private var entering = false
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        if let b = UnlockStore.biometry, host.unlockFeature, let id = host.hostID {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Unlock with \(b.name)", systemImage: b.symbol)
                    Spacer()
                    Text(saved ? "Password saved" : "Not set up").foregroundStyle(.secondary)
                }
                if entering {
                    // No content type: no AutoFill, and no offer to save it to the (synced) Passwords app.
                    SecureField("\(host.title)'s login password", text: $password)
                        .textContentType(nil)
                        .onSubmit { save(id) }
                    HStack {
                        Button("Cancel") { password = ""; entering = false }
                        Button("Save") { save(id) }.disabled(password.isEmpty).keyboardShortcut(.defaultAction)
                    }
                } else {
                    HStack {
                        Button(saved ? "Replace Password…" : "Set Up…") { entering = true }
                        if saved { Button("Forget", role: .destructive) { UnlockStore.delete(hostID: id); saved = false } }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Kept only on this device, behind \(b.name), and typed only at \(host.title)'s lock screen.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { saved = UnlockStore.has(hostID: id) }
        }
    }

    private func save(_ id: String) {
        guard !password.isEmpty else { return }
        let secret = SecretBytes(Array(password.utf8))
        password = ""
        do { try UnlockStore.save(secret, hostID: id); error = nil; entering = false } catch { self.error = "Not saved: \(error)." }
        secret.wipe()
        saved = UnlockStore.has(hostID: id)
    }
}

/// Settings (the Mac's Settings window, iOS's settings sheet): whether a locked host prompts for Unlock with biometry as soon
/// as the session shows it (on by default). Only on a device with biometry.
struct UnlockSettingsSection: View {
    @AppStorage(UnlockController.autoPromptKey) private var autoPrompt = true
    var body: some View {
        if let b = UnlockStore.biometry {
            Section {
                Toggle("Ask on Connect to a Locked Mac", isOn: $autoPrompt)
            } header: {
                Text("Unlock with \(b.name)")
            } footer: {
                Text("Set up per Mac in its Get Info, or save the password the first time you type it at its lock screen through Mirage. It stays on this device, behind \(b.name).")
            }
        }
    }
}
