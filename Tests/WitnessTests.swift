import Foundation
import SwiftData
import Testing
@testable import OriCode

/// Witness's clock and its reasons, on diffs and threads made here: no git, no engine, no model.
@MainActor
struct WitnessTests {
    private static let root = "/work/repo"
    /// The moment everything here is told from, in seconds.
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: Double) -> Date { Self.start.addingTimeInterval(seconds) }

    private func edit(_ path: String, _ lines: [String] = ["+let x = 1"], at seconds: Double) -> Item {
        .tool(id: UUID(), call: ToolCall(
            toolUseId: UUID().uuidString, name: "Edit", input: ["file_path": .string(Self.root + "/" + path)],
            result: "ok", patch: [Hunk(oldStart: 1, newStart: 1, lines: lines)], startedAt: at(seconds)))
    }

    private func ran(_ command: String, at seconds: Double, failed: Bool = false, result: String = "ok", background: Bool = false) -> Item {
        var input: [String: JSON] = ["command": .string(command)]
        if background { input["run_in_background"] = true }
        return .tool(id: UUID(), call: ToolCall(
            toolUseId: UUID().uuidString, name: "Bash", input: .object(input), result: result, isError: failed, startedAt: at(seconds)))
    }

    private func prompt(_ command: String, at seconds: Double, exit: Int32? = 0) -> Item {
        var run = ShellRun(command: command, folder: Self.root, startedAt: at(seconds))
        run.endedAt = at(seconds + 5)
        run.exitCode = exit
        return .shell(id: UUID(), run: run)
    }

    private func user(_ text: String = "Do it") -> Item { .user(id: UUID(), text: text) }

    private func file(_ path: String, status: String = "M", oldPath: String? = nil, _ hunks: [DiffHunk]? = nil, changed seconds: Double?) -> FileDiff {
        let hunks = hunks ?? [hunk(["-let x = 0", "+let x = 1"])]
        return FileDiff(
            path: path, oldPath: oldPath, status: status, binary: false, executable: false, hunks: hunks,
            added: hunks.flatMap(\.lines).count { $0.hasPrefix("+") }, deleted: hunks.flatMap(\.lines).count { $0.hasPrefix("-") },
            cut: false, stamp: nil, lossy: false, changedAt: seconds.map { at($0).timeIntervalSince1970 * 1000 })
    }

    private func hunk(_ lines: [String], at start: Int = 1) -> DiffHunk {
        let old = lines.count { !$0.hasPrefix("+") }, new = lines.count { !$0.hasPrefix("-") }
        return DiffHunk(oldStart: start, oldLines: old, newStart: start, newLines: new, context: "", lines: lines)
    }

    private func page(_ files: [FileDiff], _ items: [Item], committed seconds: Double? = nil, exits: Bool = true) -> WitnessPage {
        let diff = WorkingDiff(root: Self.root, head: "abc", files: files, headAt: seconds.map { at($0).timeIntervalSince1970 * 1000 })
        let provenance = Provenance(items: items, exits: exits) { RepoPath.relative($0, cwd: Self.root, root: Self.root) }
        return WitnessPage(diff: diff, units: ReviewBook(diff: diff, provenance: provenance).units, provenance: provenance)
    }

    /// Every word the page says, to hold against the words it must never say.
    private func said(_ page: WitnessPage) -> String {
        ([page.sentence, page.below ?? ""] + page.runs.map { "Ran \($0.command) · \(WitnessPage.result($0))" }
            + (page.readFirst + page.rest).flatMap { $0.reasons + [$0.aside ?? ""] } + page.quiet.map(\.what)).joined(separator: "\n")
    }

    // MARK: Recognising a check

    @Test func aCheckIsFoundBehindWhatStandsInFrontOfIt() {
        let found = { (command: String) in Provenance.recognise(command).map(\.check) }
        #expect(found("make test") == ["make test"])
        #expect(found("time make test") == ["make test"])
        #expect(found("env CI=1 npm test") == ["npm test"])
        #expect(found("timeout 600 swift test") == ["swift test"])
        #expect(found("nice -n 10 xcrun swift build") == ["swift build"])
        #expect(found("caffeinate -i make test") == ["make test"])
        #expect(found("(cd engine && npm test)") == ["npm test"])
        #expect(found("PATH=/opt/homebrew/bin:$PATH ./node_modules/.bin/tsc --noEmit") == ["tsc"])
        #expect(found("make test 2>&1 | tail -40") == ["make test"])
        #expect(found("make test > /tmp/out.log 2>&1") == ["make test"])
        #expect(found("tsc && make test") == ["tsc", "make test"])
        #expect(found("grep -r \"make test | tail\" docs") == [])
        // A check is named by its tool and what was asked of it, so a run with other flags, another
        // folder for its build or one test picked out keeps the same clock.
        #expect(found("xcodebuild -project OriCode.xcodeproj -scheme OriCode -derivedDataPath \"$W/dd\" -quiet test -only-testing:OriCodeTests/ReviewTests") == ["xcodebuild test"])
        #expect(found("make -C app test BUILD=$B") == ["make -C app test"])
        #expect(found("node --test test/child.test.ts") == ["node --test"])
        #expect(found("npm run test:unit -- --watch=false") == ["npm run test:unit"])
        // xcodebuild asked a question builds nothing, and words in a string or fed to a command
        // from a here-document are text, not commands.
        #expect(found("xcodebuild -version") == [])
        #expect(found("python3 card.py K-1 \"Run make test again\" 'swift test passes'") == [])
        #expect(found("python3 - <<'EOF'\nprint('tsc is next')\nmake test\nEOF\nswift build") == ["swift build"])
        #expect(found("cat > notes.txt <<EOF\nswift test\nEOF") == [])
        #expect(found("time ls") == [])
        #expect(found("cat test.txt") == [])
    }

    @Test func aRunsEndingIsItsOwnOnlyWithNothingAfterItButAnd() {
        let why = { (command: String) in Provenance.recognise(command).first?.unknown }
        #expect(why("make test") == nil)
        #expect(why("cd engine && make test") == nil)
        #expect(why("make test && echo done") == nil)
        #expect(why("make test 2>&1") == nil)
        #expect(why("make test 2>&1 | tail -20") == "piped through tail")
        #expect(why("make test |& tee out.log") == "piped through tee")
        #expect(why("make test; echo $?") == "followed by another command")
        #expect(why("make test\ngit status") == "followed by another command")
        #expect(why("make test || true") == "followed by ||")
        #expect(why("make test &") == "run in the background")
        #expect(why("make test && ls | head") == "followed by a command whose ending is the one reported")
        // A line that only ends in a newline or a semicolon has nothing after it.
        #expect(why("make test;\n") == nil)
    }

    @Test func aCheckAskedNothingOrOnlyRunWhenAnotherFailedIsNoRun() {
        let found = { (command: String) in Provenance.recognise(command).map(\.check) }
        // Its version, its help or a rehearsal: nothing of the code ran.
        for command in ["tsc --version", "tsc -v", "pytest --collect-only -q", "make -n test", "npm test -- --help", "swift build --help", "eslint -h", "xcodebuild test -dry-run", "jest --listTests"] {
            #expect(found(command) == [], "\(command)")
        }
        #expect(found("pytest -v") == ["pytest"])
        // After ||, a check runs only when what stood before it failed.
        #expect(found("make build || make test") == ["make build"])
        #expect(Provenance.recognise("make build || make test").first?.unknown == "followed by ||")
        // A comment is no command, and its apostrophe opens no string that could swallow the next line.
        #expect(Provenance.recognise("make test # don't pipe this\necho $?") == [Provenance.Recognised(check: "make test", unknown: "followed by another command")])
        #expect(found("# make test\nls") == [])
        #expect(Provenance.recognise("echo a#b && make test").map(\.unknown) == [nil])
        // A here-string feeds a word, so the lines after it are still commands.
        #expect(Provenance.recognise("make test <<< \"y\"\necho done") == [Provenance.Recognised(check: "make test", unknown: "followed by another command")])
    }

    @Test func aCheckRunInAnotherFolderIsNotThisThreadsCheck() {
        let inside = { (folder: String) in RepoPath.relative((folder as NSString).appendingPathComponent("x"), cwd: Self.root + "/engine", root: Self.root) != nil }
        let found = { (command: String) in Provenance.recognise(command, inside: inside).map(\.check) }
        #expect(found("make test") == ["make test"])
        #expect(found("cd .. && make test") == ["make test"])
        #expect(found("cd \"\(Self.root)/App\" && swift build") == ["swift build"])
        #expect(found("cd ~/Developer/Other && make test") == [])
        #expect(found("cd ../../.worktrees/t-1a2b3c && make test") == [])
        #expect(found("cd /tmp; make test") == [])
        #expect(found("pushd /tmp && make test") == [])
        #expect(found("make -C /tmp/other test") == [])
        #expect(found("make -C .. test") == ["make -C .. test"])
        // Where only the shell could say, it isn't read as here.
        #expect(found("cd \"$WORK\" && make test") == [])
        #expect(found("make test && cd /tmp && tsc") == ["make test"])
        // A command of yours typed in another folder is that folder's.
        var elsewhere = ShellRun(command: "make test", folder: "/work/other", startedAt: at(1))
        elsewhere.endedAt = at(2)
        elsewhere.exitCode = 0
        let runs = Provenance(items: [user(), .shell(id: UUID(), run: elsewhere), prompt("make test", at: 3), ran("cd /work/other && tsc", at: 4)]) {
            RepoPath.relative($0, cwd: Self.root, root: Self.root)
        }.runs
        #expect(runs.map(\.startedAt) == [at(3)])
    }

    @Test func aRunSaysExitedZeroFailedOrNotKnown() {
        let runs = Provenance(items: [
            user(),
            ran("make test", at: 1),
            ran("make test", at: 2, failed: true, result: "1 failed"),
            ran("make test 2>&1 | tail -20", at: 3),
            ran("make test", at: 4, background: true),
            ran("make test", at: 5, failed: true, result: ""),
            prompt("make test", at: 6),
            prompt("swift build", at: 7, exit: 65),
            prompt("make test | tail", at: 8),
            prompt("make test", at: 9, exit: nil),
            ran("ls", at: 10),
        ]) { $0 }.runs
        #expect(runs.map(\.outcome) == [
            .exitedZero, .failed, .unknown("piped through tail"), .unknown("run in the background"), .unknown("cut off before it ended"),
            .exitedZero, .failed, .unknown("piped through tail"), .unknown("ended with no exit code"),
        ])
        #expect(runs.map(\.startedAt) == (1...9).map { at(Double($0)) })
        // An agent that sends no exit code never has a result, piped or not.
        let silent = Provenance(items: [user(), ran("make test", at: 1), ran("make test", at: 2, failed: true, result: "no")], exits: false) { $0 }.runs
        #expect(silent.map(\.outcome) == [.unknown("run by an agent that sends no exit code"), .unknown("run by an agent that sends no exit code")])
    }

    @Test func aRunStillRunningOrNeverAnsweredIsNoRun() {
        let open = ToolCall(toolUseId: "o", name: "Bash", input: ["command": "make test"], startedAt: at(1))
        var running = ShellRun(command: "make test", folder: Self.root, startedAt: at(2))
        running.exitCode = nil
        #expect(Provenance(items: [user(), .tool(id: UUID(), call: open), .shell(id: UUID(), run: running)]) { $0 }.runs.isEmpty)
    }

    @Test func legacysChecksAreWhatTheyWere() {
        // Legacy's line under a message keeps its own reading: it doesn't step over `time`, and
        // the prompt's commands aren't in it.
        let found = Provenance(items: [user(), ran("time make test", at: 1), ran("make test | tail", at: 2), prompt("make test", at: 3)]) { $0 }
        #expect(found.checks[1] == [Provenance.Check(command: "make test | tail", failed: false)])
        #expect(found.runs.count == 3)
    }

    // MARK: The clock

    @Test func aFileChangedAfterAPipedRunIsReadFirstAndTheRunsResultIsNotKnown() {
        // The thread ran the tests through tail and then changed b.swift with sed, which leaves
        // no edit: only the disk knows.
        let page = page(
            [file("a.swift", changed: 10), file("b.swift", changed: 30)],
            [user(), edit("a.swift", at: 9), edit("b.swift", at: 11), ran("make test 2>&1 | tail -20", at: 20), ran("sed -i '' s/0/1/ b.swift", at: 30)])
        #expect(page.readFirst.map(\.file.path) == ["b.swift"])
        #expect(page.readFirst[0].reasons == ["changed after make test last ran"])
        #expect(page.rest.map(\.file.path) == ["a.swift"])
        #expect(page.runs.map(WitnessPage.result) == ["result not known, piped through tail"])
        #expect(page.sentence == "make test last ran before b.swift last changed. It was piped through tail, so its result is not known.")
        #expect(page.below == "everything below last changed before it")
        #expect(page.queued && page.first == 1 && page.total == 2)
        #expect(page.order.count == 2 && page.order.first?.hasPrefix("b.swift#") == true)
    }

    @Test func afterMakeTestAtThePromptTheFileIsUnderTheRunWhichExitedZero() {
        let page = page(
            [file("a.swift", changed: 10), file("b.swift", changed: 30)],
            [user(), ran("make test 2>&1 | tail -20", at: 20), ran("sed -i '' s/0/1/ b.swift", at: 30), prompt("make test", at: 40)])
        #expect(page.readFirst.isEmpty)
        #expect(page.rest.map(\.file.path) == ["a.swift", "b.swift"])
        #expect(page.runs.map(WitnessPage.result) == ["exited 0"])
        #expect(page.sentence == "make test exited 0 and nothing here has changed since.")
        #expect(!page.queued)
    }

    @Test func aFileChangedInTheSameMomentTheRunBeganCountsAsAfter() {
        let page = page([file("a.swift", changed: 20)], [user(), ran("make test", at: 20)])
        #expect(page.readFirst.map(\.file.path) == ["a.swift"])
        #expect(page.sentence == "Everything here changed after make test last ran. It exited 0 then.")
        // Everything is first, so nothing is a queue.
        #expect(!page.queued)
    }

    @Test func aLineAddedRunOverAndRemovedPutsItsFileFirst() {
        // Added, the tests run over it, then taken out again by an edit: the line is gone from
        // the diff, and credit by text would have nothing to say. The file's time says it.
        let page = page(
            [file("a.swift", [hunk(["-let old = 0", "+let new = 1"])], changed: 30)],
            [user(), edit("a.swift", ["+guard ready else { return }"], at: 10), ran("make test", at: 20), edit("a.swift", ["-guard ready else { return }"], at: 30)])
        #expect(page.readFirst.map(\.reasons) == [["changed after make test last ran"]])
    }

    @Test func eachCheckKeepsItsOwnClock() {
        // tsc ran after the edit; make test didn't. tsc exiting 0 doesn't answer for make test.
        let page = page(
            [file("a.ts", changed: 30), file("b.ts", changed: 50)],
            [user(), ran("make test", at: 20, failed: true, result: "1 failed"), edit("a.ts", at: 30), ran("tsc", at: 40), edit("b.ts", at: 50)])
        #expect(page.readFirst.map(\.file.path) == ["a.ts", "b.ts"])
        #expect(page.readFirst[0].reasons == ["changed after make test last ran, only tsc has run since"])
        #expect(page.readFirst[1].reasons == ["changed after make test and tsc last ran"])
        #expect(page.runs.map(\.check) == ["make test", "tsc"])
        #expect(page.sentence == "Everything here changed after make test last ran. It failed then. Only tsc has run since.")
    }

    @Test func theSentenceIsAboutTheCheckThatFailed() {
        // swift build exited 0, then make test failed, and nothing has changed: the page mustn't
        // open on "exited 0".
        let failed = page([file("a.swift", changed: 10)], [user(), ran("swift build", at: 20), ran("make test", at: 30, failed: true, result: "1 failed")])
        #expect(failed.runs.map(\.check) == ["swift build", "make test"])
        #expect(failed.sentence == "make test failed and nothing here has changed since. swift build last ran before it.")
        // And with a file changed between the two, it is still the failure the page is about.
        let between = page(
            [file("a.swift", changed: 25), file("b.swift", changed: 10)],
            [user(), ran("swift build", at: 20), ran("make test", at: 30, failed: true, result: "1 failed"), ran("tsc", at: 40)])
        #expect(between.sentence == "make test failed and nothing here has changed since. swift build last ran before it. Only tsc has run since.")
        #expect(between.readFirst.map(\.reasons) == [["changed after swift build last ran, only make test and tsc have run since"]])
    }

    @Test func aLockfileChangedAfterTheRunIsInTheSentence() {
        let lock = file("package-lock.json", [hunk(["-  \"version\": \"1.0.0\"", "+  \"version\": \"1.0.1\""])], changed: 30)
        let page = page([file("a.swift", changed: 10), lock], [user(), ran("make test", at: 20), ran("npm install", at: 30)])
        #expect(page.readFirst.map(\.file.path) == ["package-lock.json"])
        #expect(page.sentence == "make test last ran before package-lock.json last changed. It exited 0 then.")
        // The same for a file a formatter went over after the run.
        let spaced = self.page(
            [file("a.swift", changed: 10), file("b.swift", [hunk(["-  let a = 1", "+    let a = 1"])], changed: 30)], [user(), ran("make test", at: 20)])
        #expect(spaced.sentence == "make test last ran before b.swift last changed. It exited 0 then.")
    }

    @Test func aRunWithNoTimePutsEverythingFirst() {
        // A thread opened from a Terminal session has no times: its run can't be put before any file.
        let call = ToolCall(toolUseId: "t", name: "Bash", input: ["command": "make test"], result: "ok")
        let page = page([file("a.swift", changed: -86_400)], [user(), .tool(id: UUID(), call: call)], committed: -90_000)
        #expect(page.readFirst.map(\.reasons) == [["changed after make test last ran"]])
        #expect(page.sentence == "Everything here changed after make test last ran. It exited 0 then.")
    }

    @Test func aRunFromBeforeTheLastCommitSaysNothingOfWhatsHere() {
        let items = [user(), ran("make test", at: 10), edit("a.swift", at: 30)]
        let page = page([file("a.swift", changed: 30)], items, committed: 20)
        #expect(page.runs.isEmpty && page.readFirst.isEmpty)
        #expect(page.sentence == "No build or test OriCode recognises has run in this thread since the last commit.")
        #expect(self.page([file("a.swift", changed: 30)], [user(), edit("a.swift", at: 30)]).sentence == "No build or test OriCode recognises ran in this thread.")
    }

    @Test func proseIsNeverFirstForHavingChangedAfterARun() {
        let page = page(
            [file("a.swift", changed: 10), file("KANBAN.md", changed: 30), file("notes.txt", status: "D", changed: nil)],
            [user(), ran("make test", at: 20)])
        #expect(page.readFirst.map(\.file.path) == ["notes.txt"])
        #expect(page.readFirst[0].reasons == ["deleted"])
        #expect(page.rest.map(\.file.path) == ["a.swift", "KANBAN.md"])
        #expect(page.rest[1].aside == "changed since, and no check reads prose")
        #expect(page.below == "everything below but prose last changed before it")
        #expect(page.sentence == "make test exited 0 and nothing but prose has changed since.")
    }

    @Test func aFileWithNoTimeIsReadFirst() {
        let page = page([file("a.swift", changed: nil), file("b.swift", status: "D", changed: nil)], [user(), ran("make test", at: 20)])
        #expect(page.readFirst.map(\.reasons) == [["no time known"], ["deleted"]])
    }

    // MARK: The other reasons

    @Test func wordsTakenOutOfALinePutThatChangeFirstAndNoOther() {
        let dropped = hunk(["-let clear = shown && !pinned && !(beside != nil && right)", "+let clear = shown && !pinned"])
        let plain = hunk(["-let width = 280", "+let width = 300"], at: 40)
        let page = page([file("RootView.swift", [dropped, plain], changed: 10)], [user(), ran("make test", at: 20)])
        #expect(page.readFirst.map(\.reasons) == [["words taken out of a line"]])
        #expect(page.readFirst[0].units.count == 1)
        #expect(page.rest.map(\.units.count) == [1])
        #expect(page.first == 1 && page.total == 2)
        // Each change is on the page once.
        #expect(Set(page.order).count == 2)
    }

    @Test func aLineThatGainedWordsOrLostOnlyPunctuationIsNotIt() {
        let unit = { (lines: [String]) in
            ReviewBook(diff: WorkingDiff(root: Self.root, head: nil, files: [self.file("a.swift", [self.hunk(lines)], changed: 1)]), provenance: Provenance()).units[0]
        }
        #expect(WitnessPage.wordsTakenOut(unit(["-if ready && open { go() }", "+if ready { go() }"])))
        #expect(!WitnessPage.wordsTakenOut(unit(["-if ready { go() }", "+if ready && open { go() }"])))
        #expect(!WitnessPage.wordsTakenOut(unit(["-let names = [first, second,]", "+let names = [first, second]"])))
        #expect(!WitnessPage.wordsTakenOut(unit(["-let a = 1", "+let a = 2"])))
        #expect(!WitnessPage.wordsTakenOut(unit(["-let a = 1"])))
    }

    @Test func aTestsLabelPutsItsChangeFirstWithMoreReasonsHigher() {
        let expectation = hunk(["-assert.doesNotMatch(body, /sk-ant-|planted/);", "+assert.doesNotMatch(body, /sk-ant-/);"])
        let page = page(
            [file("App/A.swift", changed: 30), file("engine/test/credentials.test.ts", [expectation], changed: 30), file("App/B.swift", changed: 5)],
            [user(), edit("App/B.swift", at: 5), edit("App/A.swift", at: 10), ran("make test", at: 20)])
        #expect(page.readFirst.map(\.file.path) == ["engine/test/credentials.test.ts", "App/A.swift"])
        #expect(page.readFirst[0].reasons == ["words taken out of a line", "changes what a test expects", "changed after make test last ran"])
        #expect(page.rest.map(\.file.path) == ["App/B.swift"])
    }

    @Test func aFileEditedThreeTimesWithTwoRunsBetweenIsFirst() {
        let items = [
            user(), edit("a.swift", at: 1), ran("make test", at: 2, failed: true, result: "no"), edit("a.swift", at: 3),
            ran("make test", at: 4, failed: true, result: "no"), edit("a.swift", at: 5), edit("b.swift", at: 6), edit("b.swift", at: 7), edit("b.swift", at: 8),
            ran("make test", at: 9),
        ]
        let page = page([file("a.swift", changed: 5), file("b.swift", changed: 8)], items)
        #expect(page.readFirst.map(\.file.path) == ["a.swift"])
        #expect(page.readFirst[0].reasons == ["edited 3 times with 2 runs between"])
        // Edits from before the last commit aren't counted against what's here now.
        #expect(self.page([file("a.swift", changed: 5)], items, committed: 2.5).readFirst.isEmpty)
    }

    // MARK: The rest of the page

    @Test func theRestIsInTheOrderTheThreadFirstTouchedTheFilesThenWhatNoEditExplains() {
        let page = page(
            [file("a.swift", changed: 3), file("b.swift", changed: 1), file("c.swift", changed: 4), file("d.swift", changed: 2)],
            [user(), edit("c.swift", at: 1), edit("a.swift", at: 2), edit("c.swift", at: 3), ran("make test", at: 20)])
        #expect(page.rest.map(\.file.path) == ["c.swift", "a.swift", "b.swift", "d.swift"])
        #expect(page.rest.map(\.aside) == [nil, nil, "no edit record", "no edit record"])
        // A thread that made no edit has no record to miss.
        #expect(self.page([file("a.swift", changed: 3)], [user(), ran("make test", at: 20)]).rest.map(\.aside) == [nil])
    }

    @Test func aRenamedFileKeepsTheEditsMadeUnderItsOldName() {
        let renamed = file("New.swift", status: "R", oldPath: "Old.swift", [hunk(["-func old()", "+func new()"])], changed: 3)
        let items = [user("Rename it"), edit("Old.swift", ["-func old()", "+func new()"], at: 2), ran("git mv Old.swift New.swift", at: 3), ran("make test", at: 20)]
        let provenance = Provenance(items: items) { RepoPath.relative($0, cwd: Self.root, root: Self.root) }
        let diff = WorkingDiff(root: Self.root, head: "abc", files: [renamed, file("z.swift", changed: 1)])
        let book = ReviewBook(diff: diff, provenance: provenance)
        // The hunk is its turn's, under the name the edit was made on.
        #expect(book.units.first { $0.file.path == "New.swift" }?.turn == 1)
        let page = WitnessPage(diff: diff, units: book.units, provenance: provenance)
        #expect(page.rest.map(\.file.path) == ["New.swift", "z.swift"])
        #expect(page.rest.map(\.aside) == [nil, "no edit record"])
    }

    @Test func spacingMovesAndLockfilesAreOneLineEachAndNeverWhereSpacingIsSyntax() {
        let block = ["func total() -> Int {", "let price = 3", "let count = 4", "let tax = 1", "return price * count + tax", "}"]
        let page = page(
            [
                file("a.swift", [hunk(["-  let a = 1", "+    let a = 1"])], changed: 1),
                file("a.py", [hunk(["-  return a", "+    return a"])], changed: 1),
                file("Package.resolved", [hunk(["-  \"revision\" : \"a\"", "+  \"revision\" : \"b\""])], changed: 1),
                file("Old.swift", [hunk(block.map { "-" + $0 })], changed: 1),
                file("New.swift", [hunk(block.map { "+" + $0 })], changed: 1),
                file("ATests.swift", [hunk(["-    #expect(a == 1)", "+  #expect(a == 1)"])], changed: 1),
            ],
            [user(), ran("make test", at: 20)])
        #expect(page.quiet.map(\.path) == ["a.swift", "Package.resolved", "Old.swift", "New.swift"])
        #expect(page.quiet.map(\.what) == ["spacing only", "lockfile", "moved to New.swift:1", "moved from Old.swift:1"])
        // Python's indentation is its code, and a test's assertion taken out is never quiet.
        #expect(page.rest.map(\.file.path) == ["a.py"])
        #expect(page.readFirst.map(\.file.path) == ["ATests.swift"])
        // A change that needs no reading is still read first when its file changed after the run.
        let later = self.page([file("a.swift", [hunk(["-  let a = 1", "+    let a = 1"])], changed: 30)], [user(), ran("make test", at: 20)])
        #expect(later.quiet.isEmpty && later.readFirst.count == 1)
    }

    @Test func nothingThePageSaysClaimsARunPassed() {
        let pages = [
            page([file("a.swift", changed: 10), file("b.swift", changed: 30)], [user(), ran("make test", at: 20)]),
            page([file("a.swift", changed: 10)], [user(), ran("make test", at: 20)]),
            page([file("a.swift", changed: 10)], [user(), ran("make test | tail", at: 20)]),
            page([file("a.swift", changed: 30)], [user(), ran("make test", at: 20, failed: true, result: "no"), prompt("swift build", at: 25)]),
            page([file("a.swift", changed: 30), file("README.md", changed: 40)], [user(), ran("tsc", at: 20, background: true)]),
            page([file("a.swift", changed: 30)], []),
        ]
        for page in pages {
            let words = said(page).lowercased()
            for word in ["passed", "verified", "covered", "tested", "checked", "✓", "✔"] {
                #expect(!words.contains(word), "\(word) in: \(words)")
            }
        }
    }

    // MARK: The shared state

    private func model() throws -> AppModel {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = AppModel(container: container)
        model.review.marks = ReviewMarks(file: FileManager.default.temporaryDirectory.appending(path: "oricode-marks-\(UUID().uuidString).json"))
        return model
    }

    private func reply(_ files: [(path: String, lines: [String], changed: Double)], mark: String) -> JSON {
        let files = files.map { file -> JSON in
            let hunk: JSON = ["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1, "context": "", "lines": .array(file.lines.map(JSON.string))]
            return [
                "path": .string(file.path), "oldPath": nil, "status": "M", "binary": false, "executable": false, "hunks": [hunk],
                "added": 1, "deleted": 1, "cut": false, "stamp": nil, "lossy": false, "changedAt": .number(at(file.changed).timeIntervalSince1970 * 1000),
            ]
        }
        return ["root": .string(Self.root), "head": "abc", "headAt": .number(at(0).timeIntervalSince1970 * 1000), "mark": .string(mark), "files": .array(files)]
    }

    @Test func theKeyboardWalksThePagesOrderAndSpaceGoesToTheNextUnreviewed() async throws {
        let model = try model()
        let review = model.review
        review.design = .witness
        review.look(at: Self.root, for: nil)
        // b.swift lost a clause, so it's first on the page though git lists a.swift first.
        try await model.take(reply([("a.swift", ["-let a = 0", "+let a = 1"], 1), ("b.swift", ["-if ready && open { go() }", "+if ready { go() }"], 1), ("c.swift", ["-let c = 0", "+let c = 1"], 1)], mark: "one"), in: Self.root)
        #expect(review.diff?.headAt != nil && review.diff?.files[0].changedAt != nil)
        #expect(review.page.readFirst.map(\.file.path) == ["b.swift"])
        #expect(review.visibleUnits.map(\.file.path) == ["b.swift", "a.swift", "c.swift"])

        review.move(1)
        #expect(review.selectedUnit?.file.path == "b.swift")
        review.move(1)
        #expect(review.selectedUnit?.file.path == "a.swift")
        review.move(-1)
        #expect(review.selectedUnit?.file.path == "b.swift")

        // Space marks it and walks on, and a chapter all reviewed folds nothing away in Witness.
        model.toggleSelectedReviewed()
        #expect(review.book.units.first { $0.file.path == "b.swift" }?.reviewed == true)
        #expect(review.selectedUnit?.file.path == "a.swift")
        model.toggleSelectedReviewed()
        model.toggleSelectedReviewed()
        #expect(review.book.toReview == 0)
        #expect(review.visibleUnits.count == 3)
        // The same marks are Legacy's: its chapter, all reviewed, is folded.
        review.design = .legacy
        #expect(review.visibleUnits.isEmpty)
    }

    /// A reply whose files have a hunk for each list of lines, a hundred lines apart.
    private func reply(hunks files: [(path: String, hunks: [[String]])], mark: String) -> JSON {
        let files = files.map { file -> JSON in
            let hunks = file.hunks.enumerated().map { index, lines -> JSON in
                ["oldStart": .number(Double(index * 100 + 1)), "oldLines": 1, "newStart": .number(Double(index * 100 + 1)), "newLines": 1, "context": "", "lines": .array(lines.map(JSON.string))]
            }
            return [
                "path": .string(file.path), "oldPath": nil, "status": "M", "binary": false, "executable": false, "hunks": .array(hunks),
                "added": .number(Double(file.hunks.count)), "deleted": .number(Double(file.hunks.count)), "cut": false, "stamp": nil, "lossy": false,
                "changedAt": .number(at(1).timeIntervalSince1970 * 1000),
            ]
        }
        return ["root": .string(Self.root), "head": "abc", "headAt": .number(at(0).timeIntervalSince1970 * 1000), "mark": .string(mark), "files": .array(files)]
    }

    @Test func afterAClickTheKeyboardReadsTheRestOfTheFile() async throws {
        let model = try model()
        let review = model.review
        review.design = .witness
        review.look(at: Self.root, for: nil)
        try await model.take(reply(hunks: [
            ("a.swift", [["-let a = 0", "+let a = 1"]]),
            ("b.swift", [["-let b = 0", "+let b = 1"], ["-let c = 0", "+let c = 1"], ["-let d = 0", "+let d = 1"]]),
        ], mark: "one"), in: Self.root)
        let b = review.book.units.filter { $0.file.path == "b.swift" }
        #expect(b.count == 3)
        // A click puts the keyboard on a change without opening anything, as UnitView's tap does.
        review.selected = b[0].id
        review.move(1)
        #expect(review.selected == b[1].id)
        review.move(1)
        #expect(review.selected == b[2].id)
        review.move(-1)
        #expect(review.selected == b[1].id)
    }

    @Test func spaceStaysInReadFirstWhenTheFilesOtherChangeIsBelow() async throws {
        let model = try model()
        let review = model.review
        review.design = .witness
        review.look(at: Self.root, for: nil)
        // a.swift has one change that lost a clause and one that didn't; b.swift lost one too.
        try await model.take(reply(hunks: [
            ("a.swift", [["-if ready && open { go() }", "+if ready { go() }"], ["-let a = 0", "+let a = 1"]]),
            ("b.swift", [["-if set && open { go() }", "+if set { go() }"]]),
        ], mark: "one"), in: Self.root)
        #expect(review.page.readFirst.map(\.file.path) == ["a.swift", "b.swift"])
        #expect(review.page.rest.map(\.file.path) == ["a.swift"])
        #expect(review.visibleUnits.map(\.file.path) == ["a.swift", "b.swift", "a.swift"])
        review.move(1)
        model.toggleSelectedReviewed()
        #expect(review.selectedUnit?.file.path == "b.swift")
        model.toggleSelectedReviewed()
        #expect(review.selected == review.page.rest[0].units[0])
    }

    @Test func whenTheChangeUnderTheKeyboardGoesTheOneInItsPlaceIsSelected() async throws {
        let model = try model()
        let review = model.review
        review.design = .witness
        review.look(at: Self.root, for: nil)
        try await model.take(reply([("a.swift", ["-let a = 0", "+let a = 1"], 1), ("b.swift", ["-if ready && open { go() }", "+if ready { go() }"], 1), ("c.swift", ["-let c = 0", "+let c = 1"], 1), ("d.swift", ["-let d = 0", "+let d = 1"], 1)], mark: "one"), in: Self.root)
        #expect(review.visibleUnits.map(\.file.path) == ["b.swift", "a.swift", "c.swift", "d.swift"])
        review.selected = review.visibleUnits[2].id
        // c.swift is gone from the next read, as after the agent put it back: the keyboard is on
        // what stands third now, not at the top.
        try await model.take(reply([("a.swift", ["-let a = 0", "+let a = 1"], 1), ("b.swift", ["-if ready && open { go() }", "+if ready { go() }"], 1), ("d.swift", ["-let d = 0", "+let d = 1"], 1)], mark: "two"), in: Self.root)
        #expect(review.selectedUnit?.file.path == "d.swift")
    }

    @Test func aCommandEndingBuildsThePageAgainThoughNoFileMoved() async throws {
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
        #expect(model.chat?.id == chat.id)
        let conversation = model.conversation(for: chat)
        conversation.userSent("Do it")
        let review = model.review
        review.design = .witness
        review.look(at: Self.root, for: chat.id)
        try await model.take(reply([("a.swift", ["-let a = 0", "+let a = 1"], 1)], mark: "one"), in: Self.root)
        #expect(review.page.runs.isEmpty)
        #expect(review.page.sentence == "No build or test OriCode recognises ran in this thread.")

        // You run the tests at the prompt: git has nothing new to say, and the page has.
        var run = ShellRun(command: "make test", folder: Self.root, startedAt: at(50))
        let id = UUID()
        conversation.shellStarted(run, id: id)
        let same: JSON = ["root": .string(Self.root), "same": true]
        try await model.take(same, in: Self.root)
        #expect(review.page.runs.isEmpty)
        run.endedAt = at(55)
        run.exitCode = 0
        conversation.shellChanged(id, run)
        try await model.take(same, in: Self.root)
        #expect(review.page.runs.map(WitnessPage.result) == ["exited 0"])
        #expect(review.page.sentence == "make test exited 0 and nothing here has changed since.")

        // A command that checks nothing builds nothing: a book emptied here stays empty.
        review.book = ReviewBook()
        var listing = ShellRun(command: "ls -la", folder: Self.root, startedAt: at(60))
        listing.endedAt = at(61)
        listing.exitCode = 0
        conversation.shellStarted(listing, id: UUID())
        try await model.take(same, in: Self.root)
        #expect(review.book.units.isEmpty)

        // And Legacy builds nothing for a check either.
        review.design = .legacy
        try await model.take(same, in: Self.root)
        review.book = ReviewBook()
        conversation.shellStarted(run, id: UUID())
        try await model.take(same, in: Self.root)
        #expect(review.book.units.isEmpty)
    }

    @Test func aStoredCallComesBackWithTheTimeItStarted() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let project = Project(name: "repo", path: Self.root)
        context.insert(project)
        let chat = Chat(project: project)
        context.insert(chat)
        let use = Event(turn: 1, seq: 0, kind: "tool.use", payload: try JSON.object(["event": "tool.use", "toolUseId": "t", "name": "Bash", "input": ["command": "make test"]]).data())
        use.createdAt = at(42)
        context.insert(use)
        use.chat = chat
        let result = Event(turn: 1, seq: 1, kind: "tool.result", payload: try JSON.object(["event": "tool.result", "toolUseId": "t", "content": "ok", "isError": false]).data())
        context.insert(result)
        result.chat = chat
        try context.save()
        let conversation = Conversation(chat: chat, context: context)
        guard case .tool(_, let call) = conversation.items.first else {
            Issue.record("no call")
            return
        }
        #expect(call.startedAt == at(42))
        #expect(Provenance(items: conversation.items) { $0 }.runs.map(\.startedAt) == [at(42)])
    }

    @Test func aThreadOpenedFromATerminalSessionHasNoTimesForItsRuns() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "repo", path: Self.root)
        container.mainContext.insert(project)
        try container.mainContext.save()
        let model = AppModel(container: container)
        let events: [JSON] = [
            ["event": "user", "text": "Run the tests"],
            ["event": "tool.use", "toolUseId": "t1", "name": "Bash", "input": ["command": "make test"]],
            ["event": "tool.result", "toolUseId": "t1", "content": "ok", "isError": false],
        ]
        let chat = model.adopt(CLISession(id: "s-1", title: "Run the tests", modified: 0, branch: nil), events: events, in: project)
        let runs = Provenance(items: model.conversation(for: chat).items) { $0 }.runs
        #expect(runs.map(\.check) == ["make test"])
        // The moment it was opened is no run's start: every file would read as older than it.
        #expect(runs.map(\.startedAt) == [nil])

        // One opened by a build that didn't mark its calls: the call and its result were stored
        // in the same instant, which no command watched as it ran is.
        let context = ModelContext(container)
        let old = Chat(project: project)
        context.insert(old)
        for (seq, body) in events.enumerated() {
            let event = Event(turn: 1, seq: seq, kind: body["event"]?.string ?? "", payload: try body.data())
            event.createdAt = at(100 + Double(seq) / 10_000)
            context.insert(event)
            event.chat = old
        }
        try context.save()
        #expect(Provenance(items: Conversation(chat: old, context: context).items) { $0 }.runs.map(\.startedAt) == [nil])
    }
}
