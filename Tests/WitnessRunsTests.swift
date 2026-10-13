import Foundation
import SwiftData
import Testing
@testable import OriCode

/// Which runs Witness knows the ending of: a call's own exit code, a background command's ending
/// when it comes, a subagent's commands and edits, and the check a project names for itself.
@MainActor
struct WitnessRunsTests {
    private static let root = "/work/repo"
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: Double) -> Date { Self.start.addingTimeInterval(seconds) }

    private func run(_ command: String, at seconds: Double, failed: Bool = false, exit: Int? = nil, background: Bool = false, ended: String? = nil) -> ToolCall {
        ToolCall(
            toolUseId: UUID().uuidString, name: "Bash", input: ["command": .string(command)], result: "ok", isError: failed,
            startedAt: at(seconds), exitCode: exit, background: background, ended: ended)
    }

    private func edit(_ path: String, _ lines: [String] = ["+let x = 1"], at seconds: Double) -> ToolCall {
        ToolCall(
            toolUseId: UUID().uuidString, name: "Edit", input: ["file_path": .string(Self.root + "/" + path)],
            result: "ok", patch: [Hunk(oldStart: 1, newStart: 1, lines: lines)], startedAt: at(seconds))
    }

    private func agent(_ id: String, at seconds: Double, keepsCalls: Bool = true) -> ToolCall {
        ToolCall(toolUseId: id, name: "Agent", input: ["description": "Run the tests"], result: "Done.", startedAt: at(seconds), keepsCalls: keepsCalls)
    }

    private func item(_ call: ToolCall) -> Item { .tool(id: UUID(), call: call) }

    private func user(_ text: String = "Do it") -> Item { .user(id: UUID(), text: text) }

    private func provenance(_ items: [Item], under: [String: [ToolCall]] = [:], exits: Bool = true, own: String? = nil) -> Provenance {
        Provenance(items: items, under: under, exits: exits, own: own) { RepoPath.relative($0, cwd: Self.root, root: Self.root) }
    }

    private func file(_ path: String, changed seconds: Double) -> FileDiff {
        let hunk = DiffHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, context: "", lines: ["-let x = 0", "+let x = 1"])
        return FileDiff(
            path: path, oldPath: nil, status: "M", binary: false, executable: false, hunks: [hunk], added: 1, deleted: 1,
            cut: false, stamp: nil, lossy: false, changedAt: at(seconds).timeIntervalSince1970 * 1000)
    }

    private func page(_ files: [FileDiff], _ provenance: Provenance, committed seconds: Double? = 0) -> WitnessPage {
        let diff = WorkingDiff(root: Self.root, head: "abc", files: files, headAt: seconds.map { at($0).timeIntervalSince1970 * 1000 })
        return WitnessPage(diff: diff, units: ReviewBook(diff: diff, provenance: provenance).units, provenance: provenance)
    }

    // MARK: Exit codes

    @Test func aCallsOwnExitCodeIsItsEndingWhoeverRanIt() {
        // An agent whose word for a failure isn't the command's: only the code it sends is.
        let runs = provenance([
            user(),
            item(run("make test", at: 1, exit: 1)),
            item(run("make test", at: 2, failed: true, exit: 0)),
            item(run("make test", at: 3, failed: true)),
            item(run("make test 2>&1 | tail -5", at: 4, exit: 0)),
        ], exits: false).runs
        // The second's code says 0 and its agent says it failed: which is the command's isn't known.
        #expect(runs.map(\.outcome) == [
            .failed, .unknown("reported as failed with exit code 0"), .unknown("run by an agent that sends no exit code"), .unknown("piped through tail"),
        ])
        #expect(provenance([user(), item(run("make test", at: 1, exit: 0))], exits: false).runs.map(\.outcome) == [.exitedZero])
        // Where the agent's word is the command's own, as Codex's is, it failed by either.
        #expect(provenance([user(), item(run("make test", at: 1, failed: true, exit: 2))]).runs.map(\.outcome) == [.failed])
        #expect(provenance([user(), item(run("make test", at: 1, failed: true, exit: 0))]).runs.map(\.outcome) == [.failed])
        #expect(provenance([user(), item(run("make test", at: 1, exit: 1))]).runs.map(\.outcome) == [.failed])
        #expect(provenance([user(), item(run("make test", at: 1, exit: 0))]).runs.map(\.outcome) == [.exitedZero])
    }

    // MARK: Background commands

    @Test func aBackgroundRunIsNotKnownUntilItsOwnEndingComes() {
        let outcome = { (call: ToolCall) in self.provenance([self.user(), self.item(call)]).runs.map(\.outcome) }
        #expect(outcome(run("make test", at: 1, background: true)) == [.unknown("run in the background")])
        #expect(outcome(run("make test", at: 1, background: true, ended: "completed")) == [.exitedZero])
        #expect(outcome(run("make test", at: 1, background: true, ended: "failed")) == [.failed])
        #expect(outcome(run("make test", at: 1, background: true, ended: "stopped")) == [.unknown("stopped before it ended")])
        // Asked for by the call, with no word from the engine that it went.
        var asked = ToolCall(
            toolUseId: "b", name: "Bash", input: ["command": "make test", "run_in_background": true], result: "Command running in background", startedAt: at(1))
        #expect(outcome(asked) == [.unknown("run in the background")])
        asked.ended = "completed"
        #expect(outcome(asked) == [.exitedZero])
        // Its ending is a pipe's when it was piped, in the background as anywhere.
        #expect(outcome(run("make test | tail -3", at: 1, background: true, ended: "completed")) == [.unknown("piped through tail")])
    }

    // MARK: Subagents

    @Test func aSubagentsCheckIsARunAndItsEditsAreTheTurns() {
        let found = provenance(
            [user("Fix it"), item(edit("a.swift", at: 1)), item(agent("agent-1", at: 5))],
            under: ["agent-1": [run("make test", at: 10, failed: true), edit("b.swift", ["-let y = 0", "+let y = 2"], at: 20)]])
        #expect(found.runs.map(\.check) == ["make test"])
        #expect(found.runs.map(\.startedAt) == [at(10)])
        #expect(found.runs.map(\.outcome) == [.failed])
        #expect(found.lastTurn(editing: "b.swift") == 1)
        #expect(found.turn(of: "+let y = 2", in: "b.swift") == 1)
        #expect(found.turn(of: "-let y = 0", in: "b.swift") == 1)
        #expect(found.firstEdit(of: "b.swift") == 1)
        #expect(found.edits(of: "b.swift", since: nil).count == 1)
        #expect(found.unseenAgents.isEmpty)
        // Legacy's line of checks under a message is the main loop's, as it was.
        #expect(found.checks.isEmpty)

        // a.swift last changed before the subagent's run and b.swift after it.
        let page = page([file("a.swift", changed: 2), file("b.swift", changed: 21)], found)
        #expect(page.sentence == "make test last ran before b.swift last changed. It failed then.")
        #expect(page.runs.map { "Ran \($0.command) · \(WitnessPage.result($0))" } == ["Ran make test · failed"])
        #expect(page.readFirst.map(\.file.path) == ["b.swift"])
        #expect(page.rest.map(\.file.path) == ["a.swift"])
        #expect(page.rest.first?.aside == nil)
    }

    @Test func aSubagentsSubagentIsReadTheSameWay() {
        let found = provenance(
            [user(), item(agent("outer", at: 1))],
            under: ["outer": [agent("inner", at: 2)], "inner": [run("swift build", at: 3), edit("c.swift", at: 4)]])
        #expect(found.runs.map(\.check) == ["swift build"])
        #expect(found.lastTurn(editing: "c.swift") == 1)
        #expect(found.unseenAgents.isEmpty)
    }

    @Test func aRunThatBeganLaterIsTheLastWhereverItsCallStands() {
        // A subagent left in the background runs the tests after the main loop's own run of them.
        let found = provenance(
            [user(), item(agent("agent-1", at: 1)), item(run("make test", at: 30))],
            under: ["agent-1": [run("make test", at: 40, failed: true)]])
        #expect(page([file("a.swift", changed: 35)], found).runs.map(\.startedAt) == [at(40)])
        #expect(page([file("a.swift", changed: 35)], found).runs.map(\.outcome) == [.failed])
    }

    @Test func aSubagentInAWorktreeOfItsOwnCheckedAndEditedACopy() {
        // Its `make test` read a checkout that doesn't hold a.swift's uncommitted edit.
        for isolation in ["worktree", "remote"] {
            let away = ToolCall(
                toolUseId: "agent-1", name: "Agent", input: ["description": "Run the tests", "isolation": .string(isolation)],
                result: "Done.", startedAt: at(5), keepsCalls: true)
            let found = provenance(
                [user(), item(edit("a.swift", at: 1)), item(away)],
                under: ["agent-1": [run("make test", at: 10), edit("b.swift", at: 20), agent("inner", at: 21)], "inner": [run("swift build", at: 22)]])
            #expect(found.runs.isEmpty)
            #expect(found.lastTurn(editing: "b.swift") == nil)
            #expect(found.unseenAgents.isEmpty)
            #expect(page([file("a.swift", changed: 2)], found).sentence == "No build or test OriCode recognises ran in this thread.")
        }
    }

    @Test func runsBetweenAFilesEditsAreCountedByWhenTheyBegan() {
        // A subagent left in the background ran the tests twice while the main loop, whose
        // calls stand after the one that started it, edited the file three times.
        let files = [file("f.swift", changed: 8)]
        let found = provenance(
            [user(), item(agent("agent-1", at: 1)), item(edit("f.swift", at: 4)), item(edit("f.swift", at: 6)), item(edit("f.swift", at: 8)), item(run("make test", at: 9))],
            under: ["agent-1": [run("make test", at: 5), run("make test", at: 7)]])
        #expect(found.edits(of: "f.swift", since: nil) == (3, 2))
        #expect(page(files, found).readFirst.first?.reasons == ["edited 3 times with 2 runs between"])
        // Two subagents at once, the second's edits read after all of the first's runs.
        let two = provenance(
            [user(), item(agent("tests", at: 1)), item(agent("edits", at: 2))],
            under: ["tests": [run("make test", at: 5), run("make test", at: 7)], "edits": [edit("f.swift", at: 4), edit("f.swift", at: 6), edit("f.swift", at: 8)]])
        #expect(two.edits(of: "f.swift", since: nil) == (3, 2))
        // And a run before the first edit or after the last is not between them.
        let outside = provenance(
            [user(), item(agent("agent-1", at: 1)), item(edit("f.swift", at: 4)), item(edit("f.swift", at: 6)), item(edit("f.swift", at: 8))],
            under: ["agent-1": [run("make test", at: 3), run("make test", at: 9)]])
        #expect(outside.edits(of: "f.swift", since: nil) == (3, 0))
        // Without a time it is where the calls stand, as it was.
        var untimed = run("make test", at: 0)
        untimed.startedAt = nil
        let stood = provenance([user(), item(edit("f.swift", at: 4)), item(untimed), item(edit("f.swift", at: 6))])
        #expect(stood.edits(of: "f.swift", since: nil) == (2, 1))
    }

    @Test func aSubagentWhoseCallsWerentKeptIsSaidInTheSentence() {
        // A thread from before a subagent's calls were kept, or an agent that never tells them.
        let old = provenance([user(), item(agent("agent-1", at: 5, keepsCalls: false)), item(run("make test", at: 9))])
        #expect(old.unseenAgents == [at(5)])
        #expect(page([file("a.swift", changed: 2)], old).sentence
            == "make test exited 0 and nothing here has changed since. A subagent worked in this thread and what it ran was not recorded, so a check of its own is not on this page.")
        let alone = provenance([user(), item(agent("agent-1", at: 5, keepsCalls: false))])
        #expect(page([file("a.swift", changed: 2)], alone).sentence
            == "No build or test OriCode recognises ran in this thread. " + WitnessPage.unseenSubagent)
        // One from before the last commit says nothing of what's here.
        #expect(page([file("a.swift", changed: 20)], old, committed: 15).sentence
            == "No build or test OriCode recognises has run in this thread since the last commit.")
        // One whose calls are kept and that called nothing is not unseen.
        let kept = provenance([user(), item(agent("agent-1", at: 5))])
        #expect(page([file("a.swift", changed: 2)], kept).sentence == "No build or test OriCode recognises ran in this thread.")
    }

    // MARK: A project's own check

    @Test func aProjectsOwnCheckIsACheckBesideTheOnesKnown() {
        let found = { (command: String, own: String?) in Provenance.recognise(command, own: own).map(\.check) }
        #expect(found("./ci.sh", nil) == [])
        #expect(found("./ci.sh", "./ci.sh") == ["./ci.sh"])
        #expect(found("ci.sh --fast", "./ci.sh") == ["./ci.sh"])
        #expect(found("bash ci.sh", "./ci.sh") == ["./ci.sh"])
        #expect(found("time env CI=1 ./ci.sh && make test", " ./ci.sh ") == ["./ci.sh", "make test"])
        #expect(found("cat ci.sh", "./ci.sh") == [])
        #expect(found("./ci.sh --help", "./ci.sh") == [])
        #expect(found("lint || ./ci.sh", "./ci.sh") == [])
        // Its words are all of it: a check with an argument isn't the bare script.
        #expect(found("scripts/check.sh --all && echo ok", "scripts/check.sh --all") == ["scripts/check.sh --all"])
        #expect(found("scripts/check.sh", "scripts/check.sh --all") == [])
        #expect(found("make test", "") == ["make test"])
        // A command that asks the check's tool for something else is another command.
        #expect(found("rake test", "rake") == [])
        #expect(found("rake db:migrate", "rake") == [])
        #expect(found("rake --trace > log.txt", "rake") == ["rake"])
        #expect(found("rake 2>&1", "rake") == ["rake"])
        #expect(found("bash ci.sh unit", "./ci.sh") == [])
        #expect(found("rake -v db:migrate", "rake") == [])
        #expect(found("./ci.sh -v > out.txt 2> err.txt", "./ci.sh") == ["./ci.sh"])
        // A quoted argument is its text, on the page as in the match.
        #expect(found("./ci.sh \"unit tests\"", "./ci.sh \"unit tests\"") == ["./ci.sh \"unit tests\""])
        #expect(found("./ci.sh 'unit tests' -v", "./ci.sh \"unit tests\"") == ["./ci.sh \"unit tests\""])
        #expect(found("./ci.sh \"lint\"", "./ci.sh \"unit tests\"") == [])
        // What sets the check up is not its words, typed in the field or in the command.
        #expect(found("./ci.sh", "CI=1 ./ci.sh") == ["CI=1 ./ci.sh"])
        #expect(found("CI=1 ./ci.sh", "CI=1 ./ci.sh") == ["CI=1 ./ci.sh"])
        #expect(found("x", "CI=1") == [])
        // A check of two commands is the two in a row, and its ending the second's.
        let both = "make build && make test"
        #expect(found("make build && make test", both) == [both])
        #expect(found("cd . && make build -j8 && make test && echo ok", both) == [both])
        #expect(found("make build", both) == ["make build"])
        #expect(found("make build; make test", both) == ["make build", "make test"])
        #expect(found("make build && make test:unit", both) == ["make build", "make test:unit"])
        #expect(Provenance.recognise("make build && make test | tail", own: both).map(\.unknown) == ["piped through tail"])
        #expect(Provenance.recognise("make build && make test", own: both).map(\.unknown) == [nil])
        // A check with a pipe of its own ends as the pipe's last command does.
        #expect(Provenance.recognise("make test | xcbeautify", own: "make test | xcbeautify").map(\.unknown) == ["piped through xcbeautify"])
        #expect(Provenance.recognise("./ci.sh 2>&1 | tail -20", own: "./ci.sh").map(\.unknown) == ["piped through tail"])
    }

    @Test func aThreadThatRanTheProjectsCheckNoLongerSaysNoBuildOrTestRan() {
        let items = [user(), item(edit("a.swift", at: 1)), item(run("./ci.sh", at: 5))]
        let files = [file("a.swift", changed: 2)]
        #expect(page(files, provenance(items)).sentence == "No build or test OriCode recognises ran in this thread.")
        let named = page(files, provenance(items, own: "./ci.sh"))
        #expect(named.sentence == "./ci.sh exited 0 and nothing here has changed since.")
        #expect(named.runs.map { "Ran \($0.command) · \(WitnessPage.result($0))" } == ["Ran ./ci.sh · exited 0"])
    }

    // MARK: What the thread keeps

    private func model() throws -> (AppModel, Chat, Project) {
        let container = try TestStore.memory()
        let project = Project(name: "repo", path: Self.root)
        container.mainContext.insert(project)
        let chat = Chat(project: project)
        chat.started = true
        container.mainContext.insert(chat)
        try container.mainContext.save()
        let model = AppModel(container: container)
        model.review.marks = ReviewMarks(file: FileManager.default.temporaryDirectory.appending(path: "oricode-marks-\(UUID().uuidString).json"))
        model.select(chat)
        return (model, chat, project)
    }

    private func tell(_ conversation: Conversation, _ name: String, _ body: [String: JSON]) {
        conversation.receive(EngineEvent(name: name, threadId: conversation.chat.id.uuidString, body: .object(body.merging(["event": .string(name)]) { first, _ in first })))
    }

    @Test func aSubagentsCallsAreKeptUnderItsCallAndTheTranscriptHasNoItemForThem() throws {
        let (model, chat, _) = try model()
        let conversation = model.conversation(for: chat)
        conversation.userSent("Run the tests")
        tell(conversation, "tool.use", ["toolUseId": "agent-1", "name": "Agent", "input": ["description": "Tests"], "subcalls": true])
        let before = conversation.items
        tell(conversation, "tool.use", ["toolUseId": "sub-run", "name": "Bash", "input": ["command": "make test"], "parent": "agent-1"])
        tell(conversation, "tool.result", ["toolUseId": "sub-run", "content": "Exit code 2", "isError": true, "parent": "agent-1"])
        tell(conversation, "tool.use", ["toolUseId": "sub-edit", "name": "Edit", "input": ["file_path": .string(Self.root + "/a.swift")], "parent": "agent-1"])
        tell(conversation, "tool.result", [
            "toolUseId": "sub-edit", "content": "ok", "isError": false, "parent": "agent-1",
            "patch": [["oldStart": 1, "newStart": 1, "lines": ["-let a = 0", "+let a = 1"]]],
        ])
        #expect(conversation.items == before)
        #expect(conversation.under["agent-1"]?.map(\.toolUseId) == ["sub-run", "sub-edit"])
        #expect(conversation.under["agent-1"]?.map(\.isError) == [true, false])
        tell(conversation, "tool.result", ["toolUseId": "agent-1", "content": "One fails.", "isError": false])
        conversation.flush()

        let live = Provenance(items: conversation.items, under: conversation.under) { RepoPath.relative($0, cwd: Self.root, root: Self.root) }
        #expect(live.runs.map(\.outcome) == [.failed])
        #expect(live.lastTurn(editing: "a.swift") == 1)
        #expect(live.unseenAgents.isEmpty)

        // Read back from the store, the same.
        let again = Conversation(chat: chat, context: ModelContext(model.context.container))
        #expect(again.items.count == conversation.items.count)
        #expect(again.under["agent-1"]?.map(\.toolUseId) == ["sub-run", "sub-edit"])
        #expect(again.under["agent-1"]?.first?.result == "Exit code 2")
        #expect(again.under["agent-1"]?.last?.patch?.first?.lines == ["-let a = 0", "+let a = 1"])
        guard case .tool(_, let call) = again.items.last else {
            Issue.record("no call")
            return
        }
        #expect(call.keepsCalls)
    }

    @Test func aCallKeepsItsExitCodeAndABackgroundCommandsEnding() throws {
        let (model, chat, _) = try model()
        let conversation = model.conversation(for: chat)
        conversation.userSent("Run the tests")
        tell(conversation, "tool.use", ["toolUseId": "c1", "name": "shell", "kind": "run", "input": [:], "view": ["command": "make test"]])
        tell(conversation, "tool.result", ["toolUseId": "c1", "content": "1 failed", "isError": false, "exitCode": 1])
        tell(conversation, "tool.use", ["toolUseId": "b1", "name": "Bash", "input": ["command": "swift build"]])
        tell(conversation, "tool.result", ["toolUseId": "b1", "content": "Command running in background with ID: b1.", "isError": false, "background": true])
        let calls = { (conversation: Conversation) in
            conversation.items.compactMap { item -> ToolCall? in if case .tool(_, let call) = item { call } else { nil } }
        }
        #expect(calls(conversation).map(\.exitCode) == [1, nil])
        #expect(calls(conversation).map(\.background) == [false, true])
        let runs = { (conversation: Conversation) in Provenance(items: conversation.items, exits: false) { $0 }.runs.map(\.outcome) }
        #expect(runs(conversation) == [.failed, .unknown("run in the background")])
        tell(conversation, "tool.ended", ["toolUseId": "b1", "status": "completed"])
        #expect(calls(conversation).map(\.ended) == [nil, "completed"])
        #expect(runs(conversation) == [.failed, .exitedZero])
        conversation.flush()
        let again = Conversation(chat: chat, context: ModelContext(model.context.container))
        #expect(calls(again).map(\.exitCode) == [1, nil])
        #expect(calls(again).map(\.ended) == [nil, "completed"])
        #expect(runs(again) == [.failed, .exitedZero])
    }

    /// A diff whose commit and whose file's change are that many seconds from now, a live
    /// call's start being the moment it was told.
    private func reply(_ path: String, changed: Double) -> JSON {
        let at = { (seconds: Double) in Date.now.addingTimeInterval(seconds) }
        let hunk: JSON = ["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1, "context": "", "lines": ["-let a = 0", "+let a = 1"]]
        let file: JSON = [
            "path": .string(path), "oldPath": nil, "status": "M", "binary": false, "executable": false, "hunks": [hunk],
            "added": 1, "deleted": 1, "cut": false, "stamp": nil, "lossy": false, "changedAt": .number(at(changed).timeIntervalSince1970 * 1000),
        ]
        return ["root": .string(Self.root), "head": "abc", "headAt": .number(at(-100).timeIntervalSince1970 * 1000), "mark": "one", "files": [file]]
    }

    @Test func theProjectsCheckAndABackgroundEndingBuildThePageAgainThoughNoFileMoved() async throws {
        let (model, chat, project) = try model()
        let conversation = model.conversation(for: chat)
        conversation.userSent("Do it")
        tell(conversation, "tool.use", ["toolUseId": "c1", "name": "Bash", "input": ["command": "./ci.sh", "run_in_background": true]])
        // A result in the same instant as its call reads as one out of a transcript, with no start.
        try await Task.sleep(for: .milliseconds(10))
        tell(conversation, "tool.result", ["toolUseId": "c1", "content": "Command running in background with ID: c1.", "isError": false, "background": true])
        let review = model.review
        review.design = .witness
        review.look(at: Self.root, for: chat.id)
        try await model.take(reply("a.swift", changed: -50), in: Self.root)
        #expect(review.page.sentence == "No build or test OriCode recognises ran in this thread.")

        // The check is named in Settings: git has nothing new to say, and the page has.
        let same: JSON = ["root": .string(Self.root), "same": true]
        model.setCheck("  ./ci.sh ", for: project)
        #expect(project.check == "./ci.sh")
        try await model.take(same, in: Self.root)
        #expect(review.page.runs.map(WitnessPage.result) == ["result not known, run in the background"])

        // Its own ending comes.
        tell(conversation, "tool.ended", ["toolUseId": "c1", "status": "failed"])
        try await model.take(same, in: Self.root)
        #expect(review.page.runs.map(WitnessPage.result) == ["failed"])
        #expect(review.page.sentence == "./ci.sh failed and nothing here has changed since.")

        // Nothing typed is no check.
        model.setCheck("   ", for: project)
        #expect(project.check == nil)
        try await model.take(same, in: Self.root)
        #expect(review.page.runs.isEmpty)
    }
}
