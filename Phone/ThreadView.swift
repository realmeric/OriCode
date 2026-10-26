import Link
import SwiftUI

/// A thread, pushed over home: what it's on while it works, its last reply, its asks, what was
/// sent to it from here, and the composer. Not its history: that stays on the Mac.
struct ThreadView: View {
    @Environment(PhoneClient.self) private var store
    let id: UUID
    @State private var draft = ""
    @State private var sentAt = 0
    @FocusState private var typing: Bool

    private var thread: ThreadInfo? { store.threads[id] }
    private var awake: Bool { store.mac?.state ?? .awake == .awake }
    private var working: Bool { thread?.status == .working || thread?.status == .asking }

    private var asks: [AskInfo] {
        store.asks.values.filter { $0.thread == id }.sorted { ($0.asked, $0.id) < ($1.asked, $1.id) }
    }

    /// What was written to it from this phone, oldest first.
    private var messages: [PhoneClient.Sent] {
        store.sent.values.filter {
            if case .send(id, _) = $0.action { true } else if case .open = $0.action { $0.thread == id } else { false }
        }.sorted { $0.at < $1.at }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let thread, working, awake, let step = thread.step {
                    HStack(spacing: 10) {
                        ThreadMark(thread: thread, awake: awake)
                            .frame(width: 16, height: 16)
                        Text(step)
                            .font(.footnote)
                            .foregroundStyle(Ink.faint)
                            .lineLimit(2)
                    }
                }
                if let reply = thread?.reply, !reply.isEmpty {
                    Text(Self.markdown(reply))
                        .font(.body)
                        .foregroundStyle(Ink.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(asks) { ask in
                    AskCard(ask: ask, named: false)
                }
                ForEach(messages) { message in
                    Bubble(message: message)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .background { Ground() }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Badge(project: thread.flatMap { store.projects[$0.project] })
                    Text(thread?.title ?? "")
                        .font(.headline)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sentAt)
    }

    private var composer: some View {
        Composer(text: $draft, working: working, typing: $typing, send: send, stop: stop)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.send(.send(thread: id, text: text))
        draft = ""
        sentAt += 1
    }

    private func stop() {
        guard working else { return }
        if let old = store.stopSent(for: id) { store.clear(old.id) }
        store.send(.stop(thread: id))
        sentAt += 1
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// A message written here: in secondary ink until the Mac takes it, as the Mac shows one sent
/// into a turn; refused or never taken, a red mark beside it, as Messages shows one undelivered,
/// and a tap sends it again.
private struct Bubble: View {
    @Environment(PhoneClient.self) private var store
    let message: PhoneClient.Sent

    var body: some View {
        let undelivered = message.undelivered()
        HStack(alignment: .center, spacing: 8) {
            Spacer(minLength: 40)
            if undelivered {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Ink.red)
            }
            Text(text)
                .font(.body)
                .foregroundStyle(message.state == .done ? Ink.primary : Ink.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 18, style: .continuous))
        }
        .contentShape(.rect)
        .onTapGesture { if undelivered { store.resend(message.id) } }
    }

    private var text: String {
        switch message.action {
        case .send(_, let text), .open(_, let text): text
        default: ""
        }
    }
}
