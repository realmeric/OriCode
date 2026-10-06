import Foundation
import SwiftData
import Testing
@testable import OriCode

/// No folder: the one project that isn't a folder of the user's, for a thread that needs none.
@MainActor
struct NoFolderTests {
    private let container: ModelContainer
    private let support: URL

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        support = FileManager.default.temporaryDirectory.appending(path: "oricode-nofolder-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// A model whose support folder is the test's own, with nothing open.
    private func model() -> AppModel {
        let model = AppModel(container: container)
        model.support = support
        model.selectedProjectID = nil
        model.selectedChatID = nil
        return model
    }

    private var folder: String { support.appending(path: "No Folder", directoryHint: .isDirectory).standardizedFileURL.path }

    private func clean() { try? FileManager.default.removeItem(at: support) }

    @Test func itIsMadeOnFirstUseAndFoundAgain() throws {
        defer { clean() }
        let model = model()
        // Nothing of it at launch: no project, and no folder.
        #expect(model.projects.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder))

        let made = model.noFolderProject()
        #expect(made.isNoFolder && made.id == Project.noFolderID)
        #expect(made.name == "No folder")
        #expect(made.path == folder)
        #expect(made.path.hasPrefix(support.standardizedFileURL.path + "/"))
        #expect(made.colorIndex == nil)
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).isEmpty)

        // A second use makes no second one, here or on the store's next model.
        #expect(model.noFolderProject().id == made.id)
        #expect(model.projects.count == 1)
        let next = self.model()
        #expect(next.noFolderProject().id == made.id)
        #expect(next.projects.count == 1)
        // The launch that colours old projects leaves it without one.
        next.colourProjects()
        #expect(next.projects.first?.colorIndex == nil)
    }

    @Test func itFollowsASupportFolderThatMovedAndIsKnownByItsIdAlone() throws {
        defer { clean() }
        let model = model()
        let made = model.noFolderProject()
        made.name = "Scratch"
        let moved = FileManager.default.temporaryDirectory.appending(path: "oricode-nofolder-moved-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: moved) }
        model.support = moved
        let found = model.noFolderProject()
        #expect(found.id == made.id && model.projects.count == 1)
        #expect(found.path == moved.appending(path: "No Folder", directoryHint: .isDirectory).standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: found.path))
    }

    @Test func itComesAfterTheFoldersWhereverProjectsAreListed() throws {
        defer { clean() }
        let model = model()
        _ = model.noFolderProject()
        let added = FileManager.default.temporaryDirectory.appending(path: "oricode-nofolder-added-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: added) }
        model.addProject(at: added)
        #expect(model.projects.map(\.isNoFolder) == [false, true])
        // A folder gets a colour as it always did.
        #expect(model.projects.first?.colorIndex != nil)
    }

    @Test func removingItTakesItsFolderOnlyWhenTheFolderIsEmpty() throws {
        defer { clean() }
        let model = model()
        let project = model.noFolderProject()
        model.select(project)
        let chat = try #require(model.newChat())
        chat.started = true
        model.save()
        let kept = URL(filePath: folder).appending(path: "notes.txt")
        try Data("mine".utf8).write(to: kept)

        model.remove(project)
        #expect(model.projects.isEmpty && model.project == nil && model.chat == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == ["notes.txt"])
        #expect(try String(contentsOf: kept, encoding: .utf8) == "mine")

        // Made again on the next use, in the same folder, with what was left in it.
        let again = model.noFolderProject()
        #expect(again.isNoFolder && again.chats.isEmpty && again.path == folder)
        try FileManager.default.removeItem(at: kept)
        model.remove(again)
        #expect(!FileManager.default.fileExists(atPath: folder))
        // The support folder itself, and anything beside the folder, is never its to take.
        #expect(FileManager.default.fileExists(atPath: support.path))
    }

    @Test func commandCenterStartsAThreadWithoutAFolder() throws {
        defer { clean() }
        let model = model()
        let added = FileManager.default.temporaryDirectory.appending(path: "oricode-nofolder-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: added) }
        model.addProject(at: added)
        #expect(model.commandChoices.contains { $0.id == "thread.noFolder" && $0.title == "New thread without a folder" })
        #expect(model.projects.count == 1)

        model.runPaletteCommand("thread.noFolder")
        #expect(model.project?.isNoFolder == true)
        let draft = try #require(model.chat)
        #expect(draft.project?.isNoFolder == true && draft.cwd == folder && !draft.started && draft.worktreeBranch == nil)
        // Again, and it's the same draft, in the same one project.
        model.runPaletteCommand("thread.noFolder")
        #expect(model.chat?.id == draft.id)
        #expect(model.projects.filter(\.isNoFolder).count == 1)
    }

    @Test func aMessageSentWithNoProjectAtAllLandsInIt() throws {
        defer { clean() }
        let model = model()
        #expect(model.project == nil && model.chat == nil)
        #expect(model.send("What's using the disk on this Mac?"))
        let project = try #require(model.project)
        let chat = try #require(model.chat)
        #expect(project.isNoFolder && model.projects.count == 1)
        #expect(chat.project?.id == project.id && chat.started && chat.cwd == folder)
        #expect(chat.title == "What's using the disk on this Mac?")
        #expect(model.chats.map(\.id) == [chat.id])
        // The engine is told, so the session hears where it is; a folder's thread says nothing.
        #expect(model.sendParams(in: chat, text: "hi", images: [])["noFolder"] == true)
        let folderProject = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(folderProject)
        let other = Chat(project: folderProject)
        container.mainContext.insert(other)
        #expect(model.sendParams(in: other, text: "hi", images: [])["noFolder"] == nil)
    }

    @Test func whatNeedsGitIsNotOfferedForIt() throws {
        defer { clean() }
        let model = model()
        let alpha = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(alpha)
        try container.mainContext.save()
        model.touch()
        model.select(alpha)
        let needsGit: (String) -> Bool = { $0 == "thread.branch" || $0 == "thread.session" || $0.hasPrefix("git.") || $0.hasPrefix("pr.") }
        // A folder's own commands are as they were.
        let before = Set(model.commandChoices.map(\.id))
        #expect(before.isSuperset(of: ["thread.branch", "thread.session", "git.switch", "git.create", "git.pull", "git.push", "git.web", "pr.create"]))

        model.openThreadWithoutFolder()
        let ids = model.paletteSearchable().filter { $0.kind == .command }.map(\.id)
        #expect(ids.filter(needsGit).isEmpty)
        #expect(Set(ids).isSuperset(of: ["thread.new", "thread.noFolder", "changes", "project.reveal", "project.copyPath", "project.remove"]))
        // Settings › Actions still lists them, for an action that's another project's.
        #expect(Set(model.commandChoices.map(\.id)).isSuperset(of: ["thread.branch", "thread.session", "git.switch", "git.create", "git.pull", "git.push", "git.web", "pr.create"]))
        // An action bound to one says why nothing happened, not that there's no such command.
        for id in ["git.pull", "pr.create", "pr.checks", "thread.branch"] {
            model.runPaletteCommand("nothing")
            #expect(model.note == "There's no command called nothing")
            model.runPaletteCommand(id)
            #expect(model.note == "No folder has no repository")
        }
        model.runPaletteCommand("thread.session")
        #expect(model.note == "No folder has no Claude Code sessions to open")
        model.runPaletteCommand("git")
        #expect(model.note == "There's no command called git")

        // New threads on a branch of their own, in Settings, still gives it a thread in its folder.
        let defaults = UserDefaults.standard
        let workspace = defaults.string(forKey: NewThreads.workspace)
        defer { defaults.set(workspace, forKey: NewThreads.workspace) }
        defaults.set(NewThreads.worktree, forKey: NewThreads.workspace)
        let draft = try #require(model.chat)
        draft.started = true
        model.save()
        model.openNewThread()
        let next = try #require(model.chat)
        #expect(next.id != draft.id && next.project?.isNoFolder == true && next.worktreeBranch == nil && next.cwd == folder)
        model.openOtherThread()
        #expect(model.chat?.id == next.id)
    }

    @Test func aFolderRemovedByHandIsBackWhenATurnStarts() throws {
        defer { clean() }
        let model = model()
        #expect(model.send("First"))
        let chat = try #require(model.chat)
        try FileManager.default.removeItem(atPath: folder)
        #expect(!FileManager.default.fileExists(atPath: folder))

        model.startTurn(in: chat, text: "Again")
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue)
    }

    @Test func gitIsNotAskedAboutItsFolder() throws {
        defer { clean() }
        let model = model()
        model.engineState = .ready
        let alpha = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(alpha)
        let other = Chat(project: alpha)
        container.mainContext.insert(other)
        // A folder's thread has its branch read.
        #expect(model.refreshBranch(for: other) != nil)

        model.openThreadWithoutFolder()
        let chat = try #require(model.chat)
        #expect(model.refreshBranch(for: chat) == nil)
        #expect(model.branches[chat.id] == nil)
        // The review says what a folder without git gets, and no read is wanted of the engine.
        model.readReview()
        #expect(model.review.folder == folder && !model.review.wanted && model.review.diff == nil)
        #expect(model.review.problem == "This folder isn't a git repository.")
    }

    @Test func leftWithNothingSentItGoes() throws {
        defer { clean() }
        let model = model()
        let added = FileManager.default.temporaryDirectory.appending(path: "oricode-nofolder-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: added) }
        // A model, a level or a mode picked before any folder was added makes it, with a draft.
        model.newChat()
        #expect(model.project?.isNoFolder == true && model.chat?.started == false)
        #expect(FileManager.default.fileExists(atPath: folder))

        model.addProject(at: added)
        #expect(model.projects.map(\.path) == [added.standardizedFileURL.path])
        #expect(model.project?.isNoFolder == false)
        #expect(!FileManager.default.fileExists(atPath: folder))

        // With a thread that was started it stays, whichever project is opened over it.
        model.openThreadWithoutFolder()
        #expect(model.send("Keep this"))
        let kept = try #require(model.chat)
        model.select(try #require(model.projects.first))
        #expect(model.projects.map(\.isNoFolder) == [false, true])
        #expect(model.projects.last?.chats.map(\.id) == [kept.id])
    }

    @Test func withNoProjectAFileIsStillNamedAndNewThreadStartsOne() throws {
        defer { clean() }
        let model = model()
        // The path a name is shortened from, with nothing made for it.
        #expect(model.namingFolder == folder)
        #expect(Composer.naming(URL(filePath: "/tmp/report.pdf"), from: model.namingFolder, in: "Read") == "Read @/tmp/report.pdf ")
        #expect(model.projects.isEmpty && !FileManager.default.fileExists(atPath: folder))
        #expect(!model.inNoFolder)

        // ⌘K's New thread, whatever Settings › New threads says.
        let defaults = UserDefaults.standard
        let workspace = defaults.string(forKey: NewThreads.workspace)
        defer { defaults.set(workspace, forKey: NewThreads.workspace) }
        defaults.set(NewThreads.worktree, forKey: NewThreads.workspace)
        model.runPaletteCommand("thread.new")
        #expect(model.note == nil)
        let draft = try #require(model.chat)
        #expect(model.project?.isNoFolder == true && draft.cwd == folder && !draft.started && model.inNoFolder)
    }
}
