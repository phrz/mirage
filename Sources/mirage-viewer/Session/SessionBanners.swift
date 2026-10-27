import SwiftUI
import MirageCore

/// What the person needs to know about the connection, over the picture, the same on the Mac and iOS: an error, a
/// reconnect, a stall, the connect in progress, a locked host screen, and keystrokes held while the host was away (Send or
/// Discard). Nothing else: the numbers are the stats overlay's, off unless turned on.
struct SessionBanners: View {
    let session: ViewerSession
    @ObservedObject var model: ViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let e = model.error {
                banner(e, color: .red)
            } else if let r = model.reconnecting {
                banner("Reconnecting… attempt \(r.attempt), next in \(r.inSeconds) s", color: .orange)
            } else if model.stalledSeconds > 0 {
                banner("No data from the host for \(model.stalledSeconds) s", color: .orange)
            } else if model.streamInfo == nil {
                banner(model.status.prefix(1).uppercased() + model.status.dropFirst(), color: .gray)
            }
            if let n = model.hostNotice { banner(n, color: .indigo) }   // U4: the host restarts into an update
            if model.hostStatus?.consoleLocked == true {
                if model.unlockReady, let b = model.unlockBiometry {
                    // Unlock with biometry (DESIGN §3.13): the system's own name and symbol for this device's biometry.
                    HStack {
                        Text("\(model.hostName)'s screen is locked.")
                        Button { session.unlock.unlock() } label: { Label("Unlock with \(b.name)", systemImage: b.symbol) }
                            .buttonStyle(.borderedProminent).disabled(model.unlockBusy)
                    }
                    .font(.footnote.weight(.medium)).foregroundStyle(.white).padding(10)
                    .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .localOverlay("unlock", onDefault: model.unlockBusy ? nil : { session.unlock.unlock() })
                } else {
                    banner("\(model.hostName)'s screen is locked. Unlock it to see its windows.", color: .black)
                }
            }
            if let r = model.unlockRequest, let b = model.unlockBiometry {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Unlock \(model.hostName) for \(r.reason)?").font(.footnote.weight(.semibold))
                    Text("Asked by \(r.requester). It never sees the password.").font(.caption)
                    HStack {
                        Button { session.unlock.unlock(requestID: r.id, reason: r.reason) } label: { Label("Unlock with \(b.name)", systemImage: b.symbol) }
                            .buttonStyle(.borderedProminent).disabled(model.unlockBusy)
                        Button("Decline", role: .cancel) { session.unlock.decline(r.id) }.buttonStyle(.bordered)
                    }
                }
                .foregroundStyle(.white).padding(10)
                .background(.purple.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                .localOverlay("unlockRequest", onDefault: model.unlockBusy ? nil : { session.unlock.unlock(requestID: r.id, reason: r.reason) },
                              onCancel: { session.unlock.decline(r.id) })
            }
            if let o = model.unlockOffer, let b = model.unlockBiometry {
                HStack {
                    Text(o == .save ? "Save this password for Unlock with \(b.name)?" : "Update the saved password for Unlock with \(b.name)?")
                    Button(o == .save ? "Save" : "Update") { session.unlock.answerOffer(save: true) }.buttonStyle(.borderedProminent)
                    Button("Not Now") { session.unlock.answerOffer(save: false) }.buttonStyle(.bordered)
                }
                .font(.footnote.weight(.medium)).foregroundStyle(.white).padding(10)
                .background(.blue.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                .localOverlay("unlockOffer", onDefault: { session.unlock.answerOffer(save: true) }, onCancel: { session.unlock.answerOffer(save: false) })
            }
            if let m = model.unlockMessage { banner(m, color: .orange) }
            if let a = model.agentSession {
                // DESIGN §3.13: the Mac unlocked for an agent; anyone watching may end it (then Lock When Finished).
                HStack {
                    Text("\(model.hostName) is unlocked for \(UnlockLogic.clean(a.requester, limit: 160)).")
                    Button("End Session") { session.sendControl(.endAgentSession) }.buttonStyle(.borderedProminent)
                }
                .font(.footnote.weight(.medium)).foregroundStyle(.white).padding(10)
                .background(.purple.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                .localOverlay("agentSession", onDefault: { session.sendControl(.endAgentSession) })
            }
            if model.inputHeld {
                HStack {
                    Text("\(model.inputQueued) keystrokes typed while the host was unreachable.")
                    Button("Send") { session.flushInput() }.buttonStyle(.borderedProminent)
                    Button("Discard", role: .destructive) { session.discardInput() }.buttonStyle(.bordered)
                }
                .font(.footnote.weight(.medium)).foregroundStyle(.white).padding(10)
                .background(.blue.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                .localOverlay("inputHeld", onDefault: { session.flushInput() }, onCancel: { session.discardInput() })
            }
        }
    }

    private func banner(_ s: String, color: Color) -> some View {
        Text(s).font(.footnote.weight(.medium)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .localOverlay("banner:" + s)
    }
}

// MARK: - Local overlays over the remote picture (phrz, 2026-10-27: the unlock "Save this password" offer could never be
// pressed: clicks went to the remote Mac)

/// What an overlay's keys do: Return acts as its default button, Escape as its cancel.
final class OverlayActions {
    let onDefault: (() -> Void)?
    let onCancel: (() -> Void)?
    init(onDefault: (() -> Void)?, onCancel: (() -> Void)?) { self.onDefault = onDefault; self.onCancel = onCancel }
}

/// One local overlay drawn over the remote picture, in the picture view's coordinates (top-left origin).
struct LocalOverlay: Equatable {
    var id: String
    var rect: CGRect
    var actions: OverlayActions?
    static func == (a: LocalOverlay, b: LocalOverlay) -> Bool { a.id == b.id && a.rect == b.rect && a.actions === b.actions }
}

struct LocalOverlayKey: PreferenceKey {
    static var defaultValue: [LocalOverlay] = []
    static func reduce(value: inout [LocalOverlay], nextValue: () -> [LocalOverlay]) { value += nextValue() }
}

/// The picture's coordinate space, where overlays report their frames.
let pictureSpace = "mirage.picture"

extension View {
    /// Marks a local overlay over the remote picture: there the pointer belongs to the viewer (shown, nothing forwarded),
    /// and Return / Escape act on its buttons.
    func localOverlay(_ id: String, onDefault: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) -> some View {
        let actions = onDefault == nil && onCancel == nil ? nil : OverlayActions(onDefault: onDefault, onCancel: onCancel)
        return background(GeometryReader { g in
            Color.clear.preference(key: LocalOverlayKey.self, value: [LocalOverlay(id: id, rect: g.frame(in: .named(pictureSpace)), actions: actions)])
        })
    }
}

/// How input over the picture goes, given the local overlays (pure, for both platforms and the tests).
enum OverlayInput {
    enum Key: Equatable { case returnKey, escape, other }
    enum Route: Equatable {
        /// To the host, as always.
        case forward
        /// Kept local: over an overlay, nothing reaches the host.
        case local
        case overlayDefault
        case overlayCancel
    }
    static func overlay(at p: CGPoint, in overlays: [LocalOverlay]) -> LocalOverlay? { overlays.last { $0.rect.contains(p) } }

    /// The pointer (or a press) at `p`.
    static func pointer(at p: CGPoint, overlays: [LocalOverlay]) -> Route { overlay(at: p, in: overlays) == nil ? .forward : .local }

    /// A key while the pointer is at `p`: over an overlay, Return and Escape act on it and nothing goes to the host.
    static func key(_ k: Key, pointer p: CGPoint?, overlays: [LocalOverlay]) -> Route {
        guard let p, let o = overlay(at: p, in: overlays) else { return .forward }
        switch k {
        case .returnKey where o.actions?.onDefault != nil: return .overlayDefault
        case .escape where o.actions?.onCancel != nil: return .overlayCancel
        default: return .local
        }
    }
}
