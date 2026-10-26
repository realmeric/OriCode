import SwiftUI

/// The field on the system's glass, growing to its lines, and send, the light circle the Mac's
/// composer has: an arrow, or Stop while a turn runs and nothing is typed.
struct Composer: View {
    @Binding var text: String
    var lines = 6
    var working = false
    var typing: FocusState<Bool>.Binding
    let send: () -> Void
    var stop: () -> Void = {}

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(alignment: .bottom, spacing: 8) {
            TextField("", text: $text, axis: .vertical)
                .lineLimit(1...lines)
                .focused(typing)
                .foregroundStyle(Ink.primary)
                .padding(.vertical, 11)
                .padding(.leading, 16)
            Button {
                if empty { stop() } else { send() }
            } label: {
                Image(systemName: empty && working ? "stop.fill" : "arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: 20, height: 20)
                    // Disabled, the glass goes dark under it, so the arrow goes faint white.
                    .foregroundStyle(empty && !working ? Ink.faint : .black)
            }
            .lit()
            .buttonBorderShape(.circle)
            .disabled(empty && !working)
            .accessibilityLabel(empty && working ? "Stop" : "Send")
            .padding(5)
        }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
    }
}
