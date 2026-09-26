import Foundation
import Testing
@testable import OriCode

/// Tab at the shell prompt and after an `@`, against a folder made for it.
struct CompletionTests {
    private let folder: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "completion-\(UUID().uuidString)")
        for path in ["App/Composer.swift", "App/Conversation.swift", "My Notes/todo.txt", ".hidden/x", "web/(marketing)/page.tsx"] {
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

    @Test func aMentionIsThePathAsClaudeReadsItQuotedWhenItHasASpace() {
        // Claude reads `@path` to the next space, so nothing in it is escaped.
        #expect(ShellCompletion.mention("see @web/(mar", folder: folder)?.text == "see @web/(marketing)/")
        #expect(ShellCompletion.mention("see @web/(marketing)/pa", folder: folder)?.text == "see @web/(marketing)/page.tsx ")
        // A space puts it in quotes, left open on a folder so the next Tab goes on inside them.
        #expect(ShellCompletion.mention("see @My", folder: folder)?.text == "see @\"My Notes/")
        #expect(ShellCompletion.mention("see @\"My Notes/to", folder: folder)?.text == "see @\"My Notes/todo.txt\" ")
        #expect(ShellCompletion.mention("see @\"App/Comp", folder: folder)?.text == "see @\"App/Composer.swift\" ")
        // A closed quote is done with; the word after it is a mention of its own.
        #expect(ShellCompletion.mention("@\"My Notes/todo.txt\" and @REA", folder: folder)?.text == "@\"My Notes/todo.txt\" and @README.md ")
        let several = ShellCompletion.mention("see @\"App/Co", folder: folder)
        #expect(several?.text == "see @\"App/Co")
        #expect(several?.head == "see ")
        #expect(several?.candidates == ["@\"App/Composer.swift\"", "@\"App/Conversation.swift\""])
    }

    /// Rows as Completion.zsh prints them for `git che` in a repo.
    private static let gitChe = [
        "4\u{1F}checkout\u{1F}checkout         -- checkout branch or paths to working tree\u{1F}J-default-",
        "4\u{1F}cherry-pick\u{1F}cherry-pick      -- apply changes introduced by some existing commits\u{1F}J-default-",
        "4\u{1F}cherry\u{1F}cherry           -- find commits not merged upstream\u{1F}J-default-",
        "4\u{1F}check-attr\u{1F}check-attr       -- display gitattributes information\u{1F}J-default-",
        "\u{1D}git che",
    ].joined(separator: "\n")

    @Test func zshsMatchesAreListedSortedWithWhatItSaysOfThem() {
        let result = ShellCompletion.zsh(Self.gitChe, line: "git che")
        #expect(result?.text == "git che")
        #expect(result?.head == "git ")
        #expect(result?.candidates == ["check-attr", "checkout", "cherry", "cherry-pick"])
        #expect(result?.descriptions["checkout"] == "checkout branch or paths to working tree")
    }

    @Test func oneMatchFromZshIsTheLineAsZshLeftIt() {
        // A branch that's also a remote's is added twice.
        let answer = "13\u{1F}main\u{1F}\u{1F}J-default-\n13\u{1F}main\u{1F}\u{1F}J-default-\n\u{1D}git checkout main "
        #expect(ShellCompletion.zsh(answer, line: "git checkout ma") == ShellCompletion.Result(text: "git checkout main ", head: "git checkout ", candidates: []))
        // Inside quotes the word starts at the quote, and zsh closes it on a file.
        let quoted = "4\u{1F}\"My Notes/todo.txt\u{1F}\u{1F}J-default-\n\u{1D}cat \"My Notes/todo.txt\" "
        #expect(ShellCompletion.zsh(quoted, line: "cat \"My Notes/to")?.text == "cat \"My Notes/todo.txt\" ")
    }

    @Test func zshsGroupsKeepTheirOrderAndAnUnsortedOneStaysSo() {
        let answer = [
            "5\u{1F}test\u{1F}\u{1F}J-default-",
            "5\u{1F}Tests/\u{1F}\u{1F}J-default-",
            "5\u{1F}zeta\u{1F}\u{1F}Vrecent",
            "5\u{1F}alpha\u{1F}\u{1F}Vrecent",
            "\u{1B}[K\u{1D}make te",
        ].joined(separator: "\n")
        #expect(ShellCompletion.zsh(answer, line: "make te")?.candidates == ["Tests/", "test", "zeta", "alpha"])
    }

    @Test func aWordZshStartsFurtherOnKeepsWhatComesBefore() {
        let answer = "3\u{1F}--color=\u{1F}\u{1F}J-default-\n11\u{1F}auto\u{1F}\u{1F}J-default-\n\u{1D}ls --color="
        let result = ShellCompletion.zsh(answer, line: "ls --color=au")
        #expect(result?.head == "ls ")
        #expect(result?.candidates == ["--color=", "--color=auto"])
    }

    @Test func nothingFromZshIsLeftToThePaths() {
        #expect(ShellCompletion.zsh("\u{1D}npm run bu", line: "npm run bu") == nil)
        #expect(ShellCompletion.zsh("", line: "npm run bu") == nil)
        #expect(ShellCompletion.zsh("4\u{1F}README.md\u{1F}\u{1F}J-default-", line: "cat REA") == nil)
    }

    /// The real thing: zsh behind a pty with a startup folder of the test's own, compinit and
    /// nothing else, asked in a folder of files. It can miss the patience while it starts, so
    /// it's asked until it answers.
    @Test func zshAnswersBehindItsPty() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "zdotdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "autoload -Uz compinit && compinit -D\n".write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let zsh = try #require(ZshCompletion(userFolder: home.path))
        func ask(_ line: String) async -> ShellCompletion.Result? {
            for _ in 0..<10 {
                if let answer = await zsh.matches(of: line, in: folder) { return ShellCompletion.zsh(answer, line: line) }
            }
            return nil
        }
        #expect(await ask("cat REA")?.text == "cat README.md ")
        #expect(await ask("cat My")?.text == "cat My\\ Notes/")
        let git = await ask("git che")
        #expect(git?.text == "git che")
        #expect(Set(["checkout", "cherry", "cherry-pick"]).isSubset(of: git?.candidates ?? []))
        #expect(git?.descriptions["cherry-pick"]?.isEmpty == false)
    }

    @Test func theWordIsWhatFollowsTheLastSpaceNotEscaped() {
        #expect(ShellCompletion.split("cat My\\ No").word == "My\\ No")
        #expect(ShellCompletion.split("ls ").word == "")
    }
}
