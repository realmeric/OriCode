import SwiftData
import SwiftUI

/// A quit in the middle of a turn isn't a stop. Each thread still working is marked as OriCode
/// quits, and the next launch picks it up the way the Claude Code app does: one that was working
/// is sent on with a line of its own, and one waiting on you comes back still waiting.
extension AppModel {
    /// The Claude Code app's words, shown in the thread as the message that moved it.
    static let quitLine = "The app was quit while you were working. Please continue from where you left off."

    static let deniedMessage = "The user denied this. Tell them you stopped, and wait for what they want instead."

    /// Called as the app terminates, whatever asked it to: ⌘Q, the Dock, a logout, an update's
    /// restart, or a SIGTERM.
    func markCutOffTurns() {
        for conversation in conversations.values { conversation.quitting() }
    }

    /// Once the engine is ready: a thread cut off while it worked gets the line, on screen or
    /// not, and one cut off while it waited on you keeps its card up and its turn with it.
    func pickUpAfterQuit() {
        guard engineState == .ready else { return }
        let cutOff = (try? context.fetch(FetchDescriptor<Chat>(predicate: #Predicate { $0.quitMidTurn }))) ?? []
        for chat in cutOff {
            let conversation = conversation(for: chat)
            guard !conversation.waitingAfterQuit, !conversation.running else { continue }
            // A quit before the session had begun leaves nothing to go back to.
            guard chat.sessionId != nil else {
                chat.quitMidTurn = false
                conversation.note("OriCode quit before this thread got going. Send it again to start.")
                continue
            }
            Engine.logger.notice("picking up thread \(chat.id.uuidString, privacy: .public) after a quit")
            conversation.userSent(Self.quitLine)
            startTurn(in: chat, text: Self.quitLine)
        }
        notifier.badge(conversations.values.count { $0.waitingAsk != nil })
    }

    /// The CLI that asked went with the quit, so the answer reaches the session as a message of its
    /// own. A permission given covers the call Claude makes again, so it isn't asked twice.
    func answerAfterQuit(_ ask: PendingAsk, in chat: Chat, allow: Bool, answers: [String: String]?, message: String?) {
        let conversation = conversation(for: chat)
        withAnimation(Motion.move) { conversation.answeredAfterQuit(ask.requestId, allow: allow) }
        let text = Self.afterQuit(ask, allow: allow, answers: answers, message: message, cwd: chat.cwd)
        startTurn(in: chat, text: text, allowing: allow && ask.kind == "permission" ? ask : nil)
        notifier.badge(conversations.values.count { $0.waitingAsk != nil })
    }

    /// What Claude is told when an ask a quit cut off is answered: what it had asked, and what the
    /// user chose.
    static func afterQuit(_ ask: PendingAsk, allow: Bool, answers: [String: String]?, message: String?, cwd: String) -> String {
        if ask.kind == "question" {
            let opening = "The app was quit while your question waited for an answer."
            guard allow, let answers, !answers.isEmpty else { return opening + " " + (message ?? AskCard.skipMessage) }
            let asked = (ask.options?.array ?? []).compactMap { $0["question"]?.string }
            let order = asked.filter { answers[$0] != nil } + answers.keys.filter { !asked.contains($0) }.sorted()
            let lines = order.map { "\($0) → \(answers[$0] ?? "")" }
            return ([opening, "The user has answered it now:"] + lines + ["Please continue from where you left off."]).joined(separator: "\n")
        }
        let detail = ask.input["command"]?.string.map(ToolSummary.firstLine)
            ?? ask.input["file_path"]?.string.map { ToolSummary.relative($0, to: cwd) }
        let opening = "The app was quit while you waited for permission to use \(ask.tool)\(detail.map { " (\($0))" } ?? "")."
        guard allow else { return opening + " " + (message ?? deniedMessage) }
        return opening + " The user has allowed it now. Please continue from where you left off."
    }
}
