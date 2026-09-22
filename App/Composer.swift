import SwiftUI

struct Composer: View {
    @Environment(AppModel.self) private var model
    let running: Bool
    let maxHeight: CGFloat
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ModelMenu(chat: model.chat)
                .frame(height: 36)
                .padding(.leading, 12)
            TextField("Ask for a change", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Type.body)
                .foregroundStyle(Ink.primary)
                .lineLimit(1...maxLines)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        text += "\n"
                    } else if !canSend, let ask = waitingPermission {
                        model.answer(ask, allow: true)
                    } else {
                        send()
                    }
                    return .handled
                }

                .padding(.vertical, 9)
            sendButton
        }
        .padding(6)
        .frame(minHeight: 48)
        .background(Surface.composer, in: .rect(cornerRadius: 24, style: .continuous))
        .overlay {
            // The raised-glass highlight along the top edge, fading out before the sides.
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Surface.composerEdge, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)),
                    lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onAppear { focused = true }
        // While Claude waits on a card, the card owns Return and Esc; the field would eat them.
        .onChange(of: waitingAsk?.requestId) { _, waiting in
            focused = waiting == nil
        }
    }

    private var maxLines: Int {
        max(1, Int((maxHeight - 28) / 18))
    }

    private var sendButton: some View {
        Button {
            if running { model.stop() } else { send() }
        } label: {
            Image(systemName: running ? "stop.fill" : "arrow.up")
                .font(.system(size: running ? 12 : 15, weight: .semibold))
                .foregroundStyle(canSend || running ? Color.black.opacity(0.85) : Ink.faint)
                .frame(width: 36, height: 36)
                .background(canSend || running ? Ink.primary : Surface.selected, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .background { ContextRing(chat: model.chat) }
        .disabled(!running && !canSend)
        .help(running ? "Stop (⌘.)" : "Send (Return)")
        .accessibilityLabel(running ? "Stop" : "Send")
        .animation(Motion.fade, value: running)
    }

    private var waitingAsk: PendingAsk? {
        model.currentConversation?.waitingAsk
    }

    private var waitingPermission: PendingAsk? {
        waitingAsk.flatMap { $0.kind == "permission" ? $0 : nil }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard !running, canSend else { return }
        model.send(text)
        text = ""
        // The field editor can write its buffer back after a Return; clear again once it has.
        Task { @MainActor in text = "" }
    }
}

/// How full the thread's context is, as a thin ring around the send button.
struct ContextRing: View {
    let chat: Chat?

    var body: some View {
        let used = chat?.contextUsed ?? 0
        let window = chat?.contextWindow ?? 0
        let fraction = window > 0 ? min(1, Double(used) / Double(window)) : 0
        ZStack {
            Circle().stroke(Surface.selected, lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(fraction > 0.8 ? Ink.primary : Ink.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.move, value: fraction)
        }
        .frame(width: 42, height: 42)
        .opacity(window > 0 ? 1 : 0)
        .help(window > 0 ? "\(used.formatted(.number.notation(.compactName))) of \(window.formatted(.number.notation(.compactName))) tokens" : "")
        .allowsHitTesting(false)
    }
}
