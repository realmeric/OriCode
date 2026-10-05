import Foundation
import SwiftData
import Testing
@testable import OriCode

@MainActor
struct ProjectsTests {
    @Test func aFolderWithoutGitIsAProject() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = AppModel(container: container)
        let folder = FileManager.default.temporaryDirectory.appending(path: "oricode-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        model.addProject(at: folder)

        #expect(model.projects.map(\.path) == [folder.standardizedFileURL.path])
        #expect(model.project?.name == folder.lastPathComponent)
        model.addProject(at: folder)
        #expect(model.projects.count == 1)
    }

    @Test func anArchivedThreadLeavesTheListAndComesBackWhole() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let alpha = Project(name: "alpha", path: "/tmp/alpha")
        let beta = Project(name: "beta", path: "/tmp/beta")
        context.insert(alpha)
        context.insert(beta)
        let first = Chat(project: alpha, title: "First")
        let second = Chat(project: alpha, title: "Second")
        let other = Chat(project: beta, title: "Other")
        for chat in [first, second, other] {
            chat.started = true
            context.insert(chat)
        }
        first.sessionId = "s-1"
        first.pinned = true
        try context.save()
        let model = AppModel(container: container)
        model.selectedProjectID = alpha.id
        model.selectedChatID = first.id

        model.archive(first)
        #expect(!model.chats.contains { $0.id == first.id })
        #expect(model.archivedChats.map(\.id) == [first.id])
        // The next thread of the same project is the one open.
        #expect(model.selectedChatID == second.id)
        #expect(first.sessionId == "s-1" && !first.pinned)

        model.drawerFilter = .project(beta.id)
        #expect(model.chats.map(\.id) == [other.id])
        model.drawerFilter = .working
        #expect(model.chats.isEmpty)

        model.restore(first)
        #expect(model.drawerFilter == .all)
        #expect(model.chats.contains { $0.id == first.id })
        #expect(model.selectedChatID == first.id && model.archivedChats.isEmpty)
    }

    @Test func aSessionFromTerminalOpensAsAThreadWithItsTranscript() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        try container.mainContext.save()
        let model = AppModel(container: container)
        let events: [JSON] = [
            ["event": "user", "text": "Read the Makefile"],
            ["event": "text", "delta": "Reading it."],
            ["event": "tool.use", "toolUseId": "t1", "name": "Read", "input": ["file_path": "Makefile"]],
            ["event": "tool.result", "toolUseId": "t1", "content": "all:", "isError": false],
            ["event": "user", "text": "And the tests?"],
            ["event": "text", "delta": "They pass."],
        ]
        let chat = model.adopt(CLISession(id: "s-9", title: "Read the Makefile", modified: 0, branch: nil), events: events, in: project)
        #expect(chat.sessionId == "s-9" && chat.started && chat.cwd == "/tmp/alpha")
        #expect(model.chats.map(\.id) == [chat.id])
        let conversation = model.conversation(for: chat)
        #expect(conversation.items.count == 5)
        #expect(!conversation.running)
        if case .tool(_, let call) = conversation.items[2] { #expect(call.result == "all:") } else { Issue.record("the call should be third") }
        #expect(Set(chat.events.map(\.turn)) == [1, 2])
    }

    @Test func theArchivedFilterListsWhatIsPutAwayAndAMessageBringsAThreadBack() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        let kept = Chat(project: project, title: "Kept")
        let old = Chat(project: project, title: "Old")
        for chat in [kept, old] {
            chat.started = true
            container.mainContext.insert(chat)
        }
        old.archived = true
        try container.mainContext.save()
        let model = AppModel(container: container)
        #expect(model.chats.map(\.title) == ["Kept"])
        model.drawerFilter = .archived
        #expect(model.chats.map(\.title) == ["Old"])
        #expect(DrawerFilter.archived.title(in: []) == "archived threads")
        // Written to again, it's a thread in use.
        model.conversation(for: old).userSent("Still there?")
        #expect(!old.archived)
        model.save()
        #expect(model.chats.isEmpty)
        model.drawerFilter = .all
        #expect(Set(model.chats.map(\.id)) == [kept.id, old.id])
    }

    @Test func aCommandRunsByItsIdAsAnActionOfYourOwnWouldRunIt() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = AppModel(container: container)
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: TranscriptSettings.showThinking)
        defer { defaults.set(before, forKey: TranscriptSettings.showThinking) }
        defaults.set(true, forKey: TranscriptSettings.showThinking)
        model.runPaletteCommand("transcript.thinking")
        #expect(defaults.bool(forKey: TranscriptSettings.showThinking) == false)
        // One that opens a list opens ⌘K on it.
        #expect(!model.commandCenterShown)
        model.runPaletteCommand("threads.filter")
        #expect(model.commandCenterShown)
        model.closeCommandCenter()
        model.runPaletteCommand("no.such.command")
        #expect(model.note == "There's no command called no.such.command")
        // Every command an action can stand for has a name, and the new ones are among them.
        let ids = Set(model.commandChoices.map(\.id))
        #expect(ids.isSuperset(of: ["threads.archived", "threads.filter", "review.ask", "transcript.thinking", "replies.concise", "settings.archive"]))
        #expect(!ids.contains { $0.hasPrefix("action.") })
    }

    @Test func anActionsKeyIsRefusedWhenSomethingElseHasIt() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = AppModel(container: container)
        let action = CustomAction(name: "Open archive", command: "threads.archived", runs: .builtIn)
        #expect(model.refusal(KeyCombo("a", []), for: action) == "A key of your own needs ⌘ or ⌃")
        #expect(model.refusal(KeyCombo("q"), for: action) == "⌘Q is Quit")
        #expect(model.refusal(model.shortcuts[.commandCenter], for: action)?.hasSuffix("is Command Center") == true)
        #expect(model.refusal(KeyCombo("3"), for: action) == "⌘3 goes to a thread")
        #expect(model.refusal(KeyCombo("a", [.command, .control]), for: action) == nil)
    }
}
