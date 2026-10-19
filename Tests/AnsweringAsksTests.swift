import Foundation
import SwiftData
import Testing
@testable import OriCode

/// An ask from a thread another thread set going goes to that thread first (K-296): what it may
/// allow by its own mode, what it answers, what it passes up, and what stays the user's.
@MainActor
@Suite(.serialized)
final class AnsweringAsksTests {
    private let container: ModelContainer
    private let project: Project
    /// The switch is read from the test host's own defaults, which Settings may have turned off.
    private let switchBefore = UserDefaults.standard.object(forKey: AppModel.openersAnswerKey) as? Bool

    init() throws {
        container = try TestStore.memory()
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        try container.mainContext.save()
        UserDefaults.standard.set(true, forKey: AppModel.openersAnswerKey)
    }

    deinit {
        if let switchBefore { UserDefaults.standard.set(switchBefore, forKey: AppModel.openersAnswerKey) } else { UserDefaults.standard.removeObject(forKey: AppModel.openersAnswerKey) }
    }

    /// Lead on `mode`, working, which set Rename going on Ask in a worktree of its own.
    private func model(mode: String = "acceptEdits") throws -> (AppModel, lead: Chat, child: Chat) {
        let model = AppModel(container: container)
        model.support = FileManager.default.temporaryDirectory.appending(path: "oricode-answering-\(UUID().uuidString)", directoryHint: .isDirectory)
        model.providers = [.claude]
        let lead = Chat(project: project, title: "Lead", permissionMode: mode)
        lead.provider = "claude"
        lead.started = true
        lead.titleIsCustom = true
        let child = Chat(project: project, title: "Rename", permissionMode: "default")
        child.provider = "claude"
        child.started = true
        child.titleIsCustom = true
        child.cwd = "/tmp/alpha-wt"
        child.worktreeBranch = "oricode/rename"
        child.openedBy = lead.id
        child.turnFrom = lead.id
        container.mainContext.insert(lead)
        container.mainContext.insert(child)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = lead.id
        model.conversation(for: lead).userSent("Rename sum to plus in a thread of its own.")
        model.conversation(for: child).userSent("Rename sum to plus.")
        return (model, lead, child)
    }

    private func ask(_ requestId: String, in chat: Chat, tool: String, input: JSON, view: JSON? = nil, toolKind: String? = nil, model: AppModel) {
        var body: [String: JSON] = ["event": "ask", "requestId": .string(requestId), "kind": "permission", "tool": .string(tool), "input": input]
        if let view { body["view"] = view }
        if let toolKind { body["toolKind"] = .string(toolKind) }
        model.route(EngineEvent(name: "ask", threadId: chat.id.uuidString, body: .object(body)))
    }

    private func thread(_ title: String, openedBy opener: Chat, mode: String = "default", in project: Project? = nil, model: AppModel) -> Chat {
        let chat = Chat(project: project ?? self.project, title: title, permissionMode: mode)
        chat.provider = "claude"
        chat.started = true
        chat.titleIsCustom = true
        chat.openedBy = opener.id
        chat.turnFrom = opener.id
        container.mainContext.insert(chat)
        model.conversation(for: chat).userSent("\(title) it.")
        return chat
    }

    private func youMayAllow(_ requestId: String, _ lead: Chat, in model: AppModel) -> Bool? {
        model.asksHeld(by: lead.id).first { $0.id == requestId }.map { model.told($0, to: lead) }?["youMayAllow"]?.bool
    }

    private func question(_ requestId: String, in chat: Chat, model: AppModel) {
        let questions: JSON = [["question": "Which file?", "options": [["label": "sum.py"], ["label": "plus.py"]]]]
        model.route(EngineEvent(name: "ask", threadId: chat.id.uuidString, body: [
            "event": "ask", "requestId": .string(requestId), "kind": "question", "tool": "AskUserQuestion", "input": ["questions": questions], "options": questions,
        ]))
    }

    private func lines(_ chat: Chat, in model: AppModel) -> [String] {
        model.conversation(for: chat).items.compactMap { if case .act(_, _, let text) = $0 { text } else { nil } }
    }

    private func turnEnds(_ chat: Chat, in model: AppModel) {
        model.route(EngineEvent(name: "turn.done", threadId: chat.id.uuidString, body: ["event": "turn.done", "stopReason": "end_turn", "durationMs": 10, "costUSD": 0]))
    }

    @Test func anEditInTheChildsFolderIsTheLeadsToAllowOnAcceptEdits() throws {
        let (model, lead, child) = try model()
        ask("e1", in: child, tool: "Edit", input: ["file_path": "/tmp/alpha-wt/sum.py", "old_string": "sum", "new_string": "plus"], model: model)
        #expect(model.askHolders["e1"] == lead.id)
        // Not the user's yet: no entry, no count, no badge.
        #expect(model.waitingAsks.isEmpty)
        #expect(model.waitingCount == 0)
        let told = try #require(model.asksHeld(by: lead.id).first.map { model.told($0, to: lead) })
        #expect(told["asks"]?.string == "Edit sum.py")
        #expect(told["youMayAllow"]?.bool == true)

        let answered = try model.answerAsk(["ask": "e1", "answer": "allow", "reason": "Its own worktree."], from: lead.id)
        #expect(answered["answered"]?.string == "allow")
        #expect(model.askHolders["e1"] == nil)
        let settled = model.conversation(for: child).items.compactMap { if case .ask(_, let ask) = $0 { ask } else { nil } }.first
        #expect(settled?.state == .allowed)
        #expect(settled?.answeredBy == "Lead")
        #expect(settled?.answerReason == "Its own worktree.")
        // The lead's line waits for its turn's end, as every line between threads does.
        turnEnds(lead, in: model)
        #expect(lines(lead, in: model) == ["Allowed for Rename: Edit sum.py · Its own worktree."])
        #expect(throws: AppModel.Refused.self) { try model.answerAsk(["ask": "e1", "answer": "allow", "reason": "Again."], from: lead.id) }
    }

    @Test func aCommandIsPastAcceptEditsAndGoesToTheUserWithTheLeadsReason() throws {
        let (model, lead, child) = try model()
        ask("c1", in: child, tool: "Bash", input: ["command": "npm test"], model: model)
        let told = try #require(model.asksHeld(by: lead.id).first.map { model.told($0, to: lead) })
        #expect(told["youMayAllow"]?.bool == false)
        #expect(told["why"]?.string?.contains("Accept edits") == true)
        #expect(throws: AppModel.Refused.self) { try model.answerAsk(["ask": "c1", "answer": "allow", "reason": "Tests are safe."], from: lead.id) }
        #expect(model.askHolders["c1"] == lead.id)

        let passed = try model.answerAsk(["ask": "c1", "answer": "pass", "reason": "Accept edits can't run a command."], from: lead.id)
        #expect(passed["passedTo"]?.string == "the user")
        let queue = model.waitingAsks
        #expect(queue.map(\.id) == ["c1"])
        #expect(queue.first?.ask.passes == [PendingAsk.Pass(by: "Lead", to: nil, reason: "Accept edits can't run a command.")])
        #expect(model.waitingCount == 1)
        turnEnds(lead, in: model)
        #expect(lines(lead, in: model) == ["Passed Rename's ask to you: Bash: npm test · Accept edits can't run a command."])
    }

    @Test func aQuestionAboutTheTaskIsAnsweredByTheLead() throws {
        let (model, lead, child) = try model(mode: "default")
        question("q1", in: child, model: model)
        #expect(model.askHolders["q1"] == lead.id)
        // On Ask the lead allows nothing, but a question is its to answer.
        #expect(throws: AppModel.Refused.self) { try model.answerAsk(["ask": "q1", "answer": "allow", "reason": "x"], from: lead.id) }
        #expect(throws: AppModel.Refused.self) { try model.answerAsk(["ask": "q1", "answer": "answer", "answers": ["Which colour?": "red", "Other": "x"], "reason": "x"], from: lead.id) }
        _ = try model.answerAsk(["ask": "q1", "answer": "answer", "answers": ["file": "sum.py"], "reason": "The task names sum.py."], from: lead.id)
        let settled = model.conversation(for: child).items.compactMap { if case .ask(_, let ask) = $0 { ask } else { nil } }.first
        #expect(settled?.state == .allowed)
        #expect(settled?.answeredBy == "Lead")
        turnEnds(lead, in: model)
        #expect(lines(lead, in: model) == ["Answered Rename's question: sum.py · The task names sum.py."])
    }

    @Test func anAskStillWithTheLeadWhenItsTurnEndsGoesUpByItself() throws {
        let (model, lead, child) = try model()
        ask("c2", in: child, tool: "Bash", input: ["command": "ls"], model: model)
        #expect(model.waitingAsks.isEmpty)
        turnEnds(lead, in: model)
        #expect(model.askHolders["c2"] == nil)
        #expect(model.waitingAsks.first?.ask.passes.first?.reason == "Its turn ended before it answered")
    }

    @Test func aPassFromTheMiddleGoesToTheThreadAboveWhileItWorks() throws {
        let (model, lead, child) = try model(mode: "bypassPermissions")
        // Rename set Check going, on Ask too.
        let check = thread("Check", openedBy: child, model: model)
        ask("c3", in: check, tool: "Bash", input: ["command": "make"], model: model)
        #expect(model.askHolders["c3"] == child.id)
        let waiting = { model.conversation(for: check).waitingAsks.first { $0.requestId == "c3" } }
        #expect(waiting().flatMap { model.heldLine(of: $0, in: check) } == "With Rename first, which set this thread going")
        // Rename is on Ask, so it passes; Lead, on Don't ask, may allow it.
        _ = try model.answerAsk(["ask": "c3", "answer": "pass", "reason": "Ask can't run make."], from: child.id)
        #expect(model.askHolders["c3"] == lead.id)
        // Lead didn't set Check going: the card names the pass that brought the ask there.
        #expect(waiting().flatMap { model.heldLine(of: $0, in: check) } == "Rename passed this to Lead · Ask can't run make.")
        let told = try #require(model.asksHeld(by: lead.id).first.map { model.told($0, to: lead) })
        #expect(told["youMayAllow"]?.bool == true)
        #expect(told["passedUp"]?.array?.first?["by"]?.string == "Rename")
        _ = try model.answerAsk(["ask": "c3", "answer": "allow", "reason": "make only builds."], from: lead.id)
        #expect(model.waitingAsks.isEmpty)
    }

    @Test func whatStaysTheUsers() throws {
        let (model, lead, child) = try model()
        // Seeing and using the Mac, and a turn the user started themselves.
        ask("m1", in: child, tool: "Mac", input: ["app": "Finder"], model: model)
        #expect(model.askHolders["m1"] == nil)
        child.turnFrom = nil
        ask("e2", in: child, tool: "Edit", input: ["file_path": "/tmp/alpha-wt/a.py"], model: model)
        #expect(model.askHolders["e2"] == nil)
        // A lead that isn't working has nobody there to answer.
        child.turnFrom = lead.id
        turnEnds(lead, in: model)
        ask("e3", in: child, tool: "Edit", input: ["file_path": "/tmp/alpha-wt/b.py"], model: model)
        #expect(model.askHolders["e3"] == nil)
        #expect(model.waitingAsks.count == 3)
    }

    @Test func withTheSwitchOffEveryAskComesToTheUser() throws {
        let defaults = UserDefaults.standard
        let (model, lead, child) = try model()
        ask("e4", in: child, tool: "Edit", input: ["file_path": "/tmp/alpha-wt/sum.py"], model: model)
        #expect(model.askHolders["e4"] == lead.id)
        defaults.set(false, forKey: AppModel.openersAnswerKey)
        model.handAsksToUser()
        ask("c4", in: child, tool: "Bash", input: ["command": "npm test"], model: model)
        question("q4", in: child, model: model)
        #expect(model.askHolders.isEmpty)
        #expect(model.waitingAsks.map(\.id) == ["e4", "c4", "q4"])
    }

    @Test func anEditOutsideBothFoldersIsPastAcceptEdits() throws {
        let (model, lead, child) = try model()
        ask("e5", in: child, tool: "Write", input: ["file_path": "/etc/hosts", "content": "x"], model: model)
        let told = try #require(model.asksHeld(by: lead.id).first.map { model.told($0, to: lead) })
        #expect(told["youMayAllow"]?.bool == false)
        ask("e6", in: child, tool: "Write", input: ["file_path": "/tmp/alpha/notes.md", "content": .string(String(repeating: "x", count: 5000))], model: model)
        let second = try #require(model.asksHeld(by: lead.id).last.map { model.told($0, to: lead) })
        #expect(second["youMayAllow"]?.bool == true)
        #expect((second["input"]?["content"]?.string?.count ?? 0) < 2100)
    }

    @Test func aLeadOpensAThreadOnATighterModeAndNeverALooserOne() throws {
        let (model, lead, _) = try model()
        var request = AppModel.ThreadRequest(parent: lead.id, text: "Rename sum to plus.")
        request.mode = "default"
        #expect(try model.opening(for: request).mode == "default")
        request.mode = "bypassPermissions"
        #expect(throws: AppModel.Refused.self) { try model.opening(for: request) }
        request.mode = nil
        #expect(try model.opening(for: request).mode == "acceptEdits")
    }

    @Test func theAskingThreadReadsAsAskingItsLeadAndALeadThatGoesLeavesTheAskTheUsers() throws {
        let (model, lead, child) = try model()
        ask("e7", in: child, tool: "Edit", input: ["file_path": "/tmp/alpha-wt/sum.py"], model: model)
        #expect(model.status(of: child) == OverviewStatus(state: .working, step: "Asking Lead"))
        #expect(model.state(of: child) == "waiting on Lead to answer it")
        // Deleted or let go while it held the ask: nobody is there to answer it.
        model.conversations[lead.id] = nil
        #expect(model.waitingAsks.map(\.id) == ["e7"])
        #expect(model.status(of: child) == OverviewStatus(state: .waiting, step: "Waiting on you"))
    }

    @Test func aPassedAskWhoseHolderWentReadsAsPassedUpNotAsStillWithIt() throws {
        let (model, lead, child) = try model(mode: "bypassPermissions")
        let check = thread("Check", openedBy: child, model: model)
        ask("c8", in: check, tool: "Bash", input: ["command": "make"], model: model)
        _ = try model.answerAsk(["ask": "c8", "answer": "pass", "reason": "Ask can't run make."], from: child.id)
        #expect(model.askHolders["c8"] == lead.id)
        UserDefaults.standard.set(false, forKey: AppModel.openersAnswerKey)
        model.handAsksToUser()
        let entry = try #require(model.waitingAsks.first { $0.id == "c8" })
        #expect(model.heldLine(of: entry.ask, in: check) == "Rename passed this up · Ask can't run make.")
    }

    @Test func anAskTheLeadDoesntTakeUpGoesUpByItself() async throws {
        let (model, lead, child) = try model()
        model.holdLimits = (unread: .milliseconds(50), unanswered: .milliseconds(50))
        ask("c5", in: child, tool: "Bash", input: ["command": "npm test"], model: model)
        #expect(model.askHolders["c5"] == lead.id)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.askHolders["c5"] == nil)
        #expect(model.waitingAsks.first { $0.id == "c5" }?.ask.passes.first?.reason == "Not taken up within 0 seconds")
        // Read in a wait_thread, the clock starts again for the answer.
        ask("c6", in: child, tool: "Bash", input: ["command": "ls"], model: model)
        model.heldAskRead("c6")
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.waitingAsks.first { $0.id == "c6" }?.ask.passes.first?.reason == "Not answered within 0 seconds of being read")
        // One answered in time is settled, and nothing goes up after.
        model.holdLimits = (unread: .milliseconds(100), unanswered: .milliseconds(100))
        ask("e8", in: child, tool: "Edit", input: ["file_path": "/tmp/alpha-wt/sum.py"], model: model)
        _ = try model.answerAsk(["ask": "e8", "answer": "allow", "reason": "Its worktree."], from: lead.id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.holdDeadlines.isEmpty)
        turnEnds(lead, in: model)
        #expect(lines(lead, in: model).filter { $0.contains("sum.py") } == ["Allowed for Rename: Edit sum.py · Its worktree."])
    }

    @Test func aLeadWaitingOnAnAskOfItsOwnCantAnswerAnother() throws {
        let (model, lead, child) = try model()
        ask("l1", in: lead, tool: "Bash", input: ["command": "make"], model: model)
        ask("c7", in: child, tool: "Bash", input: ["command": "npm test"], model: model)
        #expect(model.askHolders["c7"] == nil)
        #expect(Set(model.waitingAsks.map(\.id)) == ["l1", "c7"])
    }

    @Test func aTurnThatEndsOutsideItsEventsStillSendsItsAsksUp() throws {
        let (model, lead, child) = try model()
        ask("c9", in: child, tool: "Bash", input: ["command": "npm test"], model: model)
        // A send the engine turned down: startTurn's failure ends the turn with no turn.done.
        model.conversation(for: lead).sendFailed("The engine said no.")
        model.turnEnded(lead.id)
        #expect(model.askHolders["c9"] == nil)
        #expect(model.waitingAsks.first?.ask.passes.first?.reason == "Its turn ended before it answered")
    }

    @Test func stopOnTheLeadLeavesTheAsksOfTheThreadsItStopsToBeCancelled() throws {
        let (model, lead, child) = try model()
        ask("c10", in: child, tool: "Bash", input: ["command": "npm test"], model: model)
        model.stop(in: lead)
        // The lead's turn.done comes before the child's ask.cancelled.
        turnEnds(lead, in: model)
        #expect(model.askHolders["c10"] == lead.id)
        model.route(EngineEvent(name: "ask.cancelled", threadId: child.id.uuidString, body: ["event": "ask.cancelled", "requestId": "c10"]))
        #expect(model.askHolders["c10"] == nil)
        #expect(model.waitingAsks.isEmpty)
        #expect(!lines(lead, in: model).contains { $0.hasPrefix("Passed") })
        #expect(model.conversation(for: child).items.compactMap { if case .ask(_, let ask) = $0 { ask } else { nil } }.first?.passes.isEmpty == true)
    }

    @Test func anEditInAnotherProjectsFolderIsPastAcceptEdits() throws {
        let (model, lead, _) = try model()
        let beta = Project(name: "beta", path: "/tmp/beta")
        container.mainContext.insert(beta)
        let other = thread("Config", openedBy: lead, in: beta, model: model)
        ask("e9", in: other, tool: "Edit", input: ["file_path": "/tmp/beta/config.ts"], model: model)
        #expect(youMayAllow("e9", lead, in: model) == false)
        let told = try #require(model.asksHeld(by: lead.id).first.map { model.told($0, to: lead) })
        #expect(told["why"]?.string?.contains("beta's folder") == true)
    }

    @Test func aLinkOutOfTheFolderIsOutsideIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "oricode-links-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "proj")
        let away = root.appending(path: "away")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "notes"), withDestinationURL: away)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "gone"), withDestinationURL: away.appending(path: "nothing"))
        let (model, lead, child) = try model()
        lead.cwd = folder.path
        child.cwd = folder.path
        child.worktreeBranch = nil
        ask("e10", in: child, tool: "Write", input: ["file_path": .string(folder.appending(path: "notes/authorized_keys").path)], model: model)
        ask("e11", in: child, tool: "Write", input: ["file_path": "gone"], model: model)
        ask("e12", in: child, tool: "Write", input: ["file_path": .string(folder.appending(path: "new/plus.py").path)], model: model)
        #expect(youMayAllow("e10", lead, in: model) == false)
        #expect(youMayAllow("e11", lead, in: model) == false)
        #expect(youMayAllow("e12", lead, in: model) == true)
    }

    @Test func aPatchIsAllowedOnlyWhenEveryChangeIsAnEditInTheFolder() throws {
        let (model, lead, child) = try model()
        child.provider = "codex"
        let edit: JSON = ["path": "/tmp/alpha-wt/src/a.ts", "kind": "edit"]
        ask("p1", in: child, tool: "Edit", input: ["path": "/tmp/alpha-wt/src/a.ts"], view: ["path": "/tmp/alpha-wt/src/a.ts", "paths": [edit, ["path": "/tmp/alpha-wt/src/b.ts", "kind": "write"]]], toolKind: "edit", model: model)
        ask("p2", in: child, tool: "Edit", input: ["path": "/tmp/alpha-wt/src/a.ts"], view: ["path": "/tmp/alpha-wt/src/a.ts", "paths": [edit, ["path": "/Users/someone/.zshrc", "kind": "edit"]]], toolKind: "edit", model: model)
        ask("p3", in: child, tool: "Edit", input: ["path": "/tmp/alpha-wt/src/a.ts"], view: ["path": "/tmp/alpha-wt/src/a.ts", "paths": [edit, ["path": "/tmp/alpha-wt/old.ts", "kind": "delete"]]], toolKind: "edit", model: model)
        // An agent whose ask names only its first file can't have the rest judged.
        ask("p4", in: child, tool: "Edit", input: ["path": "/tmp/alpha-wt/src/a.ts"], view: ["path": "/tmp/alpha-wt/src/a.ts"], toolKind: "edit", model: model)
        #expect(youMayAllow("p1", lead, in: model) == true)
        #expect(youMayAllow("p2", lead, in: model) == false)
        #expect(youMayAllow("p3", lead, in: model) == false)
        #expect(youMayAllow("p4", lead, in: model) == false)
    }

    @Test func aThreadWaitingOnOneWhoseAskTheLeadHoldsIsToldSo() async throws {
        let (model, lead, child) = try model()
        let sibling = thread("Docs", openedBy: lead, model: model)
        ask("c11", in: child, tool: "Bash", input: ["command": "npm test"], model: model)
        let answer = try await model.wait(on: child.id.uuidString, from: sibling.id, within: .milliseconds(10))
        #expect(answer["note"]?.string == "It's waiting on Lead, which set it going, to answer it. Call wait_thread again to wait longer.")
        #expect(model.conversation(for: child).mainStep(cwd: child.cwd, asking: model.holder(of: "c11")?.title).tool == "Asking Lead")
    }
}
