import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A head and its workers: which agents a thread's workers may use, what they cost it, what they
/// ask, and which ray the review says changed what.
@MainActor
struct RaysTests {
    private let container: ModelContainer
    private let chat: Chat
    private let model: AppModel

    private static func agent(_ id: String, _ name: String, state: ProviderInfo.State = .ready, workers: Bool? = true) -> ProviderInfo {
        ProviderInfo(
            id: id, name: name, agent: name, state: state, hint: nil, cli: "/usr/local/bin/\(id)", version: "1.0",
            capabilities: ProviderInfo.Capabilities(
                steer: true, resume: true, modeLive: false, attachments: false, heads: false, stopTask: false, limits: false,
                usage: false, commands: false, compact: false, commitMessage: false, handoff: nil, workers: workers),
            levels: [], modes: ["default"])
    }

    static let codex = agent("codex", "Codex")
    static let opencode = agent("opencode", "OpenCode")
    static let pi = agent("pi", "Pi", workers: nil)
    static let cursor = agent("cursor", "Cursor", state: .signedOut)

    init() throws {
        container = try ModelContainer(for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project)
        chat.started = true
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model = AppModel(container: container)
        model.providers = [.claude, Self.codex, Self.opencode, Self.pi, Self.cursor]
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        UserDefaults.standard.removeObject(forKey: Rays.allowKey)
    }

    private func receive(_ name: String, _ body: [String: JSON]) {
        model.conversation(for: chat).receive(EngineEvent(name: name, threadId: chat.id.uuidString, body: .object(body)))
    }

    private func sent() -> [String: JSON] {
        model.sendParams(in: chat, text: "Go", images: [])
    }

    @Test func aThreadsWorkersMayUseEveryReadyAgentUntilItsPairIsPicked() {
        // Every agent hello found ready, a signed-out one left out, the thread's own included.
        #expect(model.workers(for: chat) == ["claude", "codex", "opencode", "pi"])
        #expect(sent()["workers"] == ["claude", "codex", "opencode", "pi"])
        #expect(WorkersMenu.line(picked: model.workers(for: chat), chosen: false, agents: model.workerAgents) == "Workers may use any ready agent")

        model.setWorkers(["opencode", "codex", "cursor"], for: chat)
        #expect(model.workers(for: chat) == ["opencode", "codex"])
        #expect(sent()["workers"] == ["opencode", "codex"])
        #expect(WorkersMenu.line(picked: model.workers(for: chat), chosen: true, agents: model.workerAgents) == "Workers may use: Codex, OpenCode")

        model.setWorkers([], for: chat)
        #expect(model.workers(for: chat).isEmpty)
        #expect(sent()["workers"] == nil)
        #expect(WorkersMenu.line(picked: [], chosen: true, agents: model.workerAgents) == "Workers: none")

        model.setWorkers(nil, for: chat)
        #expect(model.workers(for: chat).count == 4)
    }

    @Test func noHeadWithoutSettingsOrAnAgentThatTakesTheTools() {
        UserDefaults.standard.set(false, forKey: Rays.allowKey)
        defer { UserDefaults.standard.removeObject(forKey: Rays.allowKey) }
        #expect(!model.offersWorkers(chat))
        #expect(model.workers(for: chat).isEmpty)
        #expect(sent()["workers"] == nil)
        UserDefaults.standard.removeObject(forKey: Rays.allowKey)
        #expect(model.showsHeads(chat))
        // Pi takes no MCP, so a thread on it is no head.
        chat.provider = "pi"
        #expect(!model.offersWorkers(chat))
        #expect(!model.showsHeads(chat))
        #expect(sent()["workers"] == nil)
        // Codex reports no heads of its own, but its workers are heads, so ⌘I opens.
        chat.provider = "codex"
        #expect(model.showsHeads(chat))
    }

    @Test func aWorkersCostIsTheThreadsAndNotItsSessions() throws {
        let conversation = model.conversation(for: chat)
        conversation.userSent("Have Codex write a test")
        receive("turn.done", ["stopReason": "end_turn", "costUSD": .number(0.5)])
        receive("worker", ["worker": "worker-1", "agent": "codex", "label": "write a test", "costUSD": .number(0.25), "files": []])
        #expect(abs(chat.costUSD - 0.75) < 1e-9)
        #expect(conversation.workerCost == 0.25)
        #expect(sent()["costSoFar"] == .number(0.5))
        // Read back from the store, the worker's share is known again.
        let again = Conversation(chat: chat, context: container.mainContext)
        #expect(again.workerCost == 0.25)
    }

    @Test func aWorkersAskIsTheThreadsLabelledWithItsAgentAndTask() {
        receive("ask", ["requestId": "r1", "kind": "permission", "tool": "Run", "toolKind": "run", "view": ["command": "npm test"], "input": [:],
                        "worker": ["id": "worker-2", "agent": "opencode", "label": "review the test"]])
        let ask = model.conversation(for: chat).waitingAsk
        #expect(ask?.worker == PendingAsk.Worker(agent: "opencode", label: "review the test"))
        #expect(ask?.toolKind == .run)
    }

    @Test func aWorkerIsAHeadOnItsAgentWithItsModelAndCost() {
        receive("heads", ["heads": [["id": "worker-1", "kind": "agent", "label": "write a test", "startedAt": .number(1), "worker": true, "agent": "codex",
                                     "model": "gpt-6-luna", "step": ["tool": "Write", "detail": "greet.test.ts"], "tokens": .number(520), "tools": .number(1), "cost": .number(0.02)]]])
        let head = model.conversation(for: chat).heads.list.first
        #expect(head?.worker == true)
        #expect(head?.agent == "codex")
        #expect(head?.model == "gpt-6-luna")
        #expect(head?.cost == 0.02)
        #expect(model.conversation(for: chat).heads.rayAgents.values.contains("codex"))
    }

    @Test func theReviewSaysWhichRayChangedWhat() {
        let conversation = model.conversation(for: chat)
        conversation.userSent("Write greet and have Codex test it")
        receive("tool.use", ["toolUseId": "e1", "name": "Write", "input": ["file_path": "/tmp/alpha/greet.ts", "content": "hi"]])
        receive("tool.result", ["toolUseId": "e1", "content": "ok", "patch": [["oldStart": .number(0), "newStart": .number(1), "lines": ["+export const greet = 1"]]]])
        receive("worker", ["worker": "worker-1", "agent": "codex", "label": "write greet.test.ts", "costUSD": .number(0), "merged": "oricode/ray-1",
                           "files": [["path": "/tmp/alpha/greet.test.ts", "hunks": [["oldStart": .number(0), "newStart": .number(1), "lines": ["+test('greets')"]]]]]])
        receive("turn.done", ["stopReason": "end_turn"])

        let found = Provenance(items: conversation.items, rayEdits: conversation.rayEdits) { RepoPath.relative($0, cwd: "/tmp/alpha", root: "/tmp/alpha") }
        let ray = Provenance.Ray(agent: "codex", label: "write greet.test.ts")
        #expect(found.turn(of: "+test('greets')", in: "greet.test.ts") == 1)
        #expect(found.ray(of: "greet.test.ts", in: 1) == ray)
        #expect(found.ray(of: "greet.ts", in: 1) == nil)
        // The head's own file first, the worker's after it, both under the turn's message.
        #expect(found.rank(of: "greet.ts", in: 1) == 0)
        #expect(found.rank(of: "greet.test.ts", in: 1) == 1)

        let hunk = { (line: String) in DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 1, context: "", lines: [line]) }
        let file = { (path: String, line: String) in
            FileDiff(path: path, oldPath: nil, status: "?", binary: false, executable: false, hunks: [hunk(line)], added: 1, deleted: 0,
                     cut: false, stamp: nil, lossy: false)
        }
        let diff = WorkingDiff(root: "/tmp/alpha", head: nil, files: [file("greet.test.ts", "+test('greets')"), file("greet.ts", "+export const greet = 1")])
        let book = ReviewBook(diff: diff, provenance: found)
        #expect(book.chapters.map(\.turn) == [1])
        #expect(book.chapters[0].files.map(\.file.path) == ["greet.ts", "greet.test.ts"])
        #expect(book.chapters[0].files.map(\.ray) == [nil, ray])
    }
}
