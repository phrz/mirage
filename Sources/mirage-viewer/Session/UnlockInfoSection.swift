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
    @State private var always = false

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
                if saved {
                    Toggle("Unlock with \(b.name) automatically", isOn: Binding(get: { always }, set: { always = $0; UnlockController.setAlways($0, hostID: id) }))
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .onAppear { saved = UnlockStore.has(hostID: id); always = UnlockController.always(hostID: id) }
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
