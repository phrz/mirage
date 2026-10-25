import SwiftUI
import UIKit
import VisionKit
import MirageCore

/// The QR scanner behind the code field's scan button: the pairing link the Mac's "Pair a Device…" window shows.
/// VisionKit's data scanner; where it is unavailable (no camera, the simulator), a field to paste the link instead.
struct PairingScanSheet: View {
    let onLink: (PairingLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var notALink = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScanner { text in
                        if let l = PairingLink(string: text) { onLink(l); dismiss() } else { notALink = true }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    Text(notALink ? "That QR code is not a Mirage pairing code." : "Point the camera at the code in Pair a Device… on your Mac.")
                        .font(.callout).foregroundStyle(notALink ? .orange : .secondary).multilineTextAlignment(.center)
                } else {
                    Spacer()
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 64)).foregroundStyle(.secondary)
                    Text("Scanning needs the camera. You can paste the pairing link instead.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    TextField("miragerd://pair?…", text: $pasted).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button("Use Link") { if let l = PairingLink(string: pasted) { onLink(l); dismiss() } else { notALink = true } }
                        .disabled(pasted.isEmpty)
                    if notALink { Text("That is not a Mirage pairing link.").foregroundStyle(.orange) }
                    Spacer()
                }
            }
            .padding()
            .navigationTitle("Scan Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                guard let t = ProcessInfo.processInfo.environment["MIRAGE_TEST_SCAN_LINK"], let l = PairingLink(string: t) else { return }
                try? await Task.sleep(for: .seconds(1)); onLink(l); dismiss()
            }
        }
    }
}

/// VisionKit's data scanner, QR codes only; reports each code's text once.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) { vc.stopScanning() }
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var seen = Set<String>()
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items { if let t = b.payloadStringValue, seen.insert(t).inserted { onCode(t) } }
        }
    }
}
