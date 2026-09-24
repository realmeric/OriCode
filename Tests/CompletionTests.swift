import Foundation
import Testing
@testable import OriCode

/// Tab at the shell prompt and after an `@`, against a folder made for it.
struct CompletionTests {
    private let folder: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "completion-\(UUID().uuidString)")
        for path in ["App/Composer.swift", "App/Conversation.swift", "My Notes/todo.txt", ".hidden/x"] {
            let file = url.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        try Data().write(to: url.appending(path: "README.md"))
        folder = url.path
    }

    @Test func oneMatchCompletesWholeAFolderWithItsSlashAndAFileWithASpace() {
        #expect(ShellCompletion.complete("cat REA", folder: folder, commands: [])?.text == "cat README.md ")
        #expect(ShellCompletion.complete("cd Ap", folder: folder, commands: [])?.text == "cd App/")
        #expect(ShellCompletion.complete("open App/Comp", folder: folder, commands: [])?.text == "open App/Composer.swift ")
    }

    @Test func severalCompleteAsFarAsTheyAgreeAndAreListed() {
        let result = ShellCompletion.complete("vim App/Co", folder: folder, commands: [])
        #expect(result?.text == "vim App/Co")
        #expect(result?.candidates == ["App/Composer.swift", "App/Conversation.swift"])
    }

    @Test func spacesAreEscapedAndHiddenFilesWaitForADot() {
        #expect(ShellCompletion.complete("cat My", folder: folder, commands: [])?.text == "cat My\\ Notes/")
        #expect(ShellCompletion.complete("cat My\\ Notes/to", folder: folder, commands: [])?.text == "cat My\\ Notes/todo.txt ")
        #expect(ShellCompletion.complete("ls .hid", folder: folder, commands: [])?.text == "ls .hidden/")
        #expect(ShellCompletion.complete("ls ", folder: folder, commands: [])?.candidates.contains(".hidden/") == false)
    }

    @Test func theFirstWordIsACommand() {
        let commands = ["make", "man", "git", "gs"]
        #expect(ShellCompletion.complete("gi", folder: folder, commands: commands)?.text == "git ")
        let many = ShellCompletion.complete("ma", folder: folder, commands: commands)
        #expect(many?.text == "ma" && many?.candidates == ["make", "man"])
        #expect(ShellCompletion.complete("./REA", folder: folder, commands: commands)?.text == "./README.md ")
    }

    @Test func aMentionCompletesAPathForClaude() {
        #expect(ShellCompletion.mention("look at @App/Conv", folder: folder)?.text == "look at @App/Conversation.swift ")
        #expect(ShellCompletion.mention("look at App/Conv", folder: folder) == nil)
    }

    @Test func theWordIsWhatFollowsTheLastSpaceNotEscaped() {
        #expect(ShellCompletion.split("cat My\\ No").word == "My\\ No")
        #expect(ShellCompletion.split("ls ").word == "")
    }
}
