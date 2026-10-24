import Foundation
import SwiftData
import Testing
@testable import OriCode

@MainActor
struct AskQueueTests {
    /// In alpha, Build and Docs are threads of their own and Lead is a head with a worker under it,
    /// Check, whose thread the engine names w-key; in beta, Site. Nothing has asked yet.
    private func model() throws -> (AppModel, build: Chat, docs: Chat, lead: Chat, check: Chat, site: Chat) {
        let container = try TestStore.memory()
        let context = container.mainContext
        let alpha = Project(name: "alpha", path: "/tmp/alpha")
        let beta = Project(name: "beta", path: "/tmp/beta")
        context.insert(alpha)
        context.insert(beta)
        func thread(_ title: String, in project: Project) -> Chat {
            let chat = Chat(project: project, title: title)
            chat.started = true
            context.insert(chat)
            return chat
        }
        let build = thread("Build", in: alpha)
        let docs = thread("Docs", in: alpha)
        let lead = thread("Lead", in: alpha)
        let check = thread("Check", in: alpha)
        check.openedBy = lead.id
        check.agentID = "w-key"
        check.agentKind = "worker"
        check.agentTask = "worker-1"
        let site = thread("Site", in: beta)
        try context.save()
        let model = AppModel(container: container)
        // At work in this launch: one stored as running was stopped with the last.
        check.agentState = "running"
        model.selectedProjectID = alpha.id
        return (model, build, docs, lead, check, site)
    }

    private func permission(_ requestId: String, in chat: Chat, command: String, model: AppModel) {
        model.route(EngineEvent(name: "ask", threadId: chat.id.uuidString, body: [
            "event": "ask", "requestId": .string(requestId), "kind": "permission", "tool": "Bash", "input": ["command": .string(command)],
        ]))
    }

    private func workerQuestion(_ requestId: String, in head: Chat, model: AppModel) {
        model.route(EngineEvent(name: "ask", threadId: head.id.uuidString, body: [
            "event": "ask", "requestId": .string(requestId), "kind": "question", "tool": "AskUserQuestion",
            "input": ["questions": [["question": "Which colour?", "options": [["label": "Red"], ["label": "Blue"]]]]],
            "options": [["question": "Which colour?", "options": [["label": "Red"], ["label": "Blue"]]]],
            "agentId": "w-key", "worker": ["id": "worker-1", "agent": "claude", "label": "Check"],
        ]))
    }

    @Test func twoApprovalsAndAWorkersQuestionAreThreeEntriesOldestFirst() throws {
        let (model, build, docs, lead, check, _) = try model()
        #expect(model.waitingAsks.isEmpty)
        // Their ids run against the order they came in, which is the queue's.
        permission("c", in: build, command: "make", model: model)
        permission("b", in: docs, command: "ls", model: model)
        workerQuestion("a", in: lead, model: model)

        let queue = model.waitingAsks
        #expect(queue.map(\.id) == ["c", "b", "a"])
        #expect(queue.map(\.thread.title) == ["Build", "Docs", "Check"])
        // The worker's question is counted at its own thread and answered in its head's.
        #expect(queue[2].holder.id == lead.id)
        #expect(model.asksByThread == [build.id: 1, docs.id: 1, check.id: 1])
        #expect(model.waitingCount == 3)
        #expect(model.status(of: check) == OverviewStatus(state: .waiting, step: nil))
        // Lead works on while its worker asks.
        #expect(model.status(of: lead).state != .waiting)
        // Each waiting thread, and the head for its worker, is on the screen under the queue.
        #expect(Set(model.overview.flatMap(\.rows).map(\.chat.title)) == ["Lead", "Check", "Docs", "Build"])
    }

    @Test func anAnswerFromTheQueueOrInsideItsThreadTakesTheAskOut() throws {
        let (model, build, docs, _, _, site) = try model()
        permission("one", in: build, command: "make", model: model)
        permission("two", in: docs, command: "ls", model: model)
        permission("three", in: site, command: "pwd", model: model)

        // From the queue, as its Allow does: in the thread that waits, which isn't the open one.
        let first = try #require(model.waitingAsks.first)
        model.answer(first.ask, in: first.holder.id, allow: true)
        #expect(model.waitingAsks.map(\.id) == ["two", "three"])
        #expect(model.conversations[build.id]?.waitingAsk == nil)

        // Inside its own thread, open, from its card, which answers the open thread's ask.
        model.select(docs)
        let card = try #require(model.conversations[docs.id]?.waitingAsk)
        model.answer(card, allow: false)
        #expect(model.waitingAsks.map(\.id) == ["three"])
        // And one the agent gave up on.
        model.route(EngineEvent(name: "ask.cancelled", threadId: site.id.uuidString, body: ["event": "ask.cancelled", "requestId": "three"]))
        #expect(model.waitingAsks.isEmpty)
        #expect(model.waitingCount == 0)
    }

    @Test func aNotificationsClickOpensTheScreenOnItsAskOrItsThreadOnceAnswered() throws {
        let (model, build, docs, _, _, _) = try model()
        permission("one", in: build, command: "make", model: model)
        permission("two", in: docs, command: "ls", model: model)

        model.notifier.clicked(chat: docs.id.uuidString, ask: "two")
        #expect(model.overviewShown)
        #expect(model.overviewAsk == "two")
        // The screen going takes the light with it.
        model.closeOverview()
        #expect(model.overviewAsk == nil)

        model.answer(try #require(model.waitingAsks.first { $0.id == "two" }).ask, in: docs.id, allow: true)
        model.notifier.clicked(chat: docs.id.uuidString, ask: "two")
        #expect(!model.overviewShown)
        #expect(model.selectedChatID == docs.id)
    }

    @Test func waitingOnYouListsTheTopThreadAWorkerAsksUnder() throws {
        let (model, _, _, lead, check, _) = try model()
        workerQuestion("a", in: lead, model: model)
        model.drawerFilter = .waiting
        // The worker has no row, so its head's does for it, its ask still counted at the worker.
        #expect(model.listedChats.map(\.id) == [lead.id])
        #expect(model.asksByThread[check.id] == 1)
    }

    @Test func aWorkerThatEndedLeavesItsAskToItsHead() throws {
        let (model, _, _, lead, check, _) = try model()
        workerQuestion("a", in: lead, model: model)
        check.agentState = "stopped"
        #expect(model.waitingAsks.map(\.thread.id) == [lead.id])
        #expect(model.status(of: check).state == .stopped)
        #expect(model.status(of: lead).state == .waiting)
    }

    @Test func anAskFromAnAgentToldOfAfterItIsCountedAtItOnceItIs() throws {
        let (model, build, _, _, _, _) = try model()
        model.route(EngineEvent(name: "ask", threadId: build.id.uuidString, body: [
            "event": "ask", "requestId": "s", "kind": "permission", "tool": "Bash", "input": ["command": "ls"], "agentId": "sub-1",
        ]))
        #expect(model.waitingAsks.map(\.thread.id) == [build.id])
        model.route(EngineEvent(name: "agent.thread", threadId: build.id.uuidString, body: [
            "agentId": "sub-1", "label": "Look around", "kind": "subagent", "state": "running",
        ]))
        let thread = try #require(model.waitingAsks.first?.thread)
        #expect(thread.id != build.id && thread.openedBy == build.id && thread.agentID == "sub-1")
    }

    @Test func aWorkflowAgentsAskIsOnItsCardAndNotInItsLeadsTranscript() throws {
        let (model, build, _, _, _, _) = try model()
        let tests = Chat(project: try #require(build.project), title: "tests")
        tests.started = true
        tests.openedBy = build.id
        tests.agentID = "a-tests"
        tests.agentState = "running"
        model.context.insert(tests)
        model.route(EngineEvent(name: "ask", threadId: build.id.uuidString, body: [
            "event": "ask", "requestId": "t", "kind": "permission", "tool": "Bash", "input": ["command": "swift test"],
            "toolUseId": "call-t", "agentId": "a-tests",
        ]))
        let lead = model.conversation(for: build)
        // Nothing in the lead's transcript; the card has it, and the queue lists it as ever.
        #expect(lead.waitingAsks.map(\.staged) == [true])
        #expect(!TranscriptEntry.fold(lead.items).contains { if case .item(.ask) = $0 { true } else { false } })
        #expect(RunStage.asks(lead.waitingAsks).keys.sorted() == ["a-tests"])
        #expect(model.waitingAsks.map(\.thread.id) == [tests.id])
        // Answered, it leaves no line there either.
        model.answer(try #require(lead.waitingAsk), in: build.id, allow: true)
        #expect(lead.waitingAsks.isEmpty)
        #expect(!TranscriptEntry.fold(lead.items).contains { if case .item(.ask) = $0 { true } else { false } })
    }

    @Test func aSubagentsAskStaysInItsHoldersTranscript() throws {
        let (model, build, _, _, _, _) = try model()
        model.route(EngineEvent(name: "agent.thread", threadId: build.id.uuidString, body: [
            "agentId": "sub-1", "label": "Look around", "kind": "subagent", "state": "running",
        ]))
        model.route(EngineEvent(name: "ask", threadId: build.id.uuidString, body: [
            "event": "ask", "requestId": "s", "kind": "permission", "tool": "Bash", "input": ["command": "ls"], "agentId": "sub-1",
        ]))
        let lead = model.conversation(for: build)
        #expect(lead.waitingAsks.map(\.staged) == [false])
        #expect(TranscriptEntry.fold(lead.items).contains { if case .item(.ask) = $0 { true } else { false } })
    }

    @Test func anAskFromASubagentTheAppHasNoThreadForIsItsHoldersOwn() throws {
        let (model, build, _, _, _, _) = try model()
        model.route(EngineEvent(name: "ask", threadId: build.id.uuidString, body: [
            "event": "ask", "requestId": "s", "kind": "permission", "tool": "Bash", "input": ["command": "ls"], "agentId": "unknown",
        ]))
        #expect(model.waitingAsks.map(\.thread.id) == [build.id])
    }
}
