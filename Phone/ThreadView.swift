import Link
import SwiftUI

/// A thread, pushed over home: its whole conversation as the Mac's transcript has it, newest at the
/// bottom, and the composer. The conversation comes in pages while this screen is up, and goes with
/// it; until the first page, what's known stands in for it, so this is never an empty screen.
struct ThreadView: View {
    @Environment(PhoneClient.self) private var store
    let id: UUID
    @State private var draft = ""
    @State private var sentAt = 0
    /// Counts the times the thread is taken to its end.
    @State private var ends = 0
    /// The row that was first while earlier pages come in above it.
    @State private var kept: String?
    /// Whether the end is in view, which keeps it there as the thread grows.
    @State private var pinned = true
    /// Whether the top of what's in hand is in view, which asks for the pages before it.
    @State private var atTop = false
    @FocusState private var typing: Bool

    private var thread: ThreadInfo? { store.thread(id) }
    private var talk: ThreadTalk? { store.talk?.thread == id ? store.talk : nil }
    private var awake: Bool { store.mac?.state ?? .awake == .awake }
    private var working: Bool { thread?.status == .working || thread?.status == .asking }

    /// The asks waiting that no row holds yet: an ask comes at once, a page within two seconds.
    private var asks: [AskInfo] {
        store.asks.values
            .filter { $0.thread == id && talk?.holds(ask: $0.id) != true }
            .sorted { ($0.asked, $0.id) < ($1.asked, $1.id) }
    }

    /// What was written to it from this phone and the Mac's transcript doesn't carry yet.
    private var messages: [PhoneClient.Sent] {
        store.sent.values.filter {
            if case .send(id, _) = $0.action { true } else if case .open = $0.action { $0.thread == id } else { false }
        }.sorted { $0.at < $1.at }
    }

    /// What it's on. An older Mac says it in no words while it waits.
    private var step: String? {
        guard working, awake, let step = thread?.step, !step.isEmpty else { return nil }
        return step
    }

    /// What grows at the thread's end.
    private var tail: Tail {
        Tail(rows: talk?.rows.count ?? 0, words: talk?.rows.last?.line.text.utf8.count ?? 0, messages: messages.count, step: step)
    }

    private struct Tail: Equatable {
        let rows: Int
        let words: Int
        let messages: Int
        let step: String?
    }

    /// Nothing known yet: no page, no reply, no ask, no message, no step.
    private var nothing: Bool {
        talk?.rows.isEmpty != false && thread?.reply?.isEmpty != false && asks.isEmpty && messages.isEmpty && step == nil
    }

    var body: some View {
        ScrollViewReader { reader in
            // A list and not a lazy stack in a scroll view: scrolling slowly up through rows it had
            // only estimated, the stack could start a layout that never ended, and the app hung
            // for good with nothing of ours running (P-24, the same stack as K-361's on the Mac).
            List {
                content
                Color.clear
                    .frame(height: 12)
                    .talkRow()
                    .id(Self.end)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            // Again once the rows it passed have sized themselves, and the keyboard has come.
            .task(id: ends) {
                guard ends > 0 else { return }
                for wait in [0, 150, 450] {
                    try? await Task.sleep(for: .milliseconds(wait))
                    guard !Task.isCancelled else { return }
                    reader.scrollTo(Self.end, anchor: .bottom)
                }
            }
            // A list opens at its top, and follows nothing: both are asked for here.
            .task(id: talk?.first != nil) {
                if talk?.first != nil { ends += 1 }
            }
            .onChange(of: tail) {
                if pinned { ends += 1 }
            }
            .onChange(of: talk?.asked != nil) { _, asked in
                if asked { kept = talk?.rows.first?.id }
            }
            // Pages came in above it: it goes back to the top, where it stood give or take the
            // spinner's height, since a list goes to a row by its top, centre or bottom alone.
            .onChange(of: talk?.rows.first?.id) { _, first in
                guard let row = kept, first != row else { return }
                reader.scrollTo(row, anchor: .top)
                if talk?.asked == nil { kept = nil }
            }
            // The keyboard coming: a thread at its end stays there.
            .task(id: typing) {
                guard typing, pinned else { return }
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { ends += 1 }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height + geometry.contentInsets.bottom < 80
            } action: { _, atEnd in
                pinned = atEnd
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .overlay {
            if nothing {
                if awake {
                    ProgressView()
                } else {
                    Mark(restingOpacity: 0.15)
                        .frame(width: 44, height: 44)
                }
            }
        }
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
        .task(id: id) { store.watch(id) }
        .onDisappear { store.leave(id) }
#if DEBUG
        .task {
            typing = CommandLine.arguments.contains("-Typing")
            await Screens.scrollUp()
        }
#endif
    }

    /// The rows, each in the column's margins.
    @ViewBuilder private var content: some View {
        if let talk, talk.hasEarlier {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .talkRow()
                .onAppear { atTop = true }
                .onDisappear { atTop = false }
                // A beat, since pages just in leave this in view until what was read is
                // put back under it.
                .task(id: Top(first: talk.first, inView: atTop)) {
                    guard atTop else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    if !Task.isCancelled, atTop { store.earlier() }
                }
        }
        if let talk, !talk.rows.isEmpty {
            TalkRows(talk: talk)
        } else if let reply = thread?.reply, !reply.isEmpty {
            MarkdownText(text: reply)
                .talkRow()
        }
        ForEach(asks) { ask in
            AskCard(ask: ask, named: false)
                .talkRow(top: 16)
        }
        ForEach(messages) { message in
            Bubble(message: message, held: talk?.first != nil)
                .talkRow(top: 16)
        }
        if let step {
            HStack(spacing: 10) {
                if let thread {
                    ThreadMark(thread: thread, awake: awake)
                        .frame(width: 16, height: 16)
                }
                Text(step)
                    .font(.footnote)
                    .foregroundStyle(Ink.faint)
                    .lineLimit(2)
            }
            .talkRow(top: 16)
        }
    }

    private static let end = "end"

    private struct Top: Equatable {
        let first: Int?
        let inView: Bool
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
        ends += 1
    }

    private func stop() {
        guard working else { return }
        if let old = store.stopSent(for: id) { store.clear(old.id) }
        store.send(.stop(thread: id))
        sentAt += 1
    }
}

private extension View {
    /// A row of the conversation in the list: the column's margins, the room over it, and no more
    /// of a list than that.
    func talkRow(top: CGFloat = 0) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// The conversation's rows. A view of its own, so a body drawn again for the step, the bars or a
/// bubble doesn't go through every row, and a row drawn again doesn't reach the list.
private struct TalkRows: View {
    let talk: ThreadTalk

    var body: some View {
        let rows = talk.rows
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            TalkRow(row: row)
                .talkRow(top: TalkRow.spacing(row.kind, after: index == 0 ? nil : rows[index - 1].kind))
        }
    }
}

/// A message written here, at the end, until the Mac's transcript carries it and it stands in its
/// real place: in secondary ink, as the Mac shows one sent into a turn; refused or never taken, a
/// red mark beside it, as Messages shows one undelivered, and a tap sends it again.
private struct Bubble: View {
    @Environment(PhoneClient.self) private var store
    let message: PhoneClient.Sent
    /// A conversation is here to carry it; from a Mac that sends none, taken is as far as it goes.
    let held: Bool

    var body: some View {
        let undelivered = message.undelivered()
        MessageBubble(text: text, ink: message.state == .done && !held ? Ink.primary : Ink.secondary, undelivered: undelivered)
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
