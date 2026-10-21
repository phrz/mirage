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
            if model.hostStatus?.consoleLocked == true {
                banner("\(model.hostName)'s screen is locked. Unlock it to see its windows.", color: .black)
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
