import Foundation
import SwiftData
import Testing
@testable import OriCode

/// merge_thread as the app answers it, and the line two working threads get when they edit the
/// same file. The git is the engine's, and engine/test/merge.test.ts runs it.
@MainActor
struct MergingTests {
    private let container: ModelContainer
    private let project: Project
    private let folder: URL

    init() throws {
        container = try TestStore.memory()
        folder = FileManager.default.temporaryDirectory.appending(path: "oricode-merging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: ".worktrees/t-x"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: ".worktrees/t-y"), withIntermediateDirectories: true)
        project = Project(name: "alpha", path: folder.path)
        container.mainContext.insert(project)
        try container.mainContext.save()
    }

    /// A model with a parent thread in alpha and two threads it opened, each in a worktree.
    private func model() throws -> (AppModel, parent: Chat, x: Chat, y: Chat) {
        let model = AppModel(container: container)
        model.support = FileManager.default.temporaryDirectory.appending(path: "oricode-merging-\(UUID().uuidString)", directoryHint: .isDirectory)
        model.providers = [.claude]
        func thread(_ title: String, in worktree: String? = nil, openedBy: Chat? = nil) -> Chat {
            let chat = Chat(project: project, title: title, permissionMode: "default")
            chat.provider = "claude"
            chat.started = true
            chat.titleIsCustom = true
            chat.openedBy = openedBy?.id
            if let worktree {
                chat.cwd = folder.appending(path: ".worktrees/\(worktree)").path
                chat.worktreeBranch = "oricode/\(worktree)"
            }
            container.mainContext.insert(chat)
            return chat
        }
        let parent = thread("Sums")
        let x = thread("Name it plus", in: "t-x", openedBy: parent)
        let y = thread("Name it add", in: "t-y", openedBy: parent)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = parent.id
        return (model, parent, x, y)
    }

    private func refusal(_ body: () throws -> Any) -> String? {
        do {
            _ = try body()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func acts(_ conversation: Conversation) -> [String] {
        conversation.items.compactMap { item in
            if case .act(_, _, let text) = item { text } else { nil }
        }
    }

    private func event(_ name: String, _ chat: Chat, _ body: JSON = [:]) -> EngineEvent {
        EngineEvent(name: name, threadId: chat.id.uuidString, body: body)
    }

    @Test func aMergeIsOfAThreadThisOneOpenedInAWorktreeOnceItsTurnIsOver() throws {
        let (model, parent, x, y) = try model()
        let target = try model.mergeTarget(x.id.uuidString, from: parent.id)
        #expect(target == ["id": .string(x.id.uuidString), "title": "Name it plus", "folder": .string(folder.path), "worktree": .string(x.cwd), "branch": "oricode/t-x"])
        // Not one another opened, nor one beside it, nor one at work, nor one whose worktree went.
        #expect(refusal { try model.mergeTarget(parent.id.uuidString, from: x.id) } == "Sums wasn't opened by this thread with open_thread, so it isn't this thread's to merge.")
        y.worktreeBranch = nil
        y.cwd = parent.cwd
        #expect(refusal { try model.mergeTarget(y.id.uuidString, from: parent.id) } == "Name it add works in this thread's folder, so its edits are here already.")
        model.route(event("turn.started", x))
        #expect(refusal { try model.mergeTarget(x.id.uuidString, from: parent.id) } == "Name it plus is still working. Wait for it with wait_thread, or stop it, first.")
        model.route(event("turn.done", x, ["stopReason": "end_turn"]))
        try FileManager.default.removeItem(at: folder.appending(path: ".worktrees/t-x"))
        #expect(refusal { try model.mergeTarget(x.id.uuidString, from: parent.id) } == "Name it plus's worktree isn't at \(x.cwd) any more.")
    }

    @Test func aThreadOnPlanOrTighterThanTheOneItMergesIsRefused() throws {
        let (model, parent, x, _) = try model()
        parent.permissionMode = "plan"
        #expect(refusal { try model.mergeTarget(x.id.uuidString, from: parent.id) } == "This thread is on Plan, which edits no files, and a merge writes them into its folder. Ask the user to take it off Plan first.")
        parent.permissionMode = "default"
        x.permissionMode = "bypassPermissions"
        #expect(refusal { try model.mergeTarget(x.id.uuidString, from: parent.id) } == "Name it plus is on Don't ask, looser than this thread, which is on Ask, so its edits don't come in from here. Ask the user to merge it.")
        x.permissionMode = "acceptEdits"
        parent.permissionMode = "acceptEdits"
        #expect(refusal { try model.mergeTarget(x.id.uuidString, from: parent.id) } == nil)
    }

    @Test func aWorktreeGoesWithItsThreadsAgentsAndTheThreadsItMergedButNotWithAnotherThread() throws {
        let (model, parent, x, _) = try model()
        #expect(model.followers(of: x) == [])
        // A Task subagent of its own, and a thread it opened and merged, which works there since.
        let agent = Chat(project: project, title: "Explore", permissionMode: "default")
        agent.cwd = x.cwd
        agent.openedBy = x.id
        agent.agentID = "a1"
        agent.agentState = "done"
        let merged = Chat(project: project, title: "Tests", permissionMode: "default")
        merged.cwd = x.cwd
        merged.openedBy = x.id
        let mergedAgent = Chat(project: project, title: "Explore again", permissionMode: "default")
        mergedAgent.cwd = x.cwd
        mergedAgent.openedBy = merged.id
        mergedAgent.agentID = "a2"
        for chat in [agent, merged, mergedAgent] { container.mainContext.insert(chat) }
        try container.mainContext.save()
        #expect(Set(model.followers(of: x)?.map(\.id) ?? []) == [agent.id, merged.id, mergedAgent.id])
        // Not while one of them works.
        agent.agentState = "running"
        #expect(model.followers(of: x) == nil)
        agent.agentState = "done"
        // Nor with a thread there that isn't under it, its opener included.
        let beside = Chat(project: project, title: "Beside", permissionMode: "default")
        beside.cwd = x.cwd
        beside.openedBy = parent.id
        container.mainContext.insert(beside)
        try container.mainContext.save()
        #expect(model.followers(of: x) == nil)
    }

    @Test func whatCameInIsALineInBothAndAWorktreeWithWorkLeftInItStays() async throws {
        let (model, parent, x, _) = try model()
        let answer = try await model.merged(["thread": .string(x.id.uuidString), "summary": "2 files, +4 −2", "unmerged": true], from: parent.id)
        #expect(answer == ["worktreeRemoved": false, "worktreeNote": "Its worktree stays, since it has work the merge didn't take."])
        #expect(acts(model.conversation(for: parent)) == ["Merged Name it plus · 2 files, +4 −2"])
        // The merged thread wasn't in memory: its line is stored after its last event.
        #expect(acts(Conversation(chat: x, context: container.mainContext)) == ["Sums merged this thread's work"])
        #expect(x.worktreeBranch == "oricode/t-x")
        // A file git ignores that the merge couldn't take is named.
        let ignored = try await model.merged(["thread": .string(x.id.uuidString), "summary": "1 file, +1 −0", "unmerged": true, "ignored": [".env"]], from: parent.id)
        #expect(ignored["worktreeNote"] == "Its worktree stays, since it has work the merge didn't take: .env, which git ignores.")
        // One another thread works in too stays whatever the engine says.
        let beside = Chat(project: project, title: "Beside", permissionMode: "default")
        beside.cwd = x.cwd
        container.mainContext.insert(beside)
        try container.mainContext.save()
        let shared = try await model.merged(["thread": .string(x.id.uuidString), "summary": "No files changed", "unmerged": false], from: parent.id)
        #expect(shared["worktreeRemoved"] == false && shared["worktreeNote"] == "Its worktree stays, since another thread works in it.")
    }

    @Test func twoWorkingThreadsEditingOneFileEachGetALineAndTheirOpenerHearsIt() async throws {
        let (model, parent, x, y) = try model()
        let other = Chat(project: project, title: "Idle", permissionMode: "default")
        other.started = true
        container.mainContext.insert(other)
        for chat in [x, y, parent] { model.route(event("turn.started", chat)) }
        func edit(_ chat: Chat, _ file: String, _ id: String) {
            model.route(event("tool.use", chat, ["toolUseId": .string(id), "name": "Edit", "input": ["file_path": .string((chat.cwd as NSString).appendingPathComponent(file)), "old_string": "a", "new_string": "b"]]))
            model.route(event("tool.result", chat, ["toolUseId": .string(id), "content": "ok"]))
        }
        edit(x, "sum.py", "x1")
        edit(x, "README.md", "x2")
        // Another file in the other worktree is no overlap; the same path from its own folder is.
        edit(y, "words.sh", "y1")
        #expect(model.conversations[x.id]?.sameFiles.isEmpty == true)
        edit(y, "sum.py", "y2")
        // Said once a turn for the pair and the file.
        edit(y, "sum.py", "y3")
        edit(x, "sum.py", "x3")
        #expect(model.conversations[x.id]?.sameFiles.map(\.path) == ["sum.py"])
        #expect(model.conversations[y.id]?.sameFiles.map(\.title) == ["Name it plus"])
        // A failed edit changed nothing.
        model.route(event("tool.use", y, ["toolUseId": "y4", "name": "Edit", "input": ["file_path": .string(y.cwd + "/README.md")]]))
        model.route(event("tool.result", y, ["toolUseId": "y4", "content": "no match", "isError": true]))
        #expect(model.conversations[y.id]?.sameFiles.count == 1)
        // Each line waits for its thread's turn to end.
        #expect(acts(model.conversation(for: x)).isEmpty)
        for chat in [x, y, parent] { model.route(event("turn.done", chat, ["stopReason": "end_turn"])) }
        #expect(acts(model.conversation(for: x)) == ["sum.py: Name it add is editing it too"])
        #expect(acts(model.conversation(for: y)) == ["sum.py: Name it plus is editing it too"])
        #expect(acts(model.conversation(for: parent)) == ["sum.py: Name it add and Name it plus are both editing it"])
        #expect(acts(Conversation(chat: parent, context: container.mainContext)) == ["sum.py: Name it add and Name it plus are both editing it"])
        // The opener waiting on either hears it.
        let waited = try await model.wait(on: x.id.uuidString, from: parent.id)
        #expect(waited["sameFiles"] == [["path": "sum.py", "thread": "Name it add", "id": .string(y.id.uuidString)]])
        // A new turn starts clean.
        model.route(event("turn.started", x))
        #expect(model.conversations[x.id]?.sameFiles.isEmpty == true)
    }
}
