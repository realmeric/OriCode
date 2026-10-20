import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread an agent opened with open_thread: what it's made with, what's refused, and the line
/// its parent gets when its first turn ends.
@MainActor
struct OpenedThreadsTests {
    private let container: ModelContainer
    private let project: Project
    private let other: Project

    init() throws {
        container = try TestStore.memory()
        project = Project(name: "alpha", path: "/tmp/alpha")
        other = Project(name: "beta", path: "/tmp/beta")
        container.mainContext.insert(project)
        container.mainContext.insert(other)
        // Saved here: a test that makes no model would leave them unsaved, and an autosave that
        // comes due after its container has gone takes the test host down.
        try container.mainContext.save()
    }

    private static func agent(_ id: String, modes: [String], state: ProviderInfo.State = .ready, unsupervised: Bool? = nil) -> ProviderInfo {
        var capabilities = ProviderInfo.Capabilities(
            steer: true, resume: true, modeLive: false, attachments: true, heads: false, stopTask: false, limits: false,
            usage: false, commands: false, compact: false, commitMessage: false, handoff: nil)
        capabilities.unsupervised = unsupervised
        return ProviderInfo(
            id: id, name: id.capitalized, agent: id.capitalized, state: state, hint: state == .ready ? nil : "run `\(id)` in Terminal and log in",
            cli: nil, version: nil, capabilities: capabilities, levels: ["low", "high"], modes: modes)
    }

    private static let codex = agent("codex", modes: ["default", "acceptEdits", "bypassPermissions"])
    private static let pi = agent("pi", modes: [], unsupervised: true)

    private static func option(_ id: String, efforts: [String] = ["low", "high"]) -> ModelOption {
        ModelOption(id: id, name: id, description: "", efforts: efforts, fast: true, defaultEffort: nil, ultra: false, ultraBlocked: nil, more: nil, needs: nil)
    }

    /// A model with Claude, Codex and Pi turned on, and a started Claude thread open in alpha.
    private func model(mode: String = "acceptEdits") throws -> (AppModel, Chat) {
        let model = AppModel(container: container)
        model.support = FileManager.default.temporaryDirectory.appending(path: "oricode-opened-\(UUID().uuidString)", directoryHint: .isDirectory)
        model.providers = [.claude, Self.codex, Self.pi, Self.agent("cursor", modes: ["default"], state: .signedOut)]
        model.models = [Self.option("opus"), Self.option("haiku", efforts: [])]
        model.modelsByAgent["codex"] = [Self.option("gpt-large"), Self.option("gpt-small")]
        let parent = Chat(project: project, title: "Sums", permissionMode: mode)
        parent.provider = "claude"
        parent.model = "opus"
        parent.effort = "high"
        parent.fastMode = true
        parent.started = true
        container.mainContext.insert(parent)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = parent.id
        return (model, parent)
    }

    private func request(_ parent: Chat, _ change: (inout AppModel.ThreadRequest) -> Void = { _ in }) -> AppModel.ThreadRequest {
        var request = AppModel.ThreadRequest(parent: parent.id, text: "Rename sum.txt to total.txt.")
        request.title = "Rename sum.txt"
        change(&request)
        return request
    }

    private func refusal(_ model: AppModel, _ request: AppModel.ThreadRequest) -> String? {
        do {
            _ = try model.opening(for: request)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func itIsAnOrdinaryThreadOnItsParentsAgentModelLevelAndMode() throws {
        let (model, parent) = try model()
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)

        #expect(chat.project?.id == project.id && chat.cwd == parent.cwd)
        #expect(chat.providerID == "claude" && chat.model == "opus" && chat.effort == "high" && chat.fastMode)
        #expect(chat.permissionMode == "acceptEdits")
        #expect(chat.openedBy == parent.id)
        #expect(chat.rays == nil && !chat.workflows && chat.worktreeBranch == nil)
        // Its name is the one the agent gave, and its first message is in it, sent as the composer sends.
        #expect(chat.title == "Rename sum.txt" && chat.titleIsCustom)
        let conversation = try #require(model.conversations[chat.id])
        guard case .user(_, let text, _, let midTurn) = conversation.items.first(where: { if case .user = $0 { true } else { false } }) else {
            Issue.record("no first message")
            return
        }
        #expect(text == "Rename sum.txt to total.txt." && !midTurn)
        #expect(conversation.running)
        // In the drawer from its first message, folded under its parent, which stays the thread on screen.
        #expect(model.chats.map(\.id) == [parent.id])
        #expect(model.drawerTree.first?.children?.map(\.id) == [chat.id])
        #expect(model.drawerRows.map(\.id) == [parent.id])
        #expect(model.selectedChatID == parent.id)
        // The tool's answer names it.
        #expect(AppModel.made(chat, on: .claude) == ["thread": "Rename sum.txt", "id": .string(chat.id.uuidString), "agent": "claude", "mode": "acceptEdits", "folder": "/tmp/alpha", "model": "opus"])
    }

    @Test func aThreadAnotherOpenedOpensItsOwnAndItsFirstMessageSaysWhoSentIt() throws {
        let (model, parent) = try model()
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        let third = request(chat) { $0.title = "Check the tests" }
        let grandchild = try model.open(model.opening(for: third), third)
        #expect(grandchild.openedBy == chat.id)
        // A send from another thread names it to the engine; the user's own name none.
        #expect(model.sendParams(in: chat, text: "hi", images: [], from: parent)["from"] == ["id": .string(parent.id.uuidString), "title": "Sums"])
        #expect(model.sendParams(in: chat, text: "hi", images: [])["from"] == nil)
        #expect(model.sendParams(in: chat, text: "hi", images: [])["opened"] == nil)
    }

    private func acts(_ conversation: Conversation) -> [String] {
        conversation.items.compactMap { item in
            if case .act(_, _, let text) = item { text } else { nil }
        }
    }

    @Test func anOpenPutsALineWithItsReasonInBothThreads() throws {
        let (model, parent) = try model()
        let asked = request(parent) { $0.reason = "The rename can go on alone." }
        let chat = try model.open(model.opening(for: asked), asked)
        #expect(acts(model.conversation(for: parent)) == ["Opened Rename sum.txt · The rename can go on alone."])
        let child = model.conversation(for: chat)
        #expect(acts(child) == ["Sums opened this thread · The rename can go on alone."])
        // Ahead of its first message, and both stored.
        guard case .act(_, let opener, _) = child.items.first, case .user = child.items.dropFirst().first else {
            Issue.record("the line isn't ahead of the message")
            return
        }
        #expect(opener == parent.id)
        #expect(acts(Conversation(chat: parent, context: container.mainContext)).count == 1)
        #expect(acts(Conversation(chat: chat, context: container.mainContext)).count == 1)
    }

    /// A second thread of the project, started and idle.
    private func sibling(_ model: AppModel, title: String = "Docs") throws -> Chat {
        let chat = Chat(project: project, title: title, permissionMode: "default")
        chat.provider = "claude"
        chat.started = true
        chat.titleIsCustom = true
        container.mainContext.insert(chat)
        try container.mainContext.save()
        return chat
    }

    @Test func theCeilingRefusesWhatWouldSetOneThreadTooManyWorking() throws {
        let (model, parent) = try model()
        UserDefaults.standard.set(2, forKey: AppModel.ceilingKey)
        defer { UserDefaults.standard.removeObject(forKey: AppModel.ceilingKey) }
        let docs = try sibling(model)
        model.conversation(for: parent).userSent("Split it up")
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        let refused = "2 threads are working, as many as the user allows at once in Settings › Agents. Wait for one with wait_thread or stop one, then try again."
        #expect(refusal(model, request(parent)) == refused)
        #expect(throws: AppModel.Refused.self) { try model.message(docs.id.uuidString, text: "Update the README", reason: "r", from: parent.id) }
        #expect(model.conversations[docs.id]?.running != true)
        // A message into a turn that runs sets nothing more going.
        #expect(try model.message(chat.id.uuidString, text: "Use git mv", reason: "Keeps history", from: parent.id)["intoTurn"] == true)
        // Nor does the user's own send.
        #expect(model.send("Update the README", images: [], in: docs))
        #expect(model.threadsAtOnce == 2)
        UserDefaults.standard.removeObject(forKey: AppModel.ceilingKey)
        #expect(model.threadsAtOnce == AppModel.defaultCeiling)
    }

    @Test func anOpenThatWaitedOnGitIsCheckedAgainstTheCeilingBeforeItSends() throws {
        let (model, parent) = try model()
        UserDefaults.standard.set(2, forKey: AppModel.ceilingKey)
        defer { UserDefaults.standard.removeObject(forKey: AppModel.ceilingKey) }
        model.conversation(for: parent).userSent("Split it up")
        // Two opens with worktrees each pass the check before git has made either.
        let first = request(parent) { $0.worktree = true }
        let second = request(parent) { $0.worktree = true }
        let openings = try (model.opening(for: first), model.opening(for: second))
        try model.open(openings.0, first, in: ("/tmp/alpha/.worktrees/t-1", "oricode/t-1"))
        #expect(throws: AppModel.Refused.self) { try model.open(openings.1, second, in: ("/tmp/alpha/.worktrees/t-2", "oricode/t-2")) }
        #expect(model.conversations.values.count(where: \.running) == 2)
        #expect(model.listedChats.count == 2)
    }

    @Test func aMessageNeverGoesToAThreadLooserThanItsSender() throws {
        let (model, parent) = try model(mode: "plan")
        let docs = try sibling(model)
        let refused = "Docs is on Ask, looser than this thread, which is on Plan, so it takes no message from here. Ask the user to send it."
        let error = #expect(throws: AppModel.Refused.self) { try model.message(docs.id.uuidString, text: "Apply the change", reason: "r", from: parent.id) }
        #expect(error?.why == refused)
        #expect(model.conversations[docs.id]?.running != true && acts(model.conversation(for: docs)).isEmpty)
        // A thread on an agent that asks before nothing is looser than any mode but Don't ask.
        let pi = try sibling(model, title: "Pi")
        pi.provider = "pi"
        parent.permissionMode = "default"
        #expect(throws: AppModel.Refused.self) { try model.message(pi.id.uuidString, text: "x", reason: "r", from: parent.id) }
        parent.permissionMode = "bypassPermissions"
        #expect(try model.message(pi.id.uuidString, text: "x", reason: "r", from: parent.id)["sent"] == true)
        // One as tight as the sender's or tighter takes it.
        #expect(try model.message(docs.id.uuidString, text: "Apply the change", reason: "r", from: parent.id)["sent"] == true)
    }

    @Test func aMessageGoesToTheThreadAsItsComposerWouldWithALineInBoth() throws {
        let (model, parent) = try model()
        let docs = try sibling(model)
        let sent = try model.message(" \(docs.id.uuidString.lowercased()) ", text: " Update the README. ", reason: "Its part changed", from: parent.id)
        #expect(sent == ["thread": "Docs", "id": .string(docs.id.uuidString), "sent": true, "intoTurn": false])
        let conversation = model.conversation(for: docs)
        #expect(conversation.running)
        #expect(acts(conversation) == ["Message from Sums · Its part changed"])
        guard case .user(_, "Update the README.", _, false) = conversation.items.last else {
            Issue.record("the message isn't sent")
            return
        }
        #expect(acts(model.conversation(for: parent)) == ["Sent Docs a message · Its part changed"])
        // Not to itself, nor to a thread it can't list.
        #expect(throws: AppModel.Refused.self) { try model.message(parent.id.uuidString, text: "x", reason: "r", from: parent.id) }
        #expect(throws: AppModel.Refused.self) { try model.message(UUID().uuidString, text: "x", reason: "r", from: parent.id) }
    }

    @Test func aStopStopsAWorkingThreadAndBothSaySo() throws {
        let (model, parent) = try model()
        parent.titleIsCustom = true
        let docs = try sibling(model)
        #expect(throws: AppModel.Refused.self) { try model.stop(docs.id.uuidString, reason: "r", from: parent.id) }
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        // The parent is mid-turn, as it is when its agent calls the tool.
        let own = model.conversation(for: parent)
        own.userSent("Stop the rename")
        #expect(try model.stop(chat.id.uuidString, reason: "The rename isn't wanted after all", from: parent.id) == ["thread": "Rename sum.txt", "id": .string(chat.id.uuidString), "stopped": true])
        // Each line waits for its own thread's turn to end, so no reply is cut in two.
        model.route(done(chat, "interrupted"))
        #expect(acts(model.conversation(for: chat)).last == "Sums stopped this thread · The rename isn't wanted after all")
        #expect(!acts(own).contains("Stopped Rename sum.txt · The rename isn't wanted after all"))
        own.receive(done(parent))
        #expect(acts(own).last == "Stopped Rename sum.txt · The rename isn't wanted after all")
    }

    @Test func stopOnAThreadStopsTheThreadsItOpenedThatWorkAndTheirsAndEachSaysSo() async throws {
        let (model, parent) = try model()
        parent.titleIsCustom = true
        let asked = request(parent)
        let rename = try model.open(model.opening(for: asked), asked)
        rename.titleIsCustom = true
        var deeper = AppModel.ThreadRequest(parent: rename.id, text: "Update the docs for total.txt.")
        deeper.title = "Docs"
        let docs = try model.open(model.opening(for: deeper), deeper)
        docs.titleIsCustom = true
        var idle = AppModel.ThreadRequest(parent: parent.id, text: "Count the lines.")
        idle.title = "Lines"
        let lines = try model.open(model.opening(for: idle), idle)
        try await working(model, parent)
        try await working(model, rename)
        try await working(model, docs)
        model.route(done(lines))

        model.stop(in: parent)
        // Each line waits for its thread's turn to end, as the interrupt ends it.
        for chat in [docs, rename, parent] { model.route(done(chat, "interrupted")) }
        #expect(Array(acts(model.conversation(for: rename)).suffix(2)) == ["Stopped Docs with this thread", "Stopped with Sums, which opened it"])
        #expect(acts(model.conversation(for: docs)).last == "Stopped with Rename sum.txt, which opened it")
        #expect(acts(model.conversation(for: parent)).filter { $0.hasPrefix("Stopped") } == ["Stopped Rename sum.txt with this thread"])
        // A thread it opened that isn't working has nothing to stop, and no line.
        #expect(!acts(model.conversation(for: lines)).contains { $0.hasPrefix("Stopped") })
    }

    @Test func stopOnAThreadReachesOnlyTheTurnsItSetGoingInTheThreadsItOpened() async throws {
        let (model, parent) = try model()
        parent.titleIsCustom = true
        let asked = request(parent)
        let rename = try model.open(model.opening(for: asked), asked)
        rename.titleIsCustom = true
        try await working(model, rename)
        model.route(done(rename))
        // The user works in it now, beside its opener.
        #expect(model.send("Rename it back", in: rename))
        try await working(model, rename)
        try await working(model, parent)
        #expect(!model.leftWorking(parent))
        model.stop(in: parent)
        for chat in [rename, parent] { model.route(done(chat, "interrupted")) }
        #expect(!acts(model.conversation(for: rename)).contains { $0.hasPrefix("Stopped with") })
        #expect(!acts(model.conversation(for: parent)).contains { $0.hasPrefix("Stopped") })

        // A message from its opener sets it going again, and that turn is the opener's to stop.
        _ = try model.message(rename.id.uuidString, text: "Undo that", reason: "Wrong name", from: parent.id)
        try await working(model, rename)
        try await working(model, parent)
        model.stop(in: parent)
        for chat in [rename, parent] { model.route(done(chat, "interrupted")) }
        #expect(acts(model.conversation(for: rename)).last == "Stopped with Sums, which opened it")
    }

    @Test func aThreadThatStopsItsOpenerGoesOnItself() async throws {
        let (model, parent) = try model()
        parent.titleIsCustom = true
        let asked = request(parent)
        let rename = try model.open(model.opening(for: asked), asked)
        rename.titleIsCustom = true
        try await working(model, rename)
        try await working(model, parent)
        #expect(try model.stop(parent.id.uuidString, reason: "Done here", from: rename.id)["stopped"] == true)
        model.route(done(parent, "interrupted"))
        model.route(done(rename))
        #expect(!acts(model.conversation(for: rename)).contains { $0.hasPrefix("Stopped with") })
        #expect(acts(model.conversation(for: parent)).last == "Rename sum.txt stopped this thread · Done here")
    }

    @Test func stopOnAThreadWhoseTurnIsOverStopsTheThreadsItLeftWorking() async throws {
        let (model, parent) = try model()
        parent.titleIsCustom = true
        let asked = request(parent)
        let rename = try model.open(model.opening(for: asked), asked)
        rename.titleIsCustom = true
        try await working(model, parent)
        try await working(model, rename)
        model.route(done(parent))
        #expect(model.leftWorking(parent) && model.canStop)
        // stop_thread on it from another thread finds work to stop, as the composer's ⌘. does.
        let docs = try sibling(model)
        #expect(try model.stop(parent.id.uuidString, reason: "Enough", from: docs.id)["stopped"] == true)
        model.route(done(rename, "interrupted"))
        #expect(acts(model.conversation(for: rename)).last == "Stopped with Sums, which opened it")
        #expect(acts(model.conversation(for: parent)).contains("Stopped Rename sum.txt with this thread"))
        #expect(!model.leftWorking(parent))
    }

    /// A turn under way as the engine reports it. With no engine in a test the send itself fails a
    /// moment after it's made, so the turn is started again from here once it has.
    private func working(_ model: AppModel, _ chat: Chat) async throws {
        try await Task.sleep(for: .milliseconds(50))
        model.route(EngineEvent(name: "turn.started", threadId: chat.id.uuidString, body: [:]))
        #expect(model.conversations[chat.id]?.running == true)
    }

    @Test func aWaitAnswersWithTheLastReplyWhenTheTurnEnds() async throws {
        let (model, parent) = try model()
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        try await working(model, chat)
        let waiting = Task { try await model.wait(on: chat.id.uuidString, from: parent.id) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.turnWaits[chat.id]?.count == 1)
        let timer = try #require(model.turnWaits[chat.id]?.values.first?.timer)
        model.route(EngineEvent(name: "text", threadId: chat.id.uuidString, body: ["delta": "Renamed sum.txt to total.txt."]))
        model.route(done(chat))
        let answer = try await waiting.value
        #expect(answer["reply"] == "Renamed sum.txt to total.txt." && answer["finished"] == true && answer["state"] == "idle")
        #expect(model.turnWaits[chat.id] == nil)
        // Its timer is called off with it, so nothing wakes when the five minutes are up.
        #expect(timer.isCancelled)
        // An idle thread answers at once with the reply it last gave, and one with none since its
        // latest message with none.
        #expect(try await model.wait(on: chat.id.uuidString, from: parent.id)["reply"] == "Renamed sum.txt to total.txt.")
        #expect(model.send("And the tests", images: [], in: chat))
        try await working(model, chat)
        let still = try await model.wait(on: chat.id.uuidString, from: parent.id, within: .milliseconds(50))
        #expect(still["state"] == "working" && still["reply"] == nil && still["note"] == "Still working. Call wait_thread again to wait longer.")
        #expect(model.turnWaits[chat.id]?.isEmpty ?? true)
        model.route(done(chat, "interrupted"))
        #expect(try await model.wait(on: chat.id.uuidString, from: parent.id)["reply"] == .null)
        // A wait the engine's going ends with it.
        model.route(EngineEvent(name: "turn.started", threadId: chat.id.uuidString, body: [:]))
        let cut = Task { try await model.wait(on: chat.id.uuidString, from: parent.id) }
        try await Task.sleep(for: .milliseconds(50))
        model.engineStopped()
        #expect(try await cut.value["state"] == "idle")
    }

    @Test func aTitleLeftOutIsTheMessagesFirstLine() throws {
        let (model, parent) = try model()
        let asked = request(parent) { $0.title = "  " }
        let chat = try model.open(model.opening(for: asked), asked)
        #expect(chat.title == "Rename sum.txt to total.txt." && !chat.titleIsCustom)
    }

    @Test func itWorksInItsParentsWorktreeWithoutOwningIt() throws {
        let (model, parent) = try model()
        parent.cwd = "/tmp/alpha/.worktrees/t-1"
        parent.worktreeBranch = "oricode/t-1"
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        #expect(chat.cwd == "/tmp/alpha/.worktrees/t-1" && chat.worktreeBranch == nil)
        // Asked for a worktree, it gets the one git made, from the project's own folder.
        let own = request(parent) { $0.worktree = true }
        let branched = try model.open(model.opening(for: own), own, in: ("/tmp/alpha/.worktrees/t-2", "oricode/t-2"))
        #expect(branched.cwd == "/tmp/alpha/.worktrees/t-2" && branched.worktreeBranch == "oricode/t-2")
        #expect(AppModel.made(branched, on: .claude)["branch"] == "oricode/t-2")
    }

    @Test func anotherProjectIsOneTheUserAdded() throws {
        let (model, parent) = try model()
        let asked = request(parent) { $0.folder = "/tmp/beta/" }
        let chat = try model.open(model.opening(for: asked), asked)
        #expect(chat.project?.id == other.id && chat.cwd == "/tmp/beta")
        #expect(refusal(model, request(parent) { $0.folder = "/tmp/gamma" })
            == "/tmp/gamma isn't one of the user's projects in OriCode. They are: /tmp/alpha, /tmp/beta.")
        // No folder has nothing to branch.
        let none = model.noFolderProject()
        defer { try? FileManager.default.removeItem(at: model.support) }
        #expect(refusal(model, request(parent) {
            $0.folder = none.path
            $0.worktree = true
        }) == "A thread without a folder has nothing to branch.")
    }

    @Test func anotherAgentGetsItsOwnModelAndTheLoosestModeNoLooserThanTheParents() throws {
        let (model, parent) = try model(mode: "auto")
        let asked = request(parent) { $0.agent = "codex" }
        let chat = try model.open(model.opening(for: asked), asked)
        // Codex has no Auto, so Accept edits; the model is left to what its composer shows, and the
        // parent's level and speed stay with the parent's agent.
        #expect(chat.providerID == "codex" && chat.model == nil && chat.permissionMode == "acceptEdits")
        #expect(chat.effort == nil && !chat.fastMode)
        #expect(model.modelSent(in: chat) == "gpt-large")
        let named = request(parent) {
            $0.agent = "codex"
            $0.model = "gpt-small"
        }
        #expect(try model.opening(for: named).model == "gpt-small")

        #expect(refusal(model, request(parent) { $0.agent = "devin" }) == "No agent called devin is turned on in OriCode. Those that are: claude, codex, pi, cursor.")
        #expect(refusal(model, request(parent) { $0.agent = "cursor" }) == "Cursor can't run here yet: run `cursor` in Terminal and log in")
        #expect(refusal(model, request(parent) { $0.model = "sonnet" }) == "Claude Code has no model called sonnet. It has: opus, haiku.")
        // An agent whose models no menu has asked for yet isn't taken at the agent's word for one.
        model.modelsByAgent["codex"] = nil
        #expect(refusal(model, request(parent) {
            $0.agent = "codex"
            $0.model = "gpt-9-nope"
        }) == "Codex didn't list its models just now, so OriCode can't tell whether gpt-9-nope is one. Leave the model out, or try again.")
        #expect(refusal(model, request(parent) { $0.agent = "codex" }) == nil)
        #expect(refusal(model, request(parent) { $0.agent = "pi" }) == "Pi asks before nothing, and this thread is on Auto.")
        #expect(refusal(model, request(parent) { $0.text = " \n" }) == "A thread needs its first message.")
        // A refusal makes nothing.
        #expect(model.listedChats.count == 2 && model.drawerTree.first?.children?.map(\.id) == [chat.id])
    }

    @Test func aHeadThatChoosesOpensNoThreadOnAModelHeadsKeepOff() throws {
        let (model, parent) = try model()
        model.headsKeepOff = ["claude/haiku", "codex/gpt-large"]
        defer { model.headsKeepOff = [] }
        #expect(refusal(model, request(parent) { $0.model = "haiku" }) == "The user keeps heads off haiku in Settings › Agents. Claude Code has: opus.")
        #expect(refusal(model, request(parent) {
            $0.agent = "codex"
            $0.model = "gpt-large"
        }) == "The user keeps heads off gpt-large in Settings › Agents. Codex has: gpt-small.")
        #expect(refusal(model, request(parent) { $0.model = "sonnet" }) == "Claude Code has no model called sonnet. It has: opus.")
        // Left out, the model is the parent's own, which may be one kept off too.
        #expect(refusal(model, request(parent)) == nil)
        model.headsKeepOff.append("claude/opus")
        #expect(refusal(model, request(parent)) == "This thread is on opus, which the user keeps heads off in Settings › Agents, so a thread it opens can't take it. Name another Claude Code model.")
        // With Heads choose off, the head picks nothing, and the list doesn't apply.
        UserDefaults.standard.set(false, forKey: Rays.chooseKey)
        defer { UserDefaults.standard.removeObject(forKey: Rays.chooseKey) }
        #expect(refusal(model, request(parent) { $0.model = "haiku" }) == nil)
    }

    @Test func aLevelTheModelDoesntHaveStaysBehind() throws {
        let (model, parent) = try model()
        let asked = request(parent) { $0.model = "haiku" }
        let chat = try model.open(model.opening(for: asked), asked)
        #expect(chat.model == "haiku" && chat.effort == nil && !chat.fastMode)
    }

    @Test(arguments: [
        ("plan", "plan", "default", nil as String?),
        ("default", "default", "default", nil),
        ("acceptEdits", "acceptEdits", "acceptEdits", nil),
        ("auto", "auto", "acceptEdits", nil),
        ("bypassPermissions", "bypassPermissions", "bypassPermissions", "bypassPermissions"),
    ])
    func noModeIsLooserThanTheParents(parent: String, same: String, onCodex: String, onPi: String?) {
        #expect(AppModel.mode(under: parent, on: .claude, same: true) == same)
        // Codex here has no Plan, and nothing it has is as tight.
        #expect(AppModel.mode(under: parent, on: Self.codex, same: false) == (parent == "plan" ? nil : onCodex))
        #expect(AppModel.mode(under: parent, on: Self.pi, same: false) == onPi)
        // One that asks before nothing and still has modes keeps to them.
        let commandCode = Self.agent("commandcode", modes: ["acceptEdits", "bypassPermissions"], unsupervised: true)
        #expect(AppModel.mode(under: parent, on: commandCode, same: false) == onPi)
        #expect(AppModel.mode(under: "something new", on: Self.codex, same: false) == nil)
    }

    private func done(_ chat: Chat, _ stopReason: String = "end_turn") -> EngineEvent {
        EngineEvent(name: "turn.done", threadId: chat.id.uuidString, body: ["stopReason": .string(stopReason)])
    }

    private func lines(_ conversation: Conversation) -> [String] {
        conversation.items.compactMap { item in
            if case .opened(_, _, let title, let finished, let resetsAt, let window) = item { OpenedLine.words(title: title, finished: finished, resetsAt: resetsAt, window: window) } else { nil }
        }
    }

    @Test func itsFirstTurnsEndPutsOneStoredLineInItsParentAndLaterTurnsNone() throws {
        let (model, parent) = try model()
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        // The parent isn't in memory, as one left a while ago isn't.
        model.selectedChatID = nil
        model.conversations[parent.id] = nil

        model.route(done(chat))
        // The line goes after its last event in the store, and its transcript stays unread.
        #expect(model.conversations[parent.id] == nil)
        let read = Conversation(chat: parent, context: container.mainContext)
        #expect(lines(read) == ["Rename sum.txt finished its first turn"])
        guard case .opened(_, let thread, _, _, _, _) = read.items.last else {
            Issue.record("no line")
            return
        }
        #expect(thread == chat.id)

        // A second turn says nothing more.
        #expect(model.send("And the tests", images: [], in: chat))
        model.route(done(chat))
        #expect(lines(Conversation(chat: parent, context: container.mainContext)).count == 1)
        // A thread nothing opened tells no one.
        model.route(done(parent))
        #expect(lines(Conversation(chat: parent, context: container.mainContext)).count == 1)
    }

    @Test func aFirstTurnThatWasStoppedSaysSoAndAParentAtWorkKeepsWorking() throws {
        let (model, parent) = try model()
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        let conversation = model.conversation(for: parent)
        conversation.userSent("Carry on")
        conversation.receive(EngineEvent(name: "text", threadId: parent.id.uuidString, body: ["delta": "Carrying"]))

        model.route(done(chat, "interrupted"))
        // The reply it's in the middle of stays one reply: the line waits for the turn's end.
        #expect(lines(conversation).isEmpty)
        #expect(conversation.running)
        #expect(model.conversations[parent.id] === conversation)
        conversation.receive(EngineEvent(name: "text", threadId: parent.id.uuidString, body: ["delta": " on"]))
        conversation.receive(done(parent))
        #expect(lines(conversation) == ["Rename sum.txt stopped before its first turn finished"])
        let read = Conversation(chat: parent, context: container.mainContext)
        #expect(read.items.count { if case .text(_, "Carrying on") = $0 { true } else { false } } == 1)
        guard case .opened = read.items.last, case .footer = read.items.dropLast().last else {
            Issue.record("the line doesn't follow the turn")
            return
        }
    }

    @Test func aParentStoppedOrCutOffByAQuitStillGetsTheLineItWasOwed() throws {
        let (model, parent) = try model()
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        let conversation = model.conversation(for: parent)
        conversation.userSent("Carry on")
        model.route(done(chat))
        conversation.stopped()
        #expect(lines(conversation) == ["Rename sum.txt finished its first turn"])

        // A send the engine refused ends the turn too.
        let next = request(parent)
        let refused = try model.open(model.opening(for: next), next)
        conversation.userSent("Carry on")
        model.route(done(refused))
        conversation.sendFailed("No session")
        #expect(lines(conversation).count == 2)

        let again = request(parent)
        let second = try model.open(model.opening(for: again), again)
        conversation.userSent("And on")
        model.route(done(second))
        conversation.quitting()
        #expect(lines(Conversation(chat: parent, context: container.mainContext)).count == 3)
    }

    @Test func aLineWrittenToAnUnreadParentFollowsItsLastEvent() throws {
        let (model, parent) = try model()
        let conversation = model.conversation(for: parent)
        conversation.userSent("Sum them")
        conversation.receive(EngineEvent(name: "text", threadId: parent.id.uuidString, body: ["delta": "Done."]))
        conversation.receive(done(parent))
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        model.selectedChatID = nil
        model.conversations[parent.id] = nil

        model.route(done(chat))
        #expect(model.conversations[parent.id] == nil)
        let read = Conversation(chat: parent, context: container.mainContext)
        guard case .opened = read.items.last else {
            Issue.record("the line isn't last")
            return
        }
        // What the thread writes next follows the line.
        read.userSent("Thanks")
        let events = StoredEvent.read(parent.id, from: container.mainContext)
        #expect(events.map(\.seq) == Array(0..<events.count))
        #expect(events.suffix(2).map(\.kind) == ["thread.done", "user"])
    }

    @Test func aParentDeletedFirstLeavesItsWorktreeToTheThreadStillInIt() throws {
        let (model, parent) = try model()
        parent.cwd = "/tmp/alpha/.worktrees/t-1"
        parent.worktreeBranch = "oricode/t-1"
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        // Deleting the parent doesn't ask about a worktree another thread works in, and removes none.
        #expect(model.ownFolder(of: parent) == nil)
        model.askToDelete(parent)
        #expect(model.deletingChat?.id == parent.id && model.deletingLoss == nil)
        model.delete(parent, removingWorktree: true)
        #expect(model.chats.map(\.id) == [chat.id])
        #expect(chat.cwd == "/tmp/alpha/.worktrees/t-1" && chat.worktreeBranch == "oricode/t-1")
        #expect(model.ownFolder(of: chat) == "/tmp/alpha/.worktrees/t-1")
    }

    @Test func itOutlivesItsParentAndAGoneThreadsLineOpensNothing() throws {
        let (model, parent) = try model()
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        model.delete(parent)
        #expect(model.chats.map(\.id) == [chat.id])
        // Its first turn's end has no one to tell, and nothing breaks.
        model.route(done(chat))
        #expect(model.conversations[chat.id]?.turnsEnded == 1)
        model.openOpened(chat.id)
        #expect(model.selectedChatID == chat.id)

        let gone = UUID()
        model.openOpened(gone)
        #expect(model.selectedChatID == chat.id)
    }

    private func limited(_ chat: Chat, resetsAt: Date, window: String = "five_hour") -> EngineEvent {
        EngineEvent(name: "limited", threadId: chat.id.uuidString, body: ["resetsAt": .number(resetsAt.timeIntervalSince1970 * 1000), "window": .string(window)])
    }

    @Test func aFirstTurnALimitStoppedSaysItWaitsAndTheTurnAfterTheResetSaysItFinishedOnce() throws {
        UserDefaults.standard.removeObject(forKey: Limit.goOnKey)
        let (model, parent) = try model()
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        let resetsAt = Date.now.addingTimeInterval(2 * 3600)

        model.route(limited(chat, resetsAt: resetsAt))
        model.route(done(chat, "stop_sequence"))
        #expect(chat.resumeAt != nil && chat.owesOpener == true)
        let waiting = "Rename sum.txt is waiting on the session limit, which resets at \(Limit.time(resetsAt))"
        #expect(lines(model.conversation(for: parent)) == [waiting])
        // Stored with its reset, so a parent read again says the same.
        #expect(lines(Conversation(chat: parent, context: container.mainContext)) == [waiting])
        guard case .opened(_, let thread, _, _, _, _) = model.conversation(for: parent).items.last else {
            Issue.record("no line")
            return
        }
        // A click on it still opens the thread beside.
        model.openOpened(thread, from: parent.id)
        #expect(model.besideChatID == chat.id)

        // The reset comes and the thread goes on by itself, as resumeDue sends it on.
        model.conversation(for: chat).userSent(AppModel.limitLine("five_hour"))
        model.route(done(chat))
        #expect(lines(model.conversation(for: parent)) == [waiting, "Rename sum.txt finished its first turn"])
        #expect(chat.owesOpener == false)

        // And never again.
        #expect(model.send("And the tests", images: [], in: chat))
        model.route(done(chat))
        #expect(lines(Conversation(chat: parent, context: container.mainContext)).count == 2)
    }

    @Test func aWaitCalledOffOrALimitItWontWaitForSaysItStopped() throws {
        UserDefaults.standard.removeObject(forKey: Limit.goOnKey)
        let (model, parent) = try model()
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        let resetsAt = Date.now.addingTimeInterval(3600)
        model.route(limited(chat, resetsAt: resetsAt))
        model.route(done(chat, "stop_sequence"))
        let waiting = "Rename sum.txt is waiting on the session limit, which resets at \(Limit.time(resetsAt))"
        let stopped = "Rename sum.txt stopped before its first turn finished"
        model.goOn(false, at: resetsAt, in: chat.id)
        #expect(lines(model.conversation(for: parent)) == [waiting, stopped])

        // Switched on again it waits again, and the turn after the reset finishes as ever.
        model.goOn(true, at: resetsAt, in: chat.id)
        #expect(lines(model.conversation(for: parent)) == [waiting, stopped, waiting])
        model.conversation(for: chat).userSent(AppModel.limitLine("five_hour"))
        model.route(done(chat))
        #expect(lines(model.conversation(for: parent)) == [waiting, stopped, waiting, "Rename sum.txt finished its first turn"])

        // The weekly limit only says when, so there's nothing to wait for, until the card's toggle waits for it.
        let again = request(parent)
        let weekly = try model.open(model.opening(for: again), again)
        let weekReset = Date.now.addingTimeInterval(3 * 86_400)
        model.route(limited(weekly, resetsAt: weekReset, window: "seven_day"))
        model.route(done(weekly, "stop_sequence"))
        #expect(lines(model.conversation(for: parent)).last == stopped)
        model.goOn(true, at: weekReset, in: weekly.id)
        #expect(lines(model.conversation(for: parent)).last == "Rename sum.txt is waiting on the \(Limit.name(of: "seven_day")), which resets at \(Limit.time(weekReset))")
        #expect(lines(model.conversation(for: parent)).count == 6)
    }

    @Test func atTheResetAThreadGoesOnOrItsOpenerHearsItWont() throws {
        UserDefaults.standard.removeObject(forKey: Limit.goOnKey)
        let (model, parent) = try model()
        model.engineState = .ready
        let resetsAt = Date.now.addingTimeInterval(3600)
        func waiting() throws -> Chat {
            let asked = request(parent)
            let chat = try model.open(model.opening(for: asked), asked)
            chat.sessionId = "session-\(chat.id)"
            model.route(limited(chat, resetsAt: resetsAt))
            model.route(done(chat, "stop_sequence"))
            return chat
        }
        let goesOn = try waiting(), refused = try waiting(), lost = try waiting()
        let stopped = "Rename sum.txt stopped before its first turn finished"
        #expect(lines(model.conversation(for: parent)).count == 3)
        // The reset has come, and the last of them lost its session meanwhile.
        lost.sessionId = nil
        for chat in [goesOn, refused, lost] { chat.resumeAt = Date.now.addingTimeInterval(-60) }

        model.resumeDue()
        #expect(model.conversation(for: goesOn).running && model.conversation(for: refused).running)
        #expect(lost.resumeAt == nil && !model.conversation(for: lost).running && lost.owesOpener == false)
        #expect(lines(model.conversation(for: parent)).count == 4 && lines(model.conversation(for: parent)).last == stopped)

        model.route(done(goesOn))
        #expect(lines(model.conversation(for: parent)).last == "Rename sum.txt finished its first turn")
        // What startTurn does with a send the engine turned down.
        model.sendRefused(in: refused, "The engine stopped.")
        #expect(lines(model.conversation(for: parent)).last == stopped)
        #expect(lines(model.conversation(for: parent)).count == 6)
        #expect(lines(Conversation(chat: parent, context: container.mainContext)).count == 6)
    }

    @Test func aFirstSendTheEngineRefusedTellsItsOpenerAtOnceAndLaterTurnsNothing() throws {
        let (model, parent) = try model()
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        model.sendRefused(in: chat, "That folder is gone.")
        #expect(lines(model.conversation(for: parent)) == ["Rename sum.txt stopped before its first turn finished"])
        #expect(!model.conversation(for: chat).running)

        #expect(model.send("Try again", images: [], in: chat))
        model.route(done(chat))
        #expect(lines(Conversation(chat: parent, context: container.mainContext)).count == 1)
    }

    @Test func aThreadOpenedBeforeALineCouldWaitAndItsStoredLineReadAsTheyDid() throws {
        let (model, parent) = try model()
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        chat.owesOpener = nil
        model.route(done(chat))
        #expect(model.send("And the tests", images: [], in: chat))
        model.route(done(chat))
        #expect(lines(model.conversation(for: parent)) == ["Rename sum.txt finished its first turn"])

        // A line stored then has no reset, and reads as it did.
        let old: JSON = ["event": "thread.done", "thread": .string(chat.id.uuidString), "title": "Old one", "finished": false]
        model.conversations[parent.id] = nil
        model.selectedChatID = nil
        Conversation.line("thread.done", old, unread: parent, in: container.mainContext)
        #expect(lines(Conversation(chat: parent, context: container.mainContext)).last == "Old one stopped before its first turn finished")
    }
}
