import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings › Phone: the switch, Pair a phone and the phones paired, each with Unpair.
struct PhonePane: View {
    @Environment(AppModel.self) private var model
    @State private var pairing = false

    var body: some View {
        let link = model.phone
        PaneTitle(text: "Phone")
        SectionHeading("Your iPhone")
        SettingsCard {
            SettingsRow(
                title: "Phone",
                detail: link.problem ?? "See what's running and answer it from your iPhone. It goes through your iCloud, sealed on this Mac."
            ) {
                Toggle("Phone", isOn: Binding(get: { link.on }, set: { link.turn(on: $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            if link.on {
                SettingsRow(title: "Pair a phone", detail: "Open OriCode on your iPhone and scan the code.") {
                    Button("Pair…") { pairing = true }
                        .disabled(link.problem != nil)
                }
                ForEach(link.phones) { phone in
                    SettingsRow(title: phone.name) {
                        Button("Unpair") { link.unpair(phone) }
                    }
                }
            }
        }
        .sheet(isPresented: $pairing) { PairingSheet() }
        .task { if link.on { await link.checkAccount() } }
    }
}

/// The code a phone scans, black on white so a camera reads it, for five minutes or until the
/// sheet closes; then the phone's name once it has paired.
private struct PairingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let link = model.phone
        VStack(spacing: 18) {
            if let name = link.justPaired {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Ink.primary)
                Text(name)
                    .font(Type.body)
                    .foregroundStyle(Ink.primary)
            } else if let code = link.code {
                QRCode(text: code.string)
                    .frame(width: 240, height: 240)
                    // For a phone build running on a Mac, which has no camera to scan with.
                    .contextMenu {
                        Button("Copy Code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code.string, forType: .string)
                        }
                    }
            }
            Button(link.justPaired == nil ? "Cancel" : "Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(minWidth: 320, minHeight: 340)
        .onAppear { link.startPairing() }
        .onDisappear { link.stopPairing() }
        .onChange(of: link.code == nil) { _, gone in
            // Expired with nobody pairing.
            if gone, link.justPaired == nil { dismiss() }
        }
        .task(id: link.justPaired) {
            guard link.justPaired != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            dismiss()
        }
    }
}

private struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(of: text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .padding(16)
                .background(.white, in: .rect(cornerRadius: 14, style: .continuous))
        }
    }

    private static func image(of text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
