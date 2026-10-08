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
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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
        guard case .user(_, let text, _, let midTurn) = conversation.items.first else {
            Issue.record("no first message")
            return
        }
        #expect(text == "Rename sum.txt to total.txt." && !midTurn)
        #expect(conversation.running)
        // In the drawer from its first message, above its parent, which stays the thread on screen.
        #expect(model.chats.map(\.id) == [chat.id, parent.id])
        #expect(model.selectedChatID == parent.id)
        // The tool's answer names it.
        #expect(AppModel.made(chat, on: .claude) == ["thread": "Rename sum.txt", "agent": "claude", "mode": "acceptEdits", "folder": "/tmp/alpha", "model": "opus"])
    }

    @Test func itsSendsTellTheEngineAnotherThreadOpenedIt() throws {
        let (model, parent) = try model()
        let asked = request(parent)
        let chat = try model.open(model.opening(for: asked), asked)
        #expect(model.sendParams(in: chat, text: "hi", images: [])["opened"] == true)
        #expect(model.sendParams(in: parent, text: "hi", images: [])["opened"] == nil)
        // And the app refuses it a thread of its own, whatever the engine let through.
        #expect(refusal(model, request(chat)) == "Another thread opened this one, so it can't open threads of its own.")
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
        #expect(model.chats.map(\.id) == [chat.id, parent.id])
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
            if case .opened(_, _, let title, let finished) = item { OpenedLine.words(title: title, finished: finished) } else { nil }
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
        guard case .opened(_, let thread, _, _) = read.items.last else {
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
}
