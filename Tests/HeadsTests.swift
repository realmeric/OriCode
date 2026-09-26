import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread's heads: the engine's list routed into them, the rays they hold, and the main loop's step.
@MainActor
struct HeadsTests {
    private let context: ModelContext
    private let chat: Chat

    init() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        let project = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(project)
        chat = Chat(project: project)
        context.insert(chat)
    }

    private func receive(_ name: String, _ body: [String: JSON], in conversation: Conversation) {
        var body = body
        body["event"] = .string(name)
        conversation.receive(EngineEvent(name: name, threadId: chat.id.uuidString, body: .object(body)))
    }

    private func head(_ id: String, _ kind: String, step: String? = nil, tokens: Int? = nil) -> JSON {
        var body: [String: JSON] = ["id": .string(id), "kind": .string(kind), "toolUseId": .string("call-" + id), "label": .string(id + "'s work")]
        if let step { body["step"] = ["tool": .string(step), "detail": "App/A.swift"] }
        if let tokens { body["tokens"] = .number(Double(tokens)) }
        return .object(body)
    }

    private func list(_ heads: JSON..., in conversation: Conversation) {
        receive("heads", ["heads": .array(heads)], in: conversation)
    }

    private func rays(_ id: String, in conversation: Conversation) -> [Int] {
        conversation.heads.list.first { $0.id == id }?.rays ?? []
    }

    @Test func theEnginesListReachesTheThreadsHeadsWithTheirDetail() {
        let conversation = Conversation(chat: chat, context: context)
        list(head("a", "agent", step: "Read", tokens: 1200), head("b", "command"), in: conversation)
        #expect(conversation.heads.list.map(\.id) == ["a", "b"])
        #expect(conversation.heads.list[0].step == Head.Step(tool: "Read", detail: "App/A.swift"))
        #expect(conversation.heads.list[0].tokens == 1200)
        #expect(conversation.heads.list[1].kind == .command)
        #expect(conversation.working)
        // Nothing of it is written down.
        #expect(conversation.items.isEmpty)
    }

    @Test func raysLightForAgentsAndNeverForCommands() {
        let conversation = Conversation(chat: chat, context: context)
        list(head("b", "command"), head("a", "agent"), head("x", "other"), in: conversation)
        #expect(rays("b", in: conversation).isEmpty)
        #expect(rays("x", in: conversation).isEmpty)
        #expect(rays("a", in: conversation) == [0])
        #expect(conversation.heads.lit == [0])
    }

    @Test func eachHeadKeepsItsRayAndAFreedOneIsTakenAgain() async throws {
        let conversation = Conversation(chat: chat, context: context)
        list(head("a", "agent"), head("b", "agent"), head("c", "agent"), in: conversation)
        #expect([rays("a", in: conversation), rays("b", in: conversation), rays("c", in: conversation)] == [[0], [1], [2]])

        // b ends: its ray goes out at once, but stays b's until its row has gone.
        list(head("a", "agent"), head("c", "agent"), head("d", "agent"), in: conversation)
        #expect(conversation.heads.lit == [0, 2, 3])
        #expect(rays("d", in: conversation) == [3])
        #expect(conversation.heads.list.first { $0.id == "b" }?.ending == true)

        try await Task.sleep(for: Heads.fading + .milliseconds(100))
        #expect(conversation.heads.list.map(\.id) == ["a", "c", "d"])
        list(head("a", "agent"), head("c", "agent"), head("d", "agent"), head("e", "agent"), in: conversation)
        #expect(rays("c", in: conversation) == [2])
        #expect(rays("e", in: conversation) == [1])
    }

    @Test func aSeventhAgentWaitsForARay() async throws {
        let conversation = Conversation(chat: chat, context: context)
        let seven = (1...7).map { head("a\($0)", "agent") }
        receive("heads", ["heads": .array(seven)], in: conversation)
        #expect(conversation.heads.lit == Set(0..<6))
        #expect(rays("a7", in: conversation).isEmpty)
        receive("heads", ["heads": .array(Array(seven.dropFirst()))], in: conversation)
        try await Task.sleep(for: Heads.fading + .milliseconds(100))
        #expect(rays("a7", in: conversation) == [0])
    }

    @Test func aWorkflowHoldsARayForEachAgentAtWork() {
        let conversation = Conversation(chat: chat, context: context)
        list(head("a", "agent"), head("w", "workflow"), in: conversation)
        #expect(rays("w", in: conversation).isEmpty)
        let agent = { (state: String) -> JSON in ["label": "r", "phase": "Review", "state": .string(state)] }
        receive("workflow", ["taskId": "w", "toolUseId": "call-w", "name": "review", "state": "running", "phases": ["Review"],
                             "agents": [agent("running"), agent("running"), agent("queued"), agent("done")]], in: conversation)
        #expect(rays("w", in: conversation) == [1, 2])
        receive("workflow", ["taskId": "w", "toolUseId": "call-w", "name": "review", "state": "running", "phases": ["Review"],
                             "agents": [agent("done"), agent("running"), agent("running"), agent("running")]], in: conversation)
        #expect(rays("w", in: conversation) == [1, 2, 3])
        #expect(conversation.heads.lit == [0, 1, 2, 3])
    }

    @Test func detailLeftOutWhileUnwatchedKeepsWhatWasSaid() {
        let conversation = Conversation(chat: chat, context: context)
        list(head("a", "agent", step: "Grep"), in: conversation)
        list(head("a", "agent"), in: conversation)
        #expect(conversation.heads.list[0].step?.tool == "Grep")
    }

    @Test func theEngineGoingEndsEveryHead() {
        let conversation = Conversation(chat: chat, context: context)
        list(head("a", "agent"), head("b", "command"), in: conversation)
        conversation.stopped()
        #expect(conversation.heads.isEmpty)
        #expect(conversation.heads.lit.isEmpty)
        #expect(!conversation.working)
    }

    @Test func theMainLoopsStepIsReadOffTheTranscript() {
        let conversation = Conversation(chat: chat, context: context)
        #expect(conversation.mainStep(cwd: "/tmp/alpha").tool == "Idle")
        conversation.userSent("Go")
        #expect(conversation.mainStep(cwd: "/tmp/alpha").tool == "Thinking")
        receive("text", ["delta": "Reading"], in: conversation)
        #expect(conversation.mainStep(cwd: "/tmp/alpha").tool == "Writing")
        receive("tool.use", ["toolUseId": "t", "name": "Read", "input": ["file_path": "/tmp/alpha/App/A.swift"]], in: conversation)
        #expect(conversation.mainStep(cwd: "/tmp/alpha") == Head.Step(tool: "Read", detail: "App/A.swift"))
        receive("tool.result", ["toolUseId": "t", "content": "ok"], in: conversation)
        #expect(conversation.mainStep(cwd: "/tmp/alpha").tool == "Thinking")
        list(head("a", "agent"), head("b", "agent"), head("c", "command"), in: conversation)
        receive("turn.done", ["stopReason": "end_turn"], in: conversation)
        #expect(conversation.mainStep(cwd: "/tmp/alpha").tool == "Waiting on 2 agents")
        #expect(conversation.working)
    }
}
