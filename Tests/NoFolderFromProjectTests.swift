import Foundation
import SwiftData
import Testing
@testable import OriCode

/// No folder reached from inside a project, with one of its threads open and begun, and ⌘K's
/// command for the folder a thread works in.
@MainActor
struct NoFolderFromProjectTests {
    private let container: ModelContainer
    private let model: AppModel
    private let support: URL
    private let alpha: Project
    private let thread: Chat
    private let other: Chat

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        support = FileManager.default.temporaryDirectory.appending(path: "oricode-nofolder-from-\(UUID().uuidString)", directoryHint: .isDirectory)
        alpha = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(alpha)
        thread = Chat(project: alpha, title: "In the project")
        other = Chat(project: alpha, title: "Another")
        for chat in [thread, other] {
            chat.started = true
            container.mainContext.insert(chat)
        }
        try container.mainContext.save()
        model = AppModel(container: container)
        model.support = support
        model.selectedProjectID = alpha.id
        model.selectedChatID = thread.id
    }

    private var folder: String { support.appending(path: "No Folder", directoryHint: .isDirectory).standardizedFileURL.path }

    private func clean() { try? FileManager.default.removeItem(at: support) }

    @Test func itOpensADraftWithTheKeyboardAndTheProjectsThreadKeepsWhatWasTyped() throws {
        defer { clean() }
        model.composer(for: thread).draft.text = "half a thought"
        #expect(model.projects.map(\.name) == ["alpha"])

        model.openThreadWithoutFolder()
        let draft = try #require(model.chat)
        #expect(model.project?.isNoFolder == true && model.inNoFolder)
        #expect(draft.project?.isNoFolder == true && !draft.started && draft.cwd == folder && draft.worktreeBranch == nil)
        // Its own composer, empty, and asked to take the keyboard.
        let composer = model.composer(for: draft)
        #expect(composer !== model.composer(for: thread))
        #expect(composer.isEmpty && composer.focus > 0)
        #expect(model.composerFocus == composer.focus)
        #expect(model.composer(for: thread).draft.text == "half a thought")
        // Not a thread yet: the list is the project's two.
        #expect(Set(model.chats.map(\.id)) == [thread.id, other.id])

        // Asked for again from ⌘K, it's the same draft.
        model.runPaletteCommand("thread.noFolder")
        #expect(model.chat?.id == draft.id)
    }

    @Test func aMessageSentThereStartsAThreadThereAndTheProjectsIsUntouched() throws {
        defer { clean() }
        model.composer(for: thread).draft.text = "half a thought"
        let events = thread.events.count
        model.openThreadWithoutFolder()
        #expect(model.send("What's using the disk on this Mac?"))

        let sent = try #require(model.chat)
        #expect(sent.started && sent.project?.isNoFolder == true && sent.cwd == folder)
        #expect(sent.title == "What's using the disk on this Mac?")
        #expect(model.sendParams(in: sent, text: "hi", images: [])["noFolder"] == true)
        #expect(Set(model.chats.map(\.id)) == [thread.id, other.id, sent.id])
        #expect(thread.project?.id == alpha.id && thread.events.count == events && thread.cwd == "/tmp/alpha")
        #expect(model.conversations[thread.id]?.running != true)

        // Back in the project its thread is as it was, and No folder stays, a thread having begun.
        model.select(thread)
        #expect(model.project?.id == alpha.id && model.chat?.id == thread.id)
        #expect(model.composer(for: thread).draft.text == "half a thought")
        #expect(model.projects.map(\.isNoFolder) == [false, true])
    }

    @Test func leftWithNothingSentItGoesAndTheThreadIsAsItWas() throws {
        defer { clean() }
        model.composer(for: thread).draft.text = "half a thought"
        model.openThreadWithoutFolder()
        #expect(model.projects.map(\.isNoFolder) == [false, true])

        model.select(thread)
        #expect(model.projects.map(\.name) == ["alpha"])
        #expect(model.project?.id == alpha.id && model.chat?.id == thread.id)
        #expect(model.composer(for: thread).draft.text == "half a thought")
        #expect(!FileManager.default.fileExists(atPath: folder))

        // The project picked in the drawer's menu, not one of its threads, does the same, and
        // what was typed in the draft that went is in the next one.
        model.openThreadWithoutFolder()
        model.composer(for: model.chat).draft.text = "for later"
        model.select(alpha)
        #expect(model.composer(for: model.chat).draft.text != "for later")
        model.openThreadWithoutFolder()
        #expect(model.composer(for: model.chat).draft.text == "for later")
        model.select(alpha)
        #expect(model.projects.map(\.name) == ["alpha"])
        #expect(model.chat?.project?.id == alpha.id)
    }

    @Test func aPairWaitsBehindTheDraftAndIsBackWithTheProjectsThread() throws {
        defer { clean() }
        model.openBeside(other)
        #expect(model.besideShown?.id == other.id)

        // A draft has the window to itself, as any new thread does.
        model.openThreadWithoutFolder()
        #expect(model.chat?.project?.isNoFolder == true && model.besideShown == nil)

        model.select(thread)
        #expect(model.chat?.id == thread.id && model.besideShown?.id == other.id)
        #expect(model.projects.map(\.name) == ["alpha"])
    }

    @Test func commandCenterOpensTheFolderTheThreadWorksIn() throws {
        defer { clean() }
        let open = try #require(model.paletteSearchable().first { $0.id == "project.reveal" })
        #expect(open.title == "Open project folder in Finder" && open.unavailable == nil)
        #expect(model.workingFolder == "/tmp/alpha")
        // The words someone looks for it by, beside the command that copies the same path.
        for query in ["open", "finder", "folder", "path", "open project path"] {
            let found = Palette.rank(model.paletteSearchable(), by: query).map(\.id)
            #expect(found.contains("project.reveal"), "\(query) doesn't find it")
        }
        #expect(Palette.rank(model.paletteSearchable(), by: "open folder").first?.id == "project.reveal")
        // Reveal in Finder, its name until now, reaches it typed whole or in part, ahead of the review.
        #expect(model.paletteSearchable().contains { $0.id == "changes" && $0.title == "Review changes" })
        for query in ["reveal", "reve", "reveal in", "reveal in finder"] {
            #expect(Palette.rank(model.paletteSearchable(), by: query).first?.id == "project.reveal", "\(query) doesn't put it first")
        }

        // A thread on its own branch works in its worktree, and that's the folder opened and copied.
        let branch = Chat(project: alpha, title: "On a branch")
        branch.started = true
        branch.cwd = "/tmp/alpha-worktrees/t-1a2b3c"
        branch.worktreeBranch = "oricode/t-1a2b3c"
        container.mainContext.insert(branch)
        try container.mainContext.save()
        model.touch()
        model.select(branch)
        #expect(model.workingFolder == "/tmp/alpha-worktrees/t-1a2b3c")
        #expect(model.paletteSearchable().contains { $0.id == "project.reveal" && $0.title == "Open project folder in Finder" })

        // No folder keeps its one command for Finder, under the same words.
        model.openThreadWithoutFolder()
        let finder = model.paletteSearchable().filter { $0.kind == .command && $0.title.contains("Finder") }
        #expect(finder.map(\.title) == ["Reveal the scratch folder in Finder"])
        #expect(Palette.rank(model.paletteSearchable(), by: "open").contains { $0.id == "project.reveal" })
    }

    @Test func aFolderThatIsGoneSaysSo() throws {
        defer { clean() }
        let gone = FileManager.default.temporaryDirectory.appending(path: "oricode-gone-\(UUID().uuidString)").path
        thread.cwd = gone
        model.save()
        model.runPaletteCommand("project.reveal")
        #expect(model.note == "\(gone) isn't there")
    }
}
