import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread OriCode quit on in the middle of a turn, replayed the way the next launch reads it.
@MainActor
struct QuitTests {
    private let context: ModelContext
    private let chat: Chat
    private var seq = 0

    init() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        let project = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(project)
        chat = Chat(project: project)
        context.insert(chat)
    }

    private mutating func add(_ kind: String, turn: Int = 1, _ body: [String: JSON]) {
        var body = body
        body["event"] = .string(kind)
        let event = Event(turn: turn, seq: seq, kind: kind, payload: (try? JSON.object(body).data()) ?? Data())
        seq += 1
        context.insert(event)
        event.chat = chat
    }

    /// A turn that ran a command, then asked a question about another call and was quit on.
    private mutating func questionCutOff() {
        add("user", ["text": "Make the file"])
        add("tool.use", ["toolUseId": "t0", "name": "Bash", "input": ["command": "ls"]])
        add("tool.use", ["toolUseId": "t1", "name": "AskUserQuestion", "input": [:]])
        add("ask", ["requestId": "r1", "kind": "question", "tool": "AskUserQuestion", "toolUseId": "t1", "input": [:],
                    "options": [["question": "Which name?", "options": [["label": "a.txt"], ["label": "b.txt"]]]]])
    }

    private func call(_ id: String, in conversation: Conversation) -> ToolCall? {
        for item in conversation.items {
            if case .tool(_, let call) = item, call.toolUseId == id { return call }
        }
        return nil
    }

    @Test mutating func aQuestionWaitingAtQuitIsStillWaiting() {
        questionCutOff()
        chat.quitMidTurn = true
        let conversation = Conversation(chat: chat, context: context)
        #expect(conversation.waitingAsk?.requestId == "r1")
        #expect(conversation.waitingAfterQuit)
        #expect(conversation.running)
        // The call the question holds waits with it; the command that never came back is over.
        #expect(call("t1", in: conversation)?.result == nil)
        #expect(call("t0", in: conversation)?.isError == true)
    }

    @Test mutating func withoutAQuitAnEarlierAskIsOver() {
        questionCutOff()
        let conversation = Conversation(chat: chat, context: context)
        #expect(conversation.waitingAsk == nil)
        #expect(!conversation.running)
        #expect(call("t1", in: conversation)?.isError == true)
    }

    @Test mutating func onlyTheLastTurnsAsksComeBack() {
        add("user", ["text": "First"])
        add("ask", ["requestId": "old", "kind": "permission", "tool": "Bash", "input": ["command": "ls"]])
        add("user", turn: 2, ["text": "Second"])
        chat.quitMidTurn = true
        let conversation = Conversation(chat: chat, context: context)
        #expect(conversation.waitingAsk == nil)
        #expect(!conversation.waitingAfterQuit)
    }

    @Test mutating func answeringSettlesTheTurnForTheResumedOne() {
        questionCutOff()
        chat.quitMidTurn = true
        let conversation = Conversation(chat: chat, context: context)
        conversation.answeredAfterQuit("r1", allow: true)
        #expect(conversation.waitingAsk == nil)
        #expect(!conversation.waitingAfterQuit)
        #expect(!chat.quitMidTurn)
        #expect(conversation.running)
        #expect(call("t1", in: conversation)?.isError == true)
    }

    @Test mutating func stopEndsItAsAStoppedTurn() {
        questionCutOff()
        chat.quitMidTurn = true
        let conversation = Conversation(chat: chat, context: context)
        conversation.stopAfterQuit()
        #expect(!conversation.running)
        #expect(!chat.quitMidTurn)
        guard case .footer(_, let footer) = conversation.items.last else {
            Issue.record("no footer")
            return
        }
        #expect(footer.words(time: true, cost: false) == "Stopped")
    }

    @Test func quittingMarksARunningTurnOnly() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.quitting()
        #expect(!chat.quitMidTurn)
        conversation.userSent("Run the tests")
        conversation.quitting()
        #expect(chat.quitMidTurn)
        conversation.userSent(AppModel.quitLine)
        #expect(!chat.quitMidTurn)
    }

    @Test func whatClaudeIsToldOnceItsAskIsAnswered() {
        let question = PendingAsk(
            requestId: "r", kind: "question", tool: "AskUserQuestion", input: [:],
            options: [["question": "Which name?"], ["question": "Which folder?"]])
        #expect(AppModel.afterQuit(question, allow: true, answers: ["Which folder?": "src", "Which name?": "a.txt"], message: nil, cwd: "/p") == """
            The app was quit while your question waited for an answer.
            The user has answered it now:
            Which name? → a.txt
            Which folder? → src
            Please continue from where you left off.
            """)
        #expect(AppModel.afterQuit(question, allow: false, answers: nil, message: AskCard.skipMessage, cwd: "/p")
            == "The app was quit while your question waited for an answer. " + AskCard.skipMessage)
        let command = PendingAsk(requestId: "c", kind: "permission", tool: "Bash", input: ["command": "make test\nmake app"], options: nil)
        #expect(AppModel.afterQuit(command, allow: true, answers: nil, message: nil, cwd: "/p")
            == "The app was quit while you waited for permission to use Bash (make test). The user has allowed it now. Please continue from where you left off.")
        let edit = PendingAsk(requestId: "e", kind: "permission", tool: "Edit", input: ["file_path": "/p/App/a.swift"], options: nil)
        #expect(AppModel.afterQuit(edit, allow: false, answers: nil, message: nil, cwd: "/p")
            == "The app was quit while you waited for permission to use Edit (App/a.swift). " + AppModel.deniedMessage)
    }
}
