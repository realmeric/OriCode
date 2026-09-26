import Foundation
import SwiftData
import Testing
@testable import OriCode

/// Another agent's calls, in the shape the engine's ACP session tells them: a kind and a view on
/// each, hunks on the result. They come out in Claude Code's words, with Claude's diff counts,
/// the review's provenance and the plan card, and Claude's own calls read as they always have.
@MainActor
struct ToolKindTests {
    private let context: ModelContext
    private let chat: Chat
    private static let root = "/tmp/alpha"

    init() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        let project = Project(name: "alpha", path: Self.root)
        context.insert(project)
        chat = Chat(project: project)
        context.insert(chat)
    }

    private func receive(_ name: String, _ body: [String: JSON], in conversation: Conversation) {
        var body = body
        body["event"] = .string(name)
        conversation.receive(EngineEvent(name: name, threadId: chat.id.uuidString, body: .object(body)))
    }

    /// A call and its result, as the ACP session tells them.
    private func call(
        _ name: String, kind: String, input: JSON = [:], view: JSON, patch: JSON? = nil, isError: Bool = false, in conversation: Conversation
    ) {
        let id = JSON.string(UUID().uuidString)
        receive("tool.use", ["toolUseId": id, "name": .string(name), "input": input, "kind": .string(kind), "view": view], in: conversation)
        var result: [String: JSON] = ["toolUseId": id, "content": "ok", "isError": .bool(isError)]
        if let patch { result["patch"] = patch }
        receive("tool.result", result, in: conversation)
    }

    private static func calls(_ conversation: Conversation) -> [ToolCall] {
        conversation.items.compactMap { item in
            if case .tool(_, let call) = item { call } else { nil }
        }
    }

    private static let todos: JSON = [
        ["content": "Read a.txt", "activeForm": "Read a.txt", "status": "completed"],
        ["content": "Edit a.txt", "activeForm": "Edit a.txt", "status": "in_progress"],
        ["content": "Check it", "activeForm": "Check it", "status": "pending"],
    ]

    @Test func aRunReadsInClaudesWordsAndCountsAsACheck() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Test it")
        call("make", kind: "run", input: ["command": ["make", "test"]], view: ["command": "make test"], in: conversation)
        call("Terminal", kind: "run", view: ["command": "ls -la"], in: conversation)
        call("Grep 'TODO' in src", kind: "search", view: ["pattern": "TODO"], in: conversation)
        receive("text", ["delta": "It passes."], in: conversation)

        let calls = Self.calls(conversation)
        #expect(calls.map(\.kind) == [.run, .run, .search])
        #expect(ToolSummary.line(for: calls[0], cwd: Self.root) == "Run: make test")
        #expect(ToolSummary.line(for: calls[2], cwd: Self.root) == "Search TODO")
        let listing = ToolCall(toolUseId: "l", name: "Shell", input: [:], declared: .list, view: ["path": "/tmp/alpha/App", "command": "ls App"])
        #expect(ToolSummary.line(for: listing, cwd: Self.root) == "List App")
        #expect(ToolSummary.target(for: calls[0], cwd: Self.root) == "make test")
        #expect(ToolSummary.run(calls) == "Ran 2 commands, searched for 1 pattern")
        let found = Provenance(items: conversation.items) { RepoPath.relative($0, cwd: Self.root, root: Self.root) }
        #expect(found.checks[1] == [Provenance.Check(command: "make test", failed: false)])
    }

    @Test func anEditAndAWriteGiveTheirDiffsFooterAndProvenance() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Change a.txt")
        call("Edit a.txt", kind: "edit", input: ["path": "/tmp/alpha/a.txt"], view: ["path": "/tmp/alpha/a.txt"],
             patch: [["oldStart": 1, "newStart": 1, "lines": [" one", "-two", "+2", " three"]], ["oldStart": 9, "newStart": 9, "lines": ["+ten"]]],
             in: conversation)
        call("Create b.txt", kind: "write", view: ["path": "/tmp/alpha/b.txt"], patch: [["oldStart": 0, "newStart": 1, "lines": ["+hello", "+world"]]],
             in: conversation)
        receive("turn.done", ["stopReason": "end_turn"], in: conversation)

        let calls = Self.calls(conversation)
        #expect(calls.map(\.isEdit) == [true, true])
        let edit = Diff.of(calls[0], cwd: Self.root)
        #expect(edit?.path == "a.txt")
        #expect(edit?.added == 2)
        #expect(edit?.deleted == 1)
        #expect(Diff.of(calls[1], cwd: Self.root)?.added == 2)
        #expect(ToolSummary.line(for: calls[0], cwd: Self.root) == "Edit a.txt")
        #expect(ToolSummary.line(for: calls[1], cwd: Self.root) == "Write b.txt")
        #expect(ToolSummary.path(for: calls[1]) == "/tmp/alpha/b.txt")
        #expect(ToolSummary.run(calls) == "Edited 2 files")
        guard case .footer(_, let footer) = conversation.items.last else {
            Issue.record("no footer")
            return
        }
        #expect(footer.files == 2)
        #expect(footer.added == 4)
        #expect(footer.deleted == 1)

        let found = Provenance(items: conversation.items) { RepoPath.relative($0, cwd: Self.root, root: Self.root) }
        #expect(found.turn(of: "+2", in: "a.txt") == 1)
        #expect(found.turn(of: "-two", in: "a.txt") == 1)
        #expect(found.turn(of: "+world", in: "b.txt") == 1)
        #expect(found.lastTurn(editing: "b.txt") == 1)
    }

    @Test func aPatchInTheViewIsTheDiffBeforeAnyResult() {
        let call = ToolCall(
            toolUseId: "e", name: "apply_patch", input: [:], declared: .edit,
            view: ["path": "/tmp/alpha/a.txt", "patch": [["oldStart": 1, "newStart": 1, "lines": ["-a", "+b"]]]])
        #expect(Diff.of(call, cwd: Self.root)?.deleted == 1)
        #expect(Diff.of(call, cwd: Self.root)?.path == "a.txt")
    }

    @Test func aPlanFromTheViewGetsTheCardAndItsUpdateFolds() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Plan it")
        call("TodoWrite", kind: "plan", input: ["todos": Self.todos], view: ["todos": Self.todos], in: conversation)
        call("Read a.txt", kind: "read", view: ["path": "/tmp/alpha/a.txt"], in: conversation)
        // An agent whose plan tool keeps its list only in the view.
        var done = Self.todos.array ?? []
        done[1] = ["content": "Edit a.txt", "activeForm": "Edit a.txt", "status": "completed"]
        call("update_plan", kind: "plan", view: ["todos": .array(done)], in: conversation)
        call("Run", kind: "run", view: ["command": "make check"], in: conversation)
        receive("text", ["delta": "Done."], in: conversation)

        let entries = TranscriptEntry.fold(conversation.items)
        let cards = entries.compactMap { entry in
            if case .item(.tool(_, let call)) = entry { call.plan } else { nil }
        }
        #expect(cards.count == 1)
        #expect(cards.first?.todos.map(\.content) == ["Read a.txt", "Edit a.txt", "Check it"])
        #expect(cards.first?.done == 2)
        #expect(conversation.plan?.current == nil)
        // The update has no line, so the read and the run either side of it are one row.
        let runs = entries.compactMap { entry in
            if case .run(let items) = entry { items.count } else { nil }
        }
        #expect(runs == [2])
    }

    @Test func anAskWithChoicesIsAnsweredByTheAgentsOptionId() throws {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Run it")
        receive("tool.use", ["toolUseId": "run-1", "name": "make", "input": [:], "kind": "run", "view": ["command": "make test"]], in: conversation)
        receive("ask", [
            "requestId": "r", "kind": "permission", "tool": "make", "toolKind": "run", "toolUseId": "run-1", "input": [:],
            "view": ["command": "make test"],
            "choices": [
                ["id": "once", "name": "Allow once", "kind": "allow_once"],
                ["id": "always", "name": "Always allow", "kind": "allow_always"],
                ["id": "reject", "name": "Reject", "kind": "reject_once"],
            ],
        ], in: conversation)

        let ask = try #require(conversation.waitingAsk)
        #expect(ask.toolKind == .run)
        #expect(ask.choices.map(\.id) == ["once", "always", "reject"])
        #expect(ask.choices.map(\.allows) == [true, true, false])
        #expect(ToolSummary.line(for: ask.call, cwd: Self.root) == "Run: make test")
        let always = AppModel.answerParams(ask, allow: true, answers: nil, message: nil, choice: ask.choices[1])
        #expect(always == ["requestId": "r", "allow": true, "optionId": "always"])
        let reject = AppModel.answerParams(ask, allow: false, answers: nil, message: "No.", choice: ask.choices[2])
        #expect(reject == ["requestId": "r", "allow": false, "message": "No.", "optionId": "reject"])
        // Claude's asks have no choices and send none.
        let plain = PendingAsk(requestId: "c", kind: "permission", tool: "Bash", input: ["command": "ls"], options: nil)
        #expect(AppModel.answerParams(plain, allow: true, answers: nil, message: nil, choice: nil) == ["requestId": "c", "allow": true])
    }

    @Test func claudesCallsReadThroughItsNames() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Go")
        for (name, input) in [("Bash", ["command": "make test"]), ("NotebookEdit", ["notebook_path": "/tmp/alpha/n.ipynb"]),
                              ("Workflow", [:]), ("mcp__linear__get_issue", [:]), ("MultiEdit", ["file_path": "/tmp/alpha/a.swift"])] as [(String, JSON)] {
            receive("tool.use", ["toolUseId": .string(name), "name": .string(name), "input": input], in: conversation)
        }
        let calls = Self.calls(conversation)
        #expect(calls.map(\.declared) == [.run, .notebook, .workflow, .mcp, .edit])
        #expect(calls.map(\.isEdit) == [false, false, false, false, true])
        #expect(ToolSummary.line(for: calls[0], cwd: Self.root) == "Bash: make test")
        #expect(ToolSummary.line(for: calls[1], cwd: Self.root) == "Edit n.ipynb")
        #expect(ToolSummary.path(for: calls[1]) == "/tmp/alpha/n.ipynb")
        #expect(ToolSummary.run([calls[1]]) == "Edited 1 file")
        #expect(ToolSummary.line(for: calls[3], cwd: Self.root) == "linear › get_issue")
        #expect(ToolKind(claude: "Glob") == .search)
        #expect(ToolKind(claude: "LS") == .list)
        #expect(ToolKind(claude: "Anything") == .other)
        #expect(ToolKind("nonsense", tool: "Read") == .read)
    }
}
