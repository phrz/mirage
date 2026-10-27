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
            }
            if let o = model.unlockOffer, let b = model.unlockBiometry {
                HStack {
                    Text(o == .save ? "Save this password for Unlock with \(b.name)?" : "Update the saved password for Unlock with \(b.name)?")
                    Button(o == .save ? "Save" : "Update") { session.unlock.answerOffer(save: true) }.buttonStyle(.borderedProminent)
                    Button("Not Now") { session.unlock.answerOffer(save: false) }.buttonStyle(.bordered)
                }
                .font(.footnote.weight(.medium)).foregroundStyle(.white).padding(10)
                .background(.blue.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
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
            }
            if model.inputHeld {
                HStack {
                    Text("\(model.inputQueued) keystrokes typed while the host was unreachable.")
                    Button("Send") { session.flushInput() }.buttonStyle(.borderedProminent)
                    Button("Discard", role: .destructive) { session.discardInput() }.buttonStyle(.bordered)
                }
                .font(.footnote.weight(.medium)).foregroundStyle(.white).padding(10)
                .background(.blue.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func banner(_ s: String, color: Color) -> some View {
        Text(s).font(.footnote.weight(.medium)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
    }
}
