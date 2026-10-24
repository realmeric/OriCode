import Foundation
import SwiftData
import Testing
@testable import OriCode

/// What a thread sets going besides a workflow, on its stage's column: which calls stand for the
/// cards, which heads are cards, and how the column comes and goes.
@MainActor
struct LaneTests {
    private func call(_ id: String, _ name: String, _ input: JSON, result: String? = nil) -> Item {
        .tool(id: UUID(), call: ToolCall(toolUseId: id, name: name, input: input, result: result))
    }

    @Test func theCallsThatStartCardsAreARowOfTheirOwn() {
        let items: [Item] = [
            call("r1", "Read", ["file_path": "/tmp/a.swift"]),
            call("r2", "Read", ["file_path": "/tmp/b.swift"]),
            call("s1", "Agent", ["description": "Trace SyncSession", "prompt": "Look", "run_in_background": true]),
            call("s2", "Agent", ["description": "Profile Store.load", "prompt": "Look", "run_in_background": true]),
            call("c1", "Bash", ["command": "swift test --filter SyncTests", "run_in_background": true]),
            call("c2", "Bash", ["command": "ls"]),
        ]
        let entries = TranscriptEntry.fold(items)
        let shape = entries.map { entry -> String in
            switch entry {
            case .run(let items): "run of \(items.count)\(items.contains(where: \.startsCard) ? " starting" : "")"
            case .item(let item): item.startsCard ? "starting" : "item"
            }
        }
        // The reads just before them join their line, which says only what was set going.
        #expect(shape == ["run of 5 starting", "item"])
        guard case .run(let starting) = entries[0] else { return }
        let calls = starting.compactMap { item -> ToolCall? in if case .tool(_, let call) = item { call } else { nil } }
        #expect(StageCallsRow.words(calls.filter(\.startsCard)) == "Started 2 agents, ran a command")
    }

    @Test func aPlanThatTookTwoTriesIsPlannedOnce() {
        let tasks: JSON = ["run": true, "tasks": [["title": "A"], ["title": "B"], ["title": "C"], ["title": "D"]]]
        let items: [Item] = [
            .tool(id: UUID(), call: ToolCall(toolUseId: "p1", name: "mcp__oricode__add_tasks", input: tasks, result: "No such model", isError: true)),
            call("l", "mcp__oricode__list_agents", [:]),
            call("p2", "mcp__oricode__add_tasks", tasks),
        ]
        let entries = TranscriptEntry.fold(items)
        #expect(entries.count == 1)
        guard case .run(let run) = entries.first else { return }
        let calls = run.compactMap { item -> ToolCall? in if case .tool(_, let call) = item { call } else { nil } }
        #expect(StageCallsRow.words(calls.filter(\.startsCard)) == "Planned 4 tasks")
    }

    @Test func aPlanAndAWorkerAreSaidInTheirOwnWords() {
        let plan = ToolCall(toolUseId: "p", name: "mcp__oricode__add_tasks", input: ["run": true, "tasks": [["title": "A"], ["title": "B"], ["title": "C"], ["title": "D"]]])
        #expect(plan.startsCard && StageCallsRow.words([plan]) == "Planned 4 tasks")
        // A plan kept and not run has no cards.
        #expect(!ToolCall(toolUseId: "q", name: "mcp__oricode__add_tasks", input: ["tasks": [["title": "A"]]]).startsCard)
        let worker = ToolCall(toolUseId: "w", name: "mcp__oricode__start_worker", input: ["title": "Check the cache"], result: #"{"worker":"worker-1"}"#)
        #expect(worker.startsCard && worker.startedWorker == "worker-1")
        #expect(ToolSummary.run([worker, worker], starting: true) == "Started a worker")
    }

    @Test func subagentsCommandsWorkersAPlanAndOpenedThreadsAreTheColumnsCards() throws {
        let container = try TestStore.memory()
        let context = container.mainContext
        let project = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(project)
        let lead = Chat(project: project, title: "Lead")
        lead.started = true
        context.insert(lead)
        try context.save()
        let model = AppModel(container: container)
        func send(_ name: String, _ body: JSON, to chat: Chat) {
            model.route(EngineEvent(name: name, threadId: chat.id.uuidString, body: body))
        }
        send("tool.use", ["toolUseId": "call-s1", "name": "Agent", "input": ["description": "Trace SyncSession", "prompt": "Look", "run_in_background": true]], to: lead)
        send("tool.use", ["toolUseId": "call-c1", "name": "Bash", "input": ["command": "swift test --filter SyncTests", "run_in_background": true]], to: lead)
        // A head the CLI lists before it names the call, a workflow agent's command that isn't in
        // this transcript, and a worker.
        send("heads", ["heads": [
            ["id": "s1", "kind": "agent", "label": "Trace SyncSession", "startedAt": 1000],
            ["id": "c1", "kind": "command", "toolUseId": "call-c1", "label": "Run the sync tests", "startedAt": 2000],
            ["id": "x1", "kind": "command", "toolUseId": "call-elsewhere", "label": "sleep 20", "startedAt": 2500],
            ["id": "w1", "kind": "agent", "label": "Check the cache", "startedAt": 3000, "worker": true, "agent": "claude"],
        ]], to: lead)
        let conversation = model.conversation(for: lead)
        #expect(model.liveLane(of: conversation).map(\.id) == ["c1", "w1"])
        send("heads", ["heads": [
            ["id": "s1", "kind": "agent", "toolUseId": "call-s1", "label": "Trace SyncSession", "startedAt": 1000],
            ["id": "c1", "kind": "command", "toolUseId": "call-c1", "label": "Run the sync tests", "startedAt": 2000],
            ["id": "w1", "kind": "agent", "label": "Check the cache", "startedAt": 3000, "worker": true, "agent": "claude"],
        ]], to: lead)
        send("agent.thread", ["agentId": "s1", "kind": "subagent", "label": "Trace SyncSession", "state": "running"], to: lead)
        send("agent.thread", ["agentId": "w1-key", "task": "w1", "kind": "worker", "label": "Check the cache", "state": "running", "agent": "claude"], to: lead)
        let cards = model.liveLane(of: conversation)
        #expect(cards.map(\.label) == ["Trace SyncSession", "swift test --filter SyncTests", "Check the cache"])
        #expect(cards.map(\.kind) == [.subagent, .command, .worker])
        // A subagent and a worker are stepped into; a command isn't.
        #expect(cards[0].thread != nil && cards[2].thread != nil && cards[1].thread == nil)
        #expect(cards[1].started(by: ToolCall(toolUseId: "call-c1", name: "Bash", input: [:])))

        // A plan of four, the first done and its thread's turn over, two at work, one waiting.
        let threads = (0..<3).map { index in
            let chat = Chat(project: project, title: "Task \(index + 1)")
            chat.openedBy = lead.id
            chat.createdAt = Date(timeIntervalSince1970: 4000 + Double(index))
            context.insert(chat)
            return chat
        }
        for (number, title, state) in [(1, "Write the v2 migration", "done"), (2, "Move Store to the v2 schema", "working"),
                                       (3, "Note v2 in CHANGELOG", "working"), (4, "Write migration tests", "open")] {
            let task = PlanTask(number: number, title: title, doneWhen: "", waitsOn: number == 4 ? [2] : [])
            task.project = project
            task.owner = lead.id
            task.state = state
            task.thread = number <= 3 ? threads[number - 1].id : nil
            context.insert(task)
        }
        // A thread it opened by hand, at work.
        let opened = Chat(project: project, title: "Look over Cache.swift")
        opened.openedBy = lead.id
        opened.createdAt = Date(timeIntervalSince1970: 5000)
        context.insert(opened)
        send("turn.started", [:], to: opened)
        // In the order they started, as the stage lays them out.
        let all = model.liveLane(of: conversation).sorted { $0.startedAt < $1.startedAt }
        #expect(all.map(\.label).suffix(5) == ["Write the v2 migration", "Move Store to the v2 schema", "Note v2 in CHANGELOG",
                                               "Look over Cache.swift", "Write migration tests"])
        #expect(all.suffix(5).map(\.state) == [.done, .running, .running, .running, .queued])
        // Opened by hand or by the plan, a thread's card is the thread itself.
        #expect(all.first { $0.kind == .opened }?.thread == opened.id)
    }

    @Test func aHeadLearnsTheCallThatStartedItAfterItCame() throws {
        let container = try TestStore.memory()
        let context = ModelContext(container)
        let project = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(project)
        let chat = Chat(project: project)
        context.insert(chat)
        let conversation = Conversation(chat: chat, context: context)
        func heads(_ head: JSON) {
            conversation.receive(EngineEvent(name: "heads", threadId: chat.id.uuidString, body: ["event": "heads", "heads": [head]]))
        }
        heads(["id": "b1", "kind": "command", "label": "Run the tests"])
        #expect(conversation.heads.list.first?.toolUseId == nil)
        heads(["id": "b1", "kind": "command", "toolUseId": "call-b1", "label": "Run the tests", "step": .null, "lines": ["one", "two"]])
        #expect(conversation.heads.list.first?.toolUseId == "call-b1")
        #expect(conversation.heads.list.first?.lines == ["one", "two"])
    }

    @Test func theColumnGrowsWithItsFirstCardKeepsWhatEndedAndFoldsOnceAllHave() async throws {
        let stage = StageModel()
        let lead = UUID()
        func card(_ id: String, _ state: LaneCard.State, at: Double) -> LaneCard {
            LaneCard(id: id, kind: .subagent, label: id, state: state, startedAt: Date(timeIntervalSince1970: at), call: nil, thread: nil, agent: "claude", ray: 0)
        }
        stage.lane([card("a", .running, at: 1), card("b", .running, at: 2)], in: lead, grow: true)
        #expect(stage.shown[lead] == StageModel.laneKey)
        // One ends: its card stays, ended, in its place.
        stage.lane([card("b", .running, at: 2)], in: lead, grow: true)
        #expect(stage.lanes[lead]?.map(\.id) == ["a", "b"] && stage.lanes[lead]?.first?.state == .done)
        // Folded by hand while it works, a new card doesn't grow it again.
        _ = stage.fold(lead)
        stage.lane([card("b", .running, at: 2), card("c", .running, at: 3)], in: lead, grow: true)
        #expect(stage.shown[lead] == nil && stage.lanes[lead]?.count == 3)
        stage.toggle(StageModel.laneKey, in: lead)
        stage.lane([], in: lead, grow: true)
        #expect(stage.shown[lead] == StageModel.laneKey)
        try await Task.sleep(for: StageModel.lingering + .milliseconds(200))
        #expect(stage.shown[lead] == nil && stage.lanes[lead] == nil)
        // Grown in a transcript read further up, it stays folded.
        stage.lane([card("d", .running, at: 4)], in: lead, grow: false)
        #expect(stage.shown[lead] == nil && stage.lanes[lead]?.count == 1)
    }
}
