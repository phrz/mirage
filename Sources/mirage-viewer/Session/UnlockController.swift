import Foundation
import MirageCore

/// Unlock with biometry in a session (DESIGN §3.13): offers it while the host's screen is locked and a password is saved
/// (a click; the prompt comes by itself only for a host set to Always), sends the password after approval, offers to save what the person typed at the
/// lock screen when it unlocked the Mac, and answers agents' requests. Never retries a password that failed.
final class UnlockController: @unchecked Sendable {
    typealias Offer = UnlockLogic.SaveOffer

    private weak var session: ViewerSession?
    private let model: ViewerModel
    private let lock = NSLock()
    private var capture = UnlockLogic.Capture()
    /// A password the person typed that unlocked the host, waiting for Save or Not Now (memory only, wiped either way).
    private var offered: SecretBytes?
    private var hostID: String?
    private var hostOffers = false
    private var locked = false
    private var promptedThisConnection = false
    /// The saved password failed: no automatic prompt, and the next typed password that works is offered as an update.
    private var savedFailed = false

    init(session: ViewerSession, model: ViewerModel) { self.session = session; self.model = model }
    /// The host as the person named it (the alias they connected to).
    private var hostName: String { session?.host ?? "the host" }

    /// Per host: this device raises the prompt by itself on connecting to it while it is locked (the offer's Always, Get Info).
    static func alwaysKey(_ hostID: String) -> String { "unlockAlways." + hostID }
    static func always(hostID: String?, _ d: UserDefaults = .standard) -> Bool { hostID.map { d.bool(forKey: alwaysKey($0)) } ?? false }
    static func setAlways(_ on: Bool, hostID: String, _ d: UserDefaults = .standard) { d.set(on, forKey: alwaysKey(hostID)) }

    /// The Hello's features for `hostID`: this viewer answers that host's requests only where it can (biometry, and a
    /// password saved for it), so a request is never settled by a device that has nothing to send.
    static func helloFeatures(hostID: String?) -> [String] {
        guard UnlockStore.biometry != nil, let hostID, UnlockStore.has(hostID: hostID) else { return [] }
        return [ControlMessage.Feature.unlock]
    }

    /// After each Welcome.
    func connected(hostID: String?, welcome: ControlMessage.Welcome) {
        lock.lock()
        self.hostID = hostID
        hostOffers = (welcome.features ?? []).contains(ControlMessage.Feature.unlock)
        promptedThisConnection = false; locked = false
        lock.unlock()
        Task { @MainActor in model.unlockDismissed = false }
        refresh()
    }

    /// The host's lock state, from each hostStatus.
    func hostStatus(locked nowLocked: Bool) {
        lock.lock()
        let was = locked
        locked = nowLocked
        var offer: Offer?
        if was, !nowLocked, let pw = capture.hostLocked(false) {
            let saved = hostID.map { UnlockStore.has(hostID: $0) } ?? false
            if hostID != nil, let o = UnlockLogic.saveOffer(biometry: UnlockStore.biometry != nil, saved: saved, savedFailed: savedFailed) {
                var d = pw
                offered = SecretBytes(taking: &d); offer = o
            }
        } else if nowLocked { _ = capture.hostLocked(true) }   // (drops a candidate whose window passed)
        if !nowLocked { savedFailed = false }
        let prompt = UnlockLogic.autoPrompt(nowLocked: nowLocked, wasLocked: was, alreadyPrompted: promptedThisConnection, savedFailed: savedFailed,
                                            always: Self.always(hostID: hostID), ready: ready())
        if prompt { promptedThisConnection = true }
        lock.unlock()
        if was != nowLocked { refresh() }   // (a file check: on changes only, not every status)
        if let offer { Task { @MainActor in model.unlockOffer = offer } }
        if prompt { unlock() }
    }

    /// Every key the session sends (not scripted ones): followed while the host is locked.
    func key(_ k: ControlMessage.Key) {
        guard k.down else { return }
        lock.lock(); if locked { capture.key(code: k.keyCode, characters: k.characters, modifiers: k.modifiers) }; lock.unlock()
    }
    func click() { lock.lock(); if locked { capture.spoil() }; lock.unlock() }

    /// Unlock now (the banner's button, the automatic prompt, or an agent's request the person approves). Not approved, or
    /// nothing saved: no answer to a request (another device may still answer it; Decline is the person's own choice).
    func unlock(requestID: String? = nil, reason: String? = nil) {
        lock.lock(); let id = hostID; lock.unlock()
        guard let id, let session else { return }
        let host = hostName
        Task { @MainActor in model.unlockBusy = true; model.unlockMessage = nil }
        Task.detached {
            let prompt = reason.map { "Unlock \(host) for \(UnlockLogic.clean($0))" } ?? "Unlock \(host)"
            do {
                let secret = try await UnlockStore.open(hostID: id, reason: prompt)
                var data = Data(secret.bytes)
                secret.wipe()
                session.sendControl(.unlock(.init(password: data, requestID: requestID)))
                SecretBytes.wipe(&data)
                session.log("unlock: sent the saved password for \(host)\(requestID != nil ? " (a request)" : "")")
            } catch {
                let f = error as? UnlockStore.Failure
                let name = UnlockStore.biometry?.name ?? "biometry"
                await MainActor.run {
                    self.model.unlockBusy = false
                    if case .notSaved? = f { self.model.unlockMessage = "No password is saved for \(host): set up Unlock with \(name) in its Get Info." }
                    else if case .cancelled? = f {} else { self.model.unlockMessage = "Unlock with \(name): \(error)." }
                }
            }
        }
    }
    /// The offer's Always: from now on this device prompts by itself on connecting to this host while it is locked; and now.
    func always() {
        lock.lock(); let id = hostID; lock.unlock()
        if let id { Self.setAlways(true, hostID: id) }
        unlock()
    }
    func decline(_ requestID: String) {
        session?.sendControl(.unlockDecline(.init(requestID: requestID)))
        Task { @MainActor in if model.unlockRequest?.id == requestID { model.unlockRequest = nil } }
    }

    func result(_ r: ControlMessage.UnlockResult) {
        // A request settled elsewhere (another device answered, or it timed out): close its prompt here.
        if let rid = r.requestID, r.message.hasPrefix("settled:") {
            Task { @MainActor in if model.unlockRequest?.id == rid { model.unlockRequest = nil; model.unlockBusy = false } }
            return
        }
        if r.outcome == .stillLocked { lock.lock(); savedFailed = true; lock.unlock() }
        session?.log("unlock: \(r.outcome.rawValue) (\(r.message))")
        let text: String? = switch r.outcome {
        case .unlocked: nil
        case .stillLocked: "The saved password didn't unlock \(hostName). Type it at the lock screen; Mirage will offer to update the saved one."
        case .notLocked, .refused, .interrupted: r.message.prefix(1).uppercased() + r.message.dropFirst() + "."
        case .passwordDialog: nil   // an alert (unlockDialog): the person has to act at the Mac's screen
        }
        if r.outcome == .passwordDialog { Task { @MainActor in model.unlockDialog = r.message.prefix(1).uppercased() + r.message.dropFirst() + "." } }
        Task { @MainActor in
            model.unlockBusy = false
            if r.requestID != nil, model.unlockRequest?.id == r.requestID { model.unlockRequest = nil }
            model.unlockMessage = text
            if let text { try? await Task.sleep(for: .seconds(12)); if model.unlockMessage == text { model.unlockMessage = nil } }
        }
        refresh()
    }

    func request(_ r: ControlMessage.UnlockRequest) {
        var shown = r
        shown.reason = UnlockLogic.clean(r.reason); shown.requester = UnlockLogic.clean(r.requester, limit: 160)
        session?.log("unlock: \(shown.requester) asks to unlock \(hostName): \(shown.reason)")
        Task { @MainActor in model.unlockRequest = shown }
    }

    /// The save offer's answer.
    func answerOffer(save: Bool) {
        lock.lock(); let pw = offered; offered = nil; let id = hostID; lock.unlock()
        var failure: String?
        if save, let pw, let id {
            do { try UnlockStore.save(pw, hostID: id); lock.lock(); savedFailed = false; lock.unlock() }
            catch { failure = "Not saved: \(error)." }
        }
        pw?.wipe()
        Task { @MainActor in model.unlockOffer = nil; if let failure { model.unlockMessage = failure } }
        refresh()
    }

    /// Unlock offered: the host types passwords, this device has biometry, and one is saved for this host.
    private func ready() -> Bool { hostOffers && UnlockStore.biometry != nil && (hostID.map { UnlockStore.has(hostID: $0) } ?? false) }
    private func refresh() {
        lock.lock(); let r = ready(); lock.unlock()
        let b = UnlockStore.biometry
        Task { @MainActor in model.unlockReady = r; model.unlockBiometry = b }
    }
}
