import Foundation
import SwiftData
import Testing
@testable import OriCode

/// What the thread says of a change in Witness: the caption for the one the keyboard is on, the
/// edit T shows, the end of a run's output behind →, and the line A leaves in a note.
@MainActor
struct WitnessThreadTests {
    private static let root = "/work/repo"
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: Double) -> Date { Self.start.addingTimeInterval(seconds) }

    private func edit(_ path: String, _ lines: [String], at seconds: Double, id: UUID = UUID()) -> Item {
        .tool(id: id, call: ToolCall(
            toolUseId: UUID().uuidString, name: "Edit", input: ["file_path": .string(Self.root + "/" + path)],
            result: "ok", patch: [Hunk(oldStart: 1, newStart: 1, lines: lines)], startedAt: at(seconds)))
    }

    private func ran(_ command: String, at seconds: Double, result: String = "ok", id: String = UUID().uuidString) -> Item {
        .tool(id: UUID(), call: ToolCall(toolUseId: id, name: "Bash", input: ["command": .string(command)], result: result, startedAt: at(seconds)))
    }

    private func user(_ text: String = "Do it") -> Item { .user(id: UUID(), text: text) }

    private func said(_ text: String) -> Item { .text(id: UUID(), text: text) }

    private func file(_ path: String, _ hunks: [[String]], changed seconds: Double) -> FileDiff {
        let hunks = hunks.enumerated().map { index, lines in
            DiffHunk(
                oldStart: 1 + index * 100, oldLines: lines.count { !$0.hasPrefix("+") }, newStart: 1 + index * 100,
                newLines: lines.count { !$0.hasPrefix("-") }, context: "", lines: lines)
        }
        return FileDiff(
            path: path, oldPath: nil, status: "M", binary: false, executable: false, hunks: hunks,
            added: 1, deleted: 1, cut: false, stamp: nil, lossy: false, changedAt: at(seconds).timeIntervalSince1970 * 1000)
    }

    private func provenance(_ items: [Item], under: [String: [ToolCall]] = [:], rays: [RayEdit] = []) -> Provenance {
        Provenance(items: items, under: under, rayEdits: rays) { RepoPath.relative($0, cwd: Self.root, root: Self.root) }
    }

    private func page(_ files: [FileDiff], _ provenance: Provenance) -> (page: WitnessPage, units: [ReviewUnit]) {
        let diff = WorkingDiff(root: Self.root, head: "abc", files: files, headAt: at(0).timeIntervalSince1970 * 1000)
        let units = ReviewBook(diff: diff, provenance: provenance).units
        return (WitnessPage(diff: diff, units: units, provenance: provenance), units)
    }

    // MARK: The caption

    @Test func aFileEditedRunAndEditedAgainSaysSoInWords() {
        let first = UUID(), second = UUID()
        let items = [
            user("Fix the drawer so it closes when the pair is beside it, and keep the tests"),
            said("The flag is read too early.\n\nI'll move it."),
            edit("a.swift", ["-let a = 0", "+let a = 1"], at: 1, id: first),
            ran("make test 2>&1 | tail -20", at: 2),
            said("## One test **still** fails, so the guard goes too."),
            ran("ls", at: 3),
            edit("a.swift", ["-guard ready else { return }", "+go()"], at: 4, id: second),
        ]
        let (page, units) = page([file("a.swift", [["-let a = 0", "+let a = 1"], ["-guard ready else { return }", "+go()"]], changed: 4)], provenance(items))
        let accounts = units.compactMap { page.accounts[$0.id] }
        #expect(accounts.map(\.number) == [1, 2])
        #expect(accounts.map(\.edits) == ["edited 2 times with a run of make test between", "edited 2 times with a run of make test between"])
        // Each change is shown by the edit that wrote it, with what was said before that one.
        #expect(accounts.map(\.edit) == [first, second])
        #expect(accounts.map(\.said) == ["The flag is read too early.", "One test still fails, so the guard goes too."])
        #expect(WitnessCaption.words(accounts[1], of: page.total, worker: nil)
            == "Change 2 of 2 · asked by “Fix the drawer so it closes when the pair is…” · its file was edited 2 times with a run of make test between")
    }

    @Test func theEditsAndRunsBetweenAreToldByCountAndName() {
        let run = { (check: String) in Provenance.Run(check: check, command: check, startedAt: nil, outcome: .exitedZero) }
        #expect(WitnessPage.edits((0, [])) == nil)
        #expect(WitnessPage.edits((1, [])) == "edited once")
        #expect(WitnessPage.edits((2, [])) == "edited 2 times with no run between")
        #expect(WitnessPage.edits((3, [run("make test"), run("make test")])) == "edited 3 times with 2 runs of make test between")
        #expect(WitnessPage.edits((4, [run("make test"), run("tsc"), run("make test")])) == "edited 4 times with 3 runs between, of make test and tsc")
    }

    @Test func whatWasSaidInAnEarlierTurnIsNotThisEdits() {
        let items = [
            user("First"), said("All done."),
            user("Second"), edit("a.swift", ["-let a = 0", "+let a = 1"], at: 1),
        ]
        let (page, units) = page([file("a.swift", [["-let a = 0", "+let a = 1"]], changed: 1)], provenance(items))
        let account = page.accounts[units[0].id]
        #expect(account?.said == nil)
        #expect(account?.asked == "Second")
        #expect(account?.edit != nil)
    }

    @Test func aLineALaterEditWroteAgainDoesNotMoveTheChangeToThatEdit() {
        let first = UUID(), second = UUID()
        let early = ["+func early() -> Int? {", "+    guard ready else { return nil }", "+    return nil", "+}"]
        let late = ["+func late() -> Int? {", "+    return nil", "+}"]
        let items = [
            user("Add the early one"), said("Early first."), edit("a.swift", early, at: 1, id: first),
            user("Now the late one"), said("Now the late one."), edit("a.swift", late, at: 2, id: second),
        ]
        let (page, units) = page([file("a.swift", [early, late], changed: 2)], provenance(items))
        let accounts = units.compactMap { page.accounts[$0.id] }
        #expect(accounts.map(\.edit) == [first, second])
        #expect(accounts.map(\.said) == ["Early first.", "Now the late one."])
        #expect(accounts.map(\.asked) == ["Add the early one", "Now the late one"])
    }

    @Test func ofTwoEditsThatWroteAsMuchOfAChangeItIsTheLater() {
        let second = UUID()
        let items = [
            user(), said("One."), edit("a.swift", ["+let a = 1"], at: 1),
            said("Two."), edit("a.swift", ["+let b = 2"], at: 2, id: second),
        ]
        let (page, units) = page([file("a.swift", [["+let a = 1", "+let b = 2"]], changed: 2)], provenance(items))
        #expect(page.accounts[units[0].id]?.edit == second)
    }

    @Test func aChangeNoEditMadeHasNoEditToShowAndNothingSaid() {
        // The thread edited the file, and a sed changed another line of it afterwards.
        let items = [user(), said("Renaming it."), edit("a.swift", ["-let a = 0", "+let a = 1"], at: 1), ran("sed -i '' s/held/grasped/ a.swift", at: 2)]
        let (page, units) = page([file("a.swift", [["-let a = 0", "+let a = 1"], ["-let held = 1", "+let grasped = 1"]], changed: 2)], provenance(items))
        let accounts = units.compactMap { page.accounts[$0.id] }
        #expect(accounts[0].edit != nil && accounts[0].said == "Renaming it.")
        #expect(accounts[1].asked == nil && accounts[1].edit == nil && accounts[1].said == nil)
        #expect(WitnessCaption.words(accounts[1], of: 2, worker: nil) == "Change 2 of 2 · no edit in this thread made it · its file was edited once")
    }

    @Test func aSubagentsEditIsShownByTheCallThatStartedIt() {
        let agent = UUID()
        let child = ToolCall(
            toolUseId: "sub-edit", name: "Edit", input: ["file_path": .string(Self.root + "/a.swift")],
            result: "ok", patch: [Hunk(oldStart: 1, newStart: 1, lines: ["-let a = 0", "+let a = 1"])], startedAt: at(2))
        let items = [
            user(), said("A subagent can take this."),
            Item.tool(id: agent, call: ToolCall(toolUseId: "agent-1", name: "Agent", input: ["description": "Edit it"], result: "Done.", startedAt: at(1), keepsCalls: true)),
        ]
        let (page, units) = page([file("a.swift", [["-let a = 0", "+let a = 1"]], changed: 2)], provenance(items, under: ["agent-1": [child]]))
        #expect(page.accounts[units[0].id]?.edit == agent)
        #expect(page.accounts[units[0].id]?.said == "A subagent can take this.")
    }

    @Test func aWorkersChangeNamesTheWorkerAndHasNoItem() {
        let ray = Provenance.Ray(agent: "codex", label: "the tests")
        let rays = [RayEdit(turn: 1, ray: ray, files: [RayEdit.File(path: Self.root + "/a.swift", hunks: [Hunk(oldStart: 1, newStart: 1, lines: ["-let a = 0", "+let a = 1"])])])]
        let (page, units) = page([file("a.swift", [["-let a = 0", "+let a = 1"]], changed: 1)], provenance([user("Send a worker")], rays: rays))
        let account = page.accounts[units[0].id]
        #expect(account?.ray == ray && account?.edit == nil)
        #expect(WitnessCaption.words(account!, of: 1, worker: "Codex") == "Change 1 of 1 · asked by “Send a worker” · Codex's worker, the tests")
    }

    @Test func theAgentsSentenceIsItsFirstLineWithWordsWithoutTheMarks() {
        #expect(Provenance.sentence(of: "\n\n---\n- **Now** the footer.\nAnd more.") == "Now the footer.")
        #expect(Provenance.sentence(of: "   \n") == nil)
        #expect(Provenance.sentence(of: String(repeating: "word ", count: 80))?.count == 240)
    }

    @Test func legacysTurnsAreWhatTheyWereWithAnEditsItemKept() {
        let items = [user("One"), edit("a.swift", ["+let a = 1"], at: 1), user("Two"), edit("a.swift", ["+let b = 2"], at: 2)]
        let provenance = provenance(items)
        #expect(provenance.turn(of: "+let a = 1", in: "a.swift") == 1)
        #expect(provenance.turn(of: "+let b = 2", in: "a.swift") == 2)
        #expect(provenance.turn(of: "+let c = 3", in: "a.swift") == nil)
        #expect(provenance.lastTurn(editing: "a.swift") == 2)
        #expect(provenance.edits(of: "a.swift", since: nil) == (2, 0))
    }

    // MARK: A run's row

    @Test func theEndOfWhatARunPrintedIsItsLastTwelveLinesAsTheyAre() {
        let printed = (1...40).map { "line \($0)" }.joined(separator: "\n") + "\n\n  \n"
        let tail = WitnessPage.tail(of: printed)
        #expect(tail.lines == (29...40).map { "line \($0)" })
        #expect(tail.of == 40)
        #expect(WitnessPage.tail(of: "  FAILED\n\n1 test, 1 failure").lines == ["  FAILED", "", "1 test, 1 failure"])
        #expect(WitnessPage.tail(of: "").lines.isEmpty)
    }

    @Test func theKeyboardWalksOntoARunsRowWhereItStandsOnThePage() {
        let items = [user(), edit("a.swift", ["-let a = 0", "+let a = 1"], at: 1), ran("make test", at: 2), ran("sed -i '' s/b/c/ b.swift", at: 3)]
        let files = [file("a.swift", [["-let a = 0", "+let a = 1"]], changed: 1), file("b.swift", [["-let b = 0", "+let c = 0"]], changed: 3)]
        let (page, units) = page(files, provenance(items))
        let a = units.first { $0.file.path == "a.swift" }!.id, b = units.first { $0.file.path == "b.swift" }!.id
        #expect(page.walk == [b, "r:make test", a])
        #expect(page.order == [b, a])
        #expect(page.run("r:make test")?.command == "make test")
        #expect(page.run(a) == nil)
        // With nothing under the runs they come first, as the page has them.
        let (all, _) = self.page([files[1]], provenance(items))
        #expect(all.walk == ["r:make test", b])
    }

    // MARK: Asking for the check again

    @Test func theNoteAsksForTheCheckTheFileChangedAfterUnpiped() {
        let items = [
            user(), ran("make test 2>&1 | tail -20", at: 1), ran("tsc --noEmit; echo done", at: 2),
            ran("sed -i '' s/a/b/ a.swift b.swift c.swift d.swift", at: 3),
        ]
        let change = [["-let a = 0", "+let b = 0"]]
        let one = page([file("a.swift", change, changed: 3)], provenance(items)).page
        #expect(one.askAgain(for: "a.swift") == "Run make test again, unpiped: a.swift changed after it last ran.")
        // On tsc's own row it is tsc that's asked for, and what followed it is named.
        #expect(one.askAgain(for: "a.swift", on: one.run("r:tsc")) == "Run tsc again, unpiped and with nothing after it: a.swift changed after it last ran.")
        let two = page(["a.swift", "b.swift"].map { file($0, change, changed: 3) }, provenance(items)).page
        #expect(two.askAgain(for: "b.swift") == "Run make test again, unpiped: a.swift and b.swift changed after it last ran.")
        let four = page(["a.swift", "b.swift", "c.swift", "d.swift"].map { file($0, change, changed: 3) }, provenance(items)).page
        #expect(four.askAgain(for: "a.swift") == "Run make test again, unpiped: a.swift, b.swift and 2 more files changed after it last ran.")
    }

    @Test func withNothingChangedSinceTheNoteAsksForTheRunWhoseResultIsNotKnown() {
        let change = [["-let a = 0", "+let b = 0"]]
        let piped = page([file("a.swift", change, changed: 1)], provenance([user(), ran("make test | tail -5", at: 2)])).page
        #expect(piped.askAgain(for: "a.swift") == "Run make test again, unpiped: its result is not known.")
        let known = page([file("a.swift", change, changed: 1)], provenance([user(), ran("make test", at: 2)])).page
        #expect(known.askAgain(for: "a.swift") == "Run make test again, unpiped.")
        let none = page([file("a.swift", change, changed: 1)], provenance([user()])).page
        #expect(none.askAgain(for: "a.swift") == nil)
    }

    // MARK: The shared state

    private func model() throws -> (AppModel, Chat) {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "repo", path: Self.root)
        container.mainContext.insert(project)
        let chat = Chat(project: project)
        chat.started = true
        container.mainContext.insert(chat)
        try container.mainContext.save()
        let model = AppModel(container: container)
        model.review.marks = ReviewMarks(file: FileManager.default.temporaryDirectory.appending(path: "oricode-marks-\(UUID().uuidString).json"))
        model.select(chat)
        return (model, chat)
    }

    private func tell(_ conversation: Conversation, _ name: String, _ body: [String: JSON]) {
        conversation.receive(EngineEvent(name: name, threadId: conversation.chat.id.uuidString, body: .object(body.merging(["event": .string(name)]) { first, _ in first })))
    }

    private func reply(_ files: [(path: String, lines: [String], changed: Double)]) -> JSON {
        let at = { (seconds: Double) in Date.now.addingTimeInterval(seconds) }
        let files = files.map { file -> JSON in
            let hunk: JSON = ["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1, "context": "", "lines": .array(file.lines.map(JSON.string))]
            return [
                "path": .string(file.path), "oldPath": nil, "status": "M", "binary": false, "executable": false, "hunks": [hunk],
                "added": 1, "deleted": 1, "cut": false, "stamp": nil, "lossy": false, "changedAt": .number(at(file.changed).timeIntervalSince1970 * 1000),
            ]
        }
        return ["root": .string(Self.root), "head": "abc", "headAt": .number(at(-100).timeIntervalSince1970 * 1000), "mark": "one", "files": .array(files)]
    }

    /// A thread that edited a.swift, ran the tests piped, and edited it again; b.swift is older than the run.
    private func thread() async throws -> (AppModel, Conversation) {
        let (model, chat) = try model()
        let conversation = model.conversation(for: chat)
        conversation.userSent("Make a one")
        tell(conversation, "tool.use", ["toolUseId": "e1", "name": "Edit", "input": ["file_path": .string(Self.root + "/a.swift")]])
        tell(conversation, "tool.result", ["toolUseId": "e1", "content": "ok", "isError": false, "patch": [["oldStart": 1, "newStart": 1, "lines": ["-let a = 0", "+let a = 2"]]]])
        tell(conversation, "tool.use", ["toolUseId": "t1", "name": "Bash", "input": ["command": "make test 2>&1 | tail -3"]])
        // A result in the same instant as its call reads as one out of a transcript, with no start.
        try await Task.sleep(for: .milliseconds(10))
        tell(conversation, "tool.result", ["toolUseId": "t1", "content": .string((1...20).map { "test \($0) ok" }.joined(separator: "\n")), "isError": false])
        tell(conversation, "text", ["delta": "Two was wrong, it is one."])
        tell(conversation, "tool.use", ["toolUseId": "e2", "name": "Edit", "input": ["file_path": .string(Self.root + "/a.swift")]])
        tell(conversation, "tool.result", ["toolUseId": "e2", "content": "ok", "isError": false, "patch": [["oldStart": 1, "newStart": 1, "lines": ["-let a = 2", "+let a = 1"]]]])
        conversation.flush()
        let review = model.review
        review.design = .witness
        review.look(at: Self.root, for: chat.id)
        try await model.take(reply([("a.swift", ["-let a = 0", "+let a = 1"], 5), ("b.swift", ["-let b = 0", "+let b = 1"], -50)]), in: Self.root)
        return (model, conversation)
    }

    private func item(_ conversation: Conversation, _ toolUseId: String) -> UUID? {
        conversation.items.first { if case .tool(_, let call) = $0 { call.toolUseId == toolUseId } else { false } }?.id
    }

    @Test func tClosesTheReviewOnTheEditAndTheReviewOpenedAgainIsOnTheSameChange() async throws {
        let (model, conversation) = try await thread()
        let review = model.review
        #expect(review.page.walk.count == 3)
        model.reviewShown = true
        review.move(1)
        let change = try #require(review.selectedUnit)
        #expect(change.file.path == "a.swift")
        let account = try #require(review.page.accounts[change.id])
        #expect(account.edits == "edited 2 times with a run of make test between")
        #expect(account.said == "Two was wrong, it is one.")
        #expect(account.edit == item(conversation, "e2"))

        model.showInThread()
        #expect(!model.reviewShown)
        #expect(model.reveal == item(conversation, "e2"))
        #expect(review.selected == change.id)

        // On the run's row it is the command that's shown, and on a change no edit made, nothing.
        model.reviewShown = true
        model.reveal = nil
        review.move(1)
        #expect(review.selected == "r:make test")
        model.showInThread()
        #expect(model.reveal == item(conversation, "t1"))
        model.reviewShown = true
        model.reveal = nil
        review.move(1)
        #expect(review.selectedUnit?.file.path == "b.swift")
        model.showInThread()
        #expect(model.reveal == nil && model.reviewShown)
    }

    @Test func rightOnTheRunsRowOpensItAndEscClosesItBeforeTheReview() async throws {
        let (model, _) = try await thread()
        let review = model.review
        review.move(1)
        review.move(1)
        #expect(review.selected == "r:make test" && review.selectedUnit == nil)
        let run = try #require(review.page.run(review.selected))
        #expect(WitnessPage.tail(of: model.printed(by: run) ?? "").lines == (9...20).map { "test \($0) ok" })

        review.open(true)
        #expect(review.unfolded.contains("r:make test"))
        // Space, and a read that finds the row still there, leave the keyboard on it and mark nothing.
        model.toggleSelectedReviewed()
        model.applyMarks()
        #expect(review.selected == "r:make test" && review.book.toReview == 2)
        #expect(review.closeOpened())
        #expect(!review.unfolded.contains("r:make test"))
        #expect(!review.closeOpened())

        // Tab from the row goes to the change under it, ⇧Tab to the one over it.
        #expect(review.walkFile(1))
        #expect(review.selectedUnit?.file.path == "b.swift")
        review.move(-1)
        #expect(review.walkFile(-1))
        #expect(review.selectedUnit?.file.path == "a.swift")
    }

    @Test func aLeavesAnEditableLineInTheNoteAndNothingIsSentUntilSend() async throws {
        let (model, conversation) = try await thread()
        let review = model.review
        let sent = conversation.items.count
        review.move(1)
        let change = try #require(review.selectedUnit)
        model.askAgain()
        #expect(review.noting == change.id)
        #expect(review.noteStart == "Run make test again, unpiped: a.swift changed after it last ran.")
        #expect(review.notes.isEmpty && conversation.items.count == sent)

        // The field takes the line, and what's kept is what was typed over it.
        review.noteStart = ""
        model.addNote(on: change, text: "Run make test again, unpiped, and say what failed.")
        #expect(model.ownNotes.map(\.text) == ["Run make test again, unpiped, and say what failed."])
        #expect(conversation.items.count == sent)

        // From the run's row the note is on the first change that changed after the run.
        review.move(1)
        #expect(review.selected == "r:make test")
        model.askAgain()
        #expect(review.noting == change.id && review.selected == change.id)
    }

    @Test func theKeysAreInTheShortcutsOfWitnessAndNotOfLegacy() {
        let keys = { (design: ReviewDesign) in
            (ShortcutList.groups(review: design).last?.rows ?? []).map { row in if case .fixed(_, let keys) = row { keys } else { "" } }
        }
        #expect(keys(.witness).contains("T") && keys(.witness).contains("A"))
        #expect(!keys(.legacy).contains("T") && !keys(.legacy).contains("A"))
    }
}
