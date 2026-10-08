import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread an agent suggested with suggest_thread: where its button lands in the transcript, that
/// it's still there read from the store, and what a click on it makes.
@MainActor
struct SuggestedThreadsTests {
    private let container: ModelContainer
    private let project: Project
    private let other: Project
    private let prompt = "README.md says npm install; the repo uses pnpm. Fix the install line."

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: "/tmp/alpha")
        other = Project(name: "beta", path: "/tmp/beta")
        container.mainContext.insert(project)
        container.mainContext.insert(other)
        try container.mainContext.save()
    }

    /// A model with a started thread open in alpha.
    private func model() throws -> (AppModel, Chat) {
        let model = AppModel(container: container)
        model.support = FileManager.default.temporaryDirectory.appending(path: "oricode-suggested-\(UUID().uuidString)", directoryHint: .isDirectory)
        model.providers = [.claude]
        let chat = Chat(project: project, title: "Sums")
        chat.provider = "claude"
        chat.started = true
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        return (model, chat)
    }

    private func event(_ name: String, _ chat: Chat, _ body: JSON = [:]) -> EngineEvent {
        EngineEvent(name: name, threadId: chat.id.uuidString, body: body)
    }

    private func suggested(_ chat: Chat, title: String = "Fix the README's install line", text: String? = nil) -> EngineEvent {
        event("thread.suggested", chat, ["event": "thread.suggested", "title": .string(title), "text": .string(text ?? prompt)])
    }

    private func buttons(_ conversation: Conversation) -> [String] {
        conversation.items.compactMap { if case .suggested(_, let title, _) = $0 { title } else { nil } }
    }

    @Test func aSuggestionWaitsForItsTurnsEndAndIsStoredUnderTheReply() throws {
        let (model, chat) = try model()
        let conversation = model.conversation(for: chat)
        conversation.userSent("Add the totals")
        model.route(event("turn.started", chat))
        model.route(event("text", chat, ["delta": "Added. The README"]))
        model.route(suggested(chat))
        // The reply it came in the middle of stays one reply.
        #expect(buttons(conversation).isEmpty)
        model.route(event("text", chat, ["delta": " is out of date too."]))
        model.route(event("turn.done", chat, ["stopReason": "end_turn"]))
        #expect(buttons(conversation) == ["Fix the README's install line"])

        // Read from the store, as after a relaunch: one reply, its footer, then the button.
        let read = Conversation(chat: chat, context: container.mainContext)
        #expect(read.items.count { if case .text(_, "Added. The README is out of date too.") = $0 { true } else { false } } == 1)
        guard case .suggested(_, let title, let kept) = read.items.last, case .footer = read.items.dropLast().last else {
            Issue.record("the button doesn't follow the turn")
            return
        }
        #expect(title == "Fix the README's install line")
        #expect(kept == prompt)
    }

    @Test func aStoppedTurnKeepsWhatItSuggestedAndOneWithNoPromptMakesNoButton() throws {
        let (model, chat) = try model()
        let conversation = model.conversation(for: chat)
        conversation.userSent("Add the totals")
        model.route(event("turn.started", chat))
        model.route(suggested(chat))
        model.route(suggested(chat, title: "Nothing to start on", text: ""))
        model.route(suggested(chat, title: "", text: "docs/setup.md names a script that was deleted.\nRemove the step."))
        conversation.stopped()
        // Without a title the button takes the prompt's first line.
        #expect(buttons(conversation) == ["Fix the README's install line", "docs/setup.md names a script that was deleted."])
        // With no turn running there is no reply to wait for.
        model.route(suggested(chat, title: "Later"))
        #expect(buttons(conversation).last == "Later")
    }

    @Test func aClickMakesADraftInTheSameProjectWithThePromptForTheComposerUnsent() throws {
        let (model, chat) = try model()
        // Another project is the one open in the drawer's menu, with a draft of its own.
        let elsewhere = Chat(project: other)
        container.mainContext.insert(elsewhere)
        model.selectedProjectID = other.id
        let focus = model.composerFocus

        let thread = try #require(model.openSuggested(title: "Fix the README's install line", prompt: prompt, from: chat))
        #expect(thread.project?.id == project.id)
        #expect(thread.cwd == project.path)
        #expect(thread.title == "Fix the README's install line")
        #expect(thread.titleIsCustom)
        #expect(model.selectedProjectID == project.id)
        #expect(model.selectedChatID == thread.id)
        // Opening it puts the cursor in the composer, as opening any thread does.
        #expect(model.composerFocus == focus + 1)
        // Nothing was sent: it's a draft with an empty transcript, and the prompt is the composer's to take.
        #expect(!thread.started)
        #expect(thread.openedBy == nil)
        let conversation = try #require(model.currentConversation)
        #expect(conversation.items.isEmpty)
        #expect(!conversation.running)
        #expect(conversation.takeHandedBack().map(\.text) == [prompt])
        #expect(conversation.returning.isEmpty)
        // The other project's draft is left alone, and the thread that suggested it is as it was.
        #expect(other.chats.map(\.id) == [elsewhere.id])
        #expect(chat.project?.id == project.id)

        // A second click leaves one draft in the project, not two.
        let again = try #require(model.openSuggested(title: "Fix the README's install line", prompt: prompt, from: chat))
        #expect(project.chats.filter { !$0.started }.map(\.id) == [again.id])
    }

    /// The composer's field as it is once it has taken what the open thread handed back.
    private func field(_ text: String, taking model: AppModel) throws -> String {
        let back = try #require(model.currentConversation).takeHandedBack()
        let typed = back.compactMap(\.replaces).reduce(text) { QueuedMessage.text($0, without: $1) }
        return QueuedMessage.joined(back.map(\.text) + [typed])
    }

    @Test func aSecondSuggestionTakesTheFirstsPlaceInTheComposer() throws {
        let (model, chat) = try model()
        let second = "docs/setup.md names a script that was deleted. Remove the step."
        model.openSuggested(title: "Fix the README's install line", prompt: prompt, from: chat)
        var text = try field("", taking: model)
        #expect(text == prompt)

        // Back in the first thread with nothing sent, the reply's other button.
        model.selectedChatID = chat.id
        let thread = try #require(model.openSuggested(title: "Drop the deleted script from setup", prompt: second, from: chat))
        text = try field(text, taking: model)
        #expect(text == second)
        #expect(thread.title == "Drop the deleted script from setup")
        #expect(project.chats.filter { !$0.started }.map(\.id) == [thread.id])

        // The same button twice leaves its prompt there once, and what was typed under it stays.
        model.openSuggested(title: "Drop the deleted script from setup", prompt: second, from: chat)
        text = try field(text + "\n\nAnd say so in the changelog.", taking: model)
        #expect(text == second + "\n\nAnd say so in the changelog.")

        // A prompt the user has changed is theirs, and stays under the next one.
        let changed = "docs/setup.md: remove the step for the deleted script."
        model.openSuggested(title: "Fix the README's install line", prompt: prompt, from: chat)
        #expect(try field(changed, taking: model) == prompt + "\n\n" + changed)
    }

    @Test func aTurnALimitStoppedIsStillKnownByItsLimitUnderWhatItSuggested() throws {
        let (model, chat) = try model()
        let conversation = model.conversation(for: chat)
        conversation.userSent("Add the totals")
        model.route(event("turn.started", chat))
        model.route(suggested(chat))
        model.route(event("limited", chat, ["event": "limited", "resetsAt": .number(Date.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000), "window": "five_hour"]))
        model.route(event("turn.done", chat, ["stopReason": "end_turn"]))
        #expect(buttons(conversation) == ["Fix the README's install line"])
        guard case .suggested = conversation.items.last else {
            Issue.record("the button isn't the last line")
            return
        }
        #expect(conversation.turnLimit?.window == "five_hour")
        model.resumeTask?.cancel()

        // A send the engine refused ends in its note, which Send the last message again goes by.
        conversation.userSent("And the averages")
        model.route(suggested(chat, title: "Later"))
        conversation.sendFailed("The engine isn't running.")
        #expect(buttons(conversation).last == "Later")
        guard case .note = conversation.items.last(where: { !$0.followsTurn }) else {
            Issue.record("the note isn't the turn's last line")
            return
        }
    }
}
