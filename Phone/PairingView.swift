import Link
import SwiftUI
import VisionKit

/// The first launch: the mark in the middle and Scan, which opens the camera on the Mac's code.
struct PairingView: View {
    @Environment(PhoneClient.self) private var store
    @State private var scanning = false
    @State private var failed = 0

    var body: some View {
        ZStack {
            Ground()
            // The icon's mark, at the icon's ink.
            Mark(dotOpacity: 1, restingOpacity: 0.62)
                .frame(width: 88, height: 88)
            VStack(spacing: 16) {
                Spacer()
                if let problem = store.problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(Ink.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                if store.pairing {
                    ProgressView().controlSize(.large).frame(height: 56)
                } else if canScan {
                    Button { scanning = true } label: {
                        Label("Scan", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .lit()
                    .controlSize(.extraLarge)
                } else {
                    // No camera to scan with, in the simulator or on a Mac: the code copied from the Mac's sheet.
                    PasteButton(payloadType: String.self) { strings in
                        guard let code = strings.lazy.compactMap(PairingCode.init(string:)).first else { return }
                        Task { await pair(code) }
                    }
                    .buttonBorderShape(.capsule)
                    .controlSize(.extraLarge)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $scanning) {
            Scanner { code in
                scanning = false
                Task { await pair(code) }
            }
            .ignoresSafeArea()
        }
        .sensoryFeedback(.error, trigger: failed)
    }

    /// Scan where there's a camera to scan with; `-Screens pairing` shows it in the simulator too.
    private var canScan: Bool {
#if DEBUG
        if CommandLine.arguments.contains("pairing") { return true }
#endif
        return Scanner.available
    }

    private func pair(_ code: PairingCode) async {
        await store.pair(with: code)
        if store.paired == nil { failed += 1 }
    }
}

/// VisionKit's scanner, looking for QR codes and taking the first that is a pairing code.
struct Scanner: UIViewControllerRepresentable {
    let found: (PairingCode) -> Void

    @MainActor static var available: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .fast, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (PairingCode) -> Void
        private var done = false

        init(found: @escaping (PairingCode) -> Void) {
            self.found = found
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                guard !done, case .barcode(let barcode) = item, let text = barcode.payloadStringValue, let code = PairingCode(string: text) else { continue }
                done = true
                scanner.stopScanning()
                found(code)
            }
        }
    }
}
