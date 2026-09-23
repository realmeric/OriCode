import Foundation
import Testing
@testable import OriCode

@MainActor
struct CustomActionTests {
    private let values = ActionValues(
        cwd: "/Users/me/My Project", project: "/Users/me/My Project", projectName: "My Project",
        branch: "main", thread: "Fix {input} in O'Brien's code", session: "abc-123")

    @Test func everyValueArrivesSingleQuoted() {
        #expect("a'b $(x)".shellQuoted == #"'a'\''b $(x)'"#)
        #expect(ActionLine.expand("cd {cwd} && git switch {branch}", with: values) == "cd '/Users/me/My Project' && git switch 'main'")
    }

    @Test func aValueIsNeverExpandedTwice() {
        // The thread's title holds {input}; the input mustn't land inside it unquoted.
        let line = ActionLine.expand("echo {thread} {input}", with: values, input: "$(x)")
        #expect(line == #"echo 'Fix {input} in O'\''Brien'\''s code' '$(x)'"#)
    }

    @Test func bracesThatArentPlaceholdersStay() {
        let command = "awk '{print $1}' {a,b} ${HOME} {unknown} ${project} \\{input}"
        #expect(ActionLine.expand(command, with: values, input: "x") == command)
    }

    @Test func aValueInsideTheCommandsOwnQuotesStaysLiteral() throws {
        let value = #"a"b' $(echo RAN) `echo ALSO` \ {input} ${HOME}"#
        let commands = [
            #"printf '%s' {input}"#: value,
            #"printf '%s' "{input}""#: value,
            #"printf '%s' '{input}'"#: value,
            #"printf '%s' "<{input}>""#: "<" + value + ">",
            #"printf '%s' '<{input}>'"#: "<" + value + ">",
        ]
        for shell in ["/bin/zsh", "/bin/bash"] {
            for (command, printed) in commands {
                let line = ActionLine.expand(command, with: values, input: value)
                #expect(try run(line, in: shell) == printed, "\(shell): \(command) became \(line)")
            }
        }
    }

    @Test func aPlaceholderInsideASubstitutionIsRefused() {
        #expect(ActionLine.problem(in: "echo $(git log {branch})") != nil)
        #expect(ActionLine.problem(in: #"echo "$(git log "{branch}")""#) != nil)
        #expect(ActionLine.problem(in: "echo `git log {branch}`") != nil)
        #expect(ActionLine.unavailable("echo $(echo {input})", with: values) != nil)
        #expect(ActionLine.problem(in: #"echo "{branch}" $(date) '(' ")""#) == nil)
    }

    private func run(_ line: String, in shell: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-c", line]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func aMissingValueSaysWhyAndInputNeverBlocks() {
        var bare = values
        bare.branch = nil
        bare.session = nil
        #expect(ActionLine.unavailable("git push origin {branch}", with: bare) == "There's no branch here")
        #expect(ActionLine.unavailable("claude --resume {session}", with: bare) == "This thread has no session yet")
        #expect(ActionLine.unavailable("git switch -c {input}", with: bare) == nil)
        #expect(ActionLine.unavailable("git status", with: ActionValues()) == nil)
    }

    @Test func aHandWrittenActionNeedsOnlyANameAndACommand() throws {
        let decoded = try JSONDecoder().decode([CustomAction].self, from: Data(#"[{"name":"Log","command":"git log -1"}]"#.utf8))
        #expect(decoded.first?.runs == .terminal)
        #expect(decoded.first?.asks == false)
        #expect(decoded.first?.project == nil)
        #expect(CustomAction(name: "x", command: "echo {input}").wantsInput)
    }

    @Test func theFirstRunWritesTheExamplesAndABadFileIsLeftAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "oricode-actions-\(UUID().uuidString)")
        let file = folder.appending(path: "actions.json")
        let store = CustomActionStore(file: file)
        #expect(store.actions.map(\.name) == CustomAction.examples.map(\.name))
        #expect(CustomActionStore(file: file).actions == store.actions)

        try Data("not json".utf8).write(to: file)
        let broken = CustomActionStore(file: file)
        #expect(broken.problem != nil)
        broken.save(CustomAction(name: "New", command: "true"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
        try? FileManager.default.removeItem(at: folder)
    }
}
