import SwiftUI

/// An ask waiting on the user, from any thread: `holder` is the thread whose agent waits on the
/// answer and gets it, `thread` the one that asks, a worker, subagent or workflow agent under the
/// holder, or the holder itself.
struct WaitingAsk: Identifiable {
    let ask: PendingAsk
    let holder: Chat
    let thread: Chat

    var id: String { ask.requestId }
}

/// The top of ⌘⇧I: every ask from every thread, oldest first, each under the name of the thread
/// that asks and answered in place, as its own card in that thread would be. It doesn't take
/// Return or Esc, which stay the composer's and the open thread's card's.
struct AskQueue: View {
    @Environment(AppModel.self) private var model
    let asks: [WaitingAsk]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(asks.count == 1 ? "Waiting on you" : "\(asks.count) waiting on you")
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            ForEach(asks) { waiting in
                AskEntry(waiting: waiting, lit: model.overviewAsk == waiting.id)
                    .id(waiting.id)
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
    }
}

/// One ask in the queue: who asks, which opens that thread, then what it asks and its answers.
private struct AskEntry: View {
    @Environment(AppModel.self) private var model
    let waiting: WaitingAsk
    let lit: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.openFromOverview(waiting.thread, beside: NSEvent.modifierFlags.contains(.option))
            } label: {
                HStack(spacing: 8) {
                    if let project = waiting.thread.project {
                        ProjectBadge(project: project)
                    }
                    Text(name)
                        .font(Type.secondary)
                        .foregroundStyle(hovering || lit ? Ink.primary : Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Open \(waiting.thread.title)")
            if let line = model.heldLine(of: waiting.ask, in: waiting.holder) {
                HeldLine(text: line)
            }
            AskForm(ask: waiting.ask, cwd: waiting.holder.cwd, thread: waiting.holder.id, listens: false, compact: true)
        }
        .padding(12)
        .background(lit ? Surface.selected : Surface.card, in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(lit ? .isSelected : [])
    }

    /// The asking thread's title; a worker the app has no thread for is named by its task.
    private var name: String {
        guard waiting.thread.id == waiting.holder.id, let worker = waiting.ask.worker else { return waiting.thread.title }
        return "\(waiting.holder.title) · \(worker.label)"
    }
}

extension AppModel {
    /// Every ask waiting on the user, oldest first. A thread waiting on one is never let go
    /// (`letGo`), so every ask is in a conversation in memory. One a thread answers first isn't
    /// the user's until that thread sends it up.
    var waitingAsks: [WaitingAsk] {
        conversations.values
            .flatMap { conversation in
                conversation.waitingAsks.filter { holder(of: $0.requestId) == nil }.map { ask in
                    WaitingAsk(ask: ask, holder: conversation.chat, thread: asker(of: ask) ?? conversation.chat)
                }
            }
            .sorted { ($0.ask.askedAt, $0.ask.requestId) < ($1.ask.askedAt, $1.ask.requestId) }
    }

    /// How many asks wait, which the Dock shows.
    var waitingCount: Int {
        conversations.values.reduce(0) { $0 + $1.waitingAsks.count { holder(of: $0.requestId) == nil } }
    }

    /// How many asks each thread has waiting, by the thread that asks, for the drawer's rows.
    var asksByThread: [UUID: Int] {
        Dictionary(waitingAsks.map { ($0.thread.id, 1) }, uniquingKeysWith: +)
    }

    /// The worker, subagent or workflow agent an ask came from, while it can still take the answer;
    /// nil for the holder's own, and for one whose asker has ended, whose ask is the holder's again.
    func asker(of ask: PendingAsk) -> Chat? {
        guard let chat = askers[ask.requestId], chat.agentWorking else { return nil }
        return chat
    }

    /// The thread of a worker, subagent or workflow agent under `holder`, by the id its asks name.
    func agentThread(_ id: String, under holder: Chat) -> Chat? {
        if let known = agentThreads[id].flatMap(chat(withID:)) { return known }
        return holder.project?.chats.first { $0.openedBy == holder.id && $0.agentID == id }
    }

    /// A notification's click on an ask: the screen of everything running opens with that ask lit
    /// at the top of its queue; one answered meanwhile opens its thread, as any notification does.
    func showAsk(_ requestId: String, holder: UUID) {
        guard let waiting = waitingAsks.first(where: { $0.id == requestId }) else {
            open(chatID: holder)
            return
        }
        (NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true } ?? NSApp.mainWindow)?.makeKeyAndOrderFront(nil)
        withAnimation(Motion.move) {
            if !overviewShown {
                openInIsland(.overview)
                composerMenu = false
                returnKeyboardSoon()
            }
            overviewAsk = requestId
        }
        // The light is the eye's; VoiceOver hears which ask the screen opened on.
        AccessibilityNotification.Announcement("\(waiting.thread.title) is waiting on you").post()
    }
}
