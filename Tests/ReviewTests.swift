import Foundation
import SwiftData
import Testing
@testable import OriCode

@MainActor
struct ReviewTests {
    private static let root = "/work/repo"

    private func edit(_ path: String, _ lines: [String]) -> Item {
        let call = ToolCall(
            toolUseId: UUID().uuidString, name: "Edit", input: ["file_path": .string(Self.root + "/" + path)],
            result: "ok", patch: [Hunk(oldStart: 1, newStart: 1, lines: lines)])
        return .tool(id: UUID(), call: call)
    }

    private func write(_ path: String, _ content: String) -> Item {
        let call = ToolCall(
            toolUseId: UUID().uuidString, name: "Write", input: ["file_path": .string(Self.root + "/" + path), "content": .string(content)],
            result: "ok", patch: [])
        return .tool(id: UUID(), call: call)
    }

    private func user(_ text: String) -> Item { .user(id: UUID(), text: text) }

    private func provenance(_ items: [Item]) -> Provenance {
        Provenance(items: items) { RepoPath.relative($0, cwd: Self.root, root: Self.root) }
    }

    private func file(_ path: String, status: String = "M", _ hunks: [DiffHunk]) -> FileDiff {
        FileDiff(
            path: path, oldPath: nil, status: status, binary: false, executable: false, hunks: hunks,
            added: hunks.flatMap(\.lines).count { $0.hasPrefix("+") }, deleted: hunks.flatMap(\.lines).count { $0.hasPrefix("-") },
            cut: false, stamp: nil, lossy: false)
    }

    private func hunk(_ lines: [String], at start: Int = 1) -> DiffHunk {
        let old = lines.count { !$0.hasPrefix("+") }, new = lines.count { !$0.hasPrefix("-") }
        return DiffHunk(oldStart: start, oldLines: old, newStart: start, newLines: new, context: "", lines: lines)
    }

    @Test func eachLineBelongsToTheLatestTurnThatWroteIt() {
        let found = provenance([
            user("Rename the helper"),
            edit("App/A.swift", [" context", "-func old()", "+func new()"]),
            user("Now add a README"),
            write("README.md", "# Repo\nHello\n"),
            edit("App/A.swift", ["+func new()", "+// again"]),
        ])
        #expect(found.prompts[1] == "Rename the helper")
        #expect(found.turn(of: "-func old()", in: "App/A.swift") == 1)
        #expect(found.turn(of: "+func new()", in: "App/A.swift") == 2)
        #expect(found.turn(of: "+Hello", in: "README.md") == 2)
        #expect(found.turn(of: "+Hello", in: "App/A.swift") == nil)
        #expect(found.turn(of: " context", in: "App/A.swift") == nil)
        #expect(found.rank(of: "README.md", in: 2) == 0)
        #expect(found.rank(of: "App/A.swift", in: 2) == 1)
    }

    @Test func aFailedOrUnfinishedEditProvesNothing() {
        var failed = ToolCall(toolUseId: "x", name: "Edit", input: ["file_path": .string(Self.root + "/a.txt")], result: "no", patch: [Hunk(oldStart: 1, newStart: 1, lines: ["+x"])])
        failed.isError = true
        let running = ToolCall(toolUseId: "y", name: "Edit", input: ["file_path": .string(Self.root + "/a.txt")], patch: [Hunk(oldStart: 1, newStart: 1, lines: ["+y"])])
        let found = provenance([user("go"), .tool(id: UUID(), call: failed), .tool(id: UUID(), call: running)])
        #expect(found.isEmpty)
    }

    @Test func theBookTellsTurnsInOrderAndWhatNoEditMadeLast() {
        let found = provenance([
            user("First"), edit("b.swift", ["+let b = 1"]),
            user("Second"), edit("a.swift", ["+let a = 2"]), edit("c.swift", ["+let c = 3"]),
        ])
        let diff = WorkingDiff(root: Self.root, head: nil, files: [
            file("a.swift", [hunk(["+let a = 2"])]),
            file("b.swift", [hunk(["+let b = 1"])]),
            file("c.swift", [hunk(["+let c = 3"])]),
            file("d.swift", [hunk(["+let d = 4"])]),
        ])
        let book = ReviewBook(diff: diff, provenance: found).marked(with: [:])
        #expect(book.chapters.map(\.turn) == [1, 2, nil])
        #expect(book.chapters.map(\.prompt) == ["First", "Second", nil])
        // The second turn edited a.swift before c.swift, and says so in that order.
        #expect(book.chapters[1].files.map(\.file.path) == ["a.swift", "c.swift"])
        #expect(book.chapters[2].files.map(\.file.path) == ["d.swift"])
        #expect(book.toReview == 4)
    }

    @Test func aLineNoEditMadeIsMarkedInsideClaudesHunk() {
        let found = provenance([user("Add it"), edit("a.swift", ["+let claude = 1", "+}"])])
        let diff = WorkingDiff(root: Self.root, head: nil, files: [
            file("a.swift", [hunk(["+let claude = 1", "+let mine = 2", "+}"])]),
        ])
        let unit = ReviewBook(diff: diff, provenance: found).marked(with: [:]).units[0]
        #expect(unit.turn == 1)
        #expect(unit.lines.map(\.foreign) == [false, true, false])
    }

    @Test func aReviewedHunkThatChangesComesBackWithWhatYouSawDimmed() {
        let found = Provenance()
        let first = WorkingDiff(root: Self.root, head: nil, files: [file("a.swift", [hunk(["+let one = 1", "+let two = 2"])])])
        let unit = ReviewBook(diff: first, provenance: found).marked(with: [:]).units[0]
        let marks = [unit.fingerprint: ReviewMark(path: "a.swift", lines: unit.lines.map(\.signed), at: .now)]
        #expect(ReviewBook(diff: first, provenance: found).marked(with: marks).units[0].reviewed)

        // Edits above it move it down: still the same change, still reviewed.
        let moved = WorkingDiff(root: Self.root, head: nil, files: [file("a.swift", [hunk(["+let one = 1", "+let two = 2"], at: 40)])])
        #expect(ReviewBook(diff: moved, provenance: found).marked(with: marks).units[0].reviewed)

        let changed = WorkingDiff(root: Self.root, head: nil, files: [file("a.swift", [hunk(["+let one = 1", "+let two = 22", "+let three = 3"])])])
        let again = ReviewBook(diff: changed, provenance: found).marked(with: marks).units[0]
        #expect(!again.reviewed)
        #expect(again.changedSince)
        #expect(again.lines.map(\.seen) == [true, false, false])
    }

    @Test func spacingOnlyIsSpacingOnly() {
        #expect(ReviewBook.whitespaceOnly(ReviewBook.lines(of: hunk(["-if a {", "+if a  {", "+", " }"]))))
        #expect(!ReviewBook.whitespaceOnly(ReviewBook.lines(of: hunk(["-if a {", "+if b {"]))))
        #expect(!ReviewBook.whitespaceOnly(ReviewBook.lines(of: hunk([" x"]))))
    }

    @Test func linesAreNumberedOnBothSides() {
        let lines = ReviewBook.lines(of: DiffHunk(oldStart: 10, oldLines: 3, newStart: 12, newLines: 3, context: "", lines: [" a", "-b", "+c", " d", "\\ No newline at end of file"]))
        #expect(lines.map(\.old) == [10, 11, nil, 12])
        #expect(lines.map(\.new) == [12, nil, 13, 14])
        #expect(lines.map(\.noNewline) == [false, false, false, true])
    }

    @Test func wordsThatChangedAreFoundInALineEdited() throws {
        let (old, new) = try #require(WordDiff.pair("let total = price * count", "let total = price * quantity"))
        #expect(old == [20..<25])
        #expect(new == [20..<28])
        // A short line changed in one place still shows where.
        let (hi, hello) = try #require(WordDiff.pair("    \"hi\"", "    \"hello\""))
        #expect(hi == [5..<7])
        #expect(hello == [5..<10])
        // A different line altogether gets no words lit.
        #expect(WordDiff.pair("return nil", "let view = makeView(for: item, in: context)") == nil)
        let ranges = WordDiff.ranges(in: ReviewBook.lines(of: hunk(["-let a = f(x)", "-let b = 2", "+let a = f(y)", "+let b = 3", "+let c = 4"])))
        #expect(ranges[0] == [10..<11])
        #expect(ranges[2] == [10..<11])
        #expect(ranges[4] == nil)
    }

    @Test func aPatchNamesTheFileTheWayGitReadsIt() {
        #expect(PatchText.quoted("a/plain name.swift") == "a/plain name.swift")
        #expect(PatchText.quoted("a/tab\there") == "\"a/tab\\there\"")
        #expect(PatchText.quoted("a/say \"hi\"") == "\"a/say \\\"hi\\\"\"")
        let text = PatchText.of("x.txt", hunks: [DiffHunk(oldStart: 3, oldLines: 1, newStart: 3, newLines: 1, context: "f()", lines: ["-a", "+b"])])
        #expect(text == "diff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n@@ -3,1 +3,1 @@\n-a\n+b\n")
    }

    @Test func editPathsBecomePathsFromTheRepositorysTop() {
        #expect(RepoPath.relative("/work/repo/App/A.swift", cwd: "/work/repo/App", root: "/work/repo") == "App/A.swift")
        #expect(RepoPath.relative("B.swift", cwd: "/work/repo/App", root: "/work/repo") == "App/B.swift")
        #expect(RepoPath.relative("/work/repo/App/../README.md", cwd: "/work/repo", root: "/work/repo") == "README.md")
        #expect(RepoPath.relative("/elsewhere/C.swift", cwd: "/work/repo", root: "/work/repo") == nil)
        #expect(RepoPath.relative("/work/repository/C.swift", cwd: "/work/repo", root: "/work/repo") == nil)
    }

    @Test func aBlockThatMovedIsQuietAtBothEndsAndItsEditStaysLit() {
        let block = ["func total() -> Int {", "let price = 3", "let count = 4", "let tax = 1", "return price * count + tax", "}"]
        let diff = WorkingDiff(root: Self.root, head: nil, files: [
            file("Old.swift", [hunk([" import Foundation"] + block.map { "-" + $0 })]),
            file("New.swift", [hunk(["+// Moved here"] + block.map { "+    " + $0 }.replacing(["+    let tax = 1"], with: ["+    let tax = 2"]))]),
        ])
        let units = ReviewBook(diff: diff, provenance: Provenance()).marked(with: [:]).units
        let old = units.first { $0.file.path == "Old.swift" }!, new = units.first { $0.file.path == "New.swift" }!
        #expect(old.labels == ["moved to New.swift:2, changed on the way"])
        #expect(new.labels == ["moved from Old.swift:2, changed on the way"])
        // The closing brace goes with the block; the line that changed and the new comment stay lit.
        #expect(new.lines.map(\.moved) == [false, true, true, true, false, true, true])
        #expect(old.lines.filter { $0.kind == .deleted }.map(\.moved) == [true, true, true, false, true, true])
    }

    @Test func aLineEditedInPlaceIsNotAMove() {
        let diff = WorkingDiff(root: Self.root, head: nil, files: [
            file("A.swift", [hunk(["-let a = 1", "-let b = 2", "-let c = 3", "+    let a = 1", "+    let b = 2", "+    let c = 3"])]),
        ])
        let unit = ReviewBook(diff: diff, provenance: Provenance()).marked(with: [:]).units[0]
        #expect(unit.labels == ["spacing only"])
        #expect(unit.lines.allSatisfy { !$0.moved })
    }

    @Test func aTestWhoseExpectationChangesIsFlagged() {
        let diff = WorkingDiff(root: Self.root, head: nil, files: [
            file("Tests/CartTests.swift", [hunk(["-    #expect(cart.total == 3)", "+    #expect(cart.total == 4)"])]),
            file("Tests/NewTests.swift", [hunk(["+    #expect(cart.total == 4)"])]),
            file("src/cart.test.ts", [hunk([" it('totals', () => {", "+  test.skip('rounds', () => {})"])]),
            file("App/Cart.swift", [hunk(["-    assert(total >= 0)", "+    precondition(total >= 0)"])]),
        ])
        let labels = Dictionary(uniqueKeysWithValues: ReviewBook(diff: diff, provenance: Provenance()).marked(with: [:]).units.map { ($0.file.path, $0.labels) })
        #expect(labels["Tests/CartTests.swift"] == ["changes what a test expects"])
        #expect(labels["Tests/NewTests.swift"] == [])
        #expect(labels["src/cart.test.ts"] == ["switches a test off"])
        #expect(labels["App/Cart.swift"] == [])
    }

    @Test func testsAreKnownByTheirPlaceOrName() {
        for path in ["Tests/A.swift", "OriCodeTests/A.swift", "src/__tests__/a.ts", "a.test.ts", "pkg/a_test.go", "test_a.py", "ASpec.kt", "spec/a_spec.rb"] {
            #expect(Signals.isTest(path), "\(path)")
        }
        for path in ["App/Contest.swift", "src/latest.ts", "attest.py", "App/Testimonial.swift"] {
            #expect(!Signals.isTest(path), "\(path)")
        }
    }

    @Test func aLockfileSaysWhatItIs() {
        let diff = WorkingDiff(root: Self.root, head: nil, files: [file("web/package-lock.json", [hunk(["-  \"a\": 1", "+  \"a\": 2"])])])
        let unit = ReviewBook(diff: diff, provenance: Provenance()).marked(with: [:]).units[0]
        #expect(unit.lockfile)
        #expect(unit.labels == ["lockfile"])
    }

    @Test func aTurnsChecksAreTheBuildsAndTestsItRan() {
        var failing = ToolCall(toolUseId: "t", name: "Bash", input: ["command": "cd /work/repo && make test"], result: "1 failed")
        failing.isError = true
        let passing = ToolCall(toolUseId: "b", name: "Bash", input: ["command": "swift build"], result: "ok")
        let looking = ToolCall(toolUseId: "l", name: "Bash", input: ["command": "ls -la"], result: "files")
        let found = provenance([user("Fix it"), .tool(id: UUID(), call: failing), .tool(id: UUID(), call: passing), .tool(id: UUID(), call: looking)])
        #expect(found.checks[1] == [Provenance.Check(command: "cd /work/repo && make test", failed: true), Provenance.Check(command: "swift build", failed: false)])
    }

    @Test func onlyATestOrBuildToolCountsAsACheck() {
        for command in ["make test", "cd app && swift build", "npm run lint", "PATH=/opt/homebrew/bin:$PATH node --test test/*.test.ts", "pytest -q", "xcodebuild -scheme X test"] {
            #expect(Provenance.checks(command), "\(command)")
        }
        for command in ["cat test.txt", "ls build", "git status", "grep -r test .", "echo build"] {
            #expect(!Provenance.checks(command), "\(command)")
        }
    }

    @Test func onePathListedTwiceIsTwoFilesNotACrash() {
        // git rm --cached leaves a path deleted from the index and untracked on disk at once.
        let diff = WorkingDiff(root: Self.root, head: nil, files: [
            file("gone.txt", status: "D", [hunk(["-gone"])]),
            file("gone.txt", status: "?", [hunk(["+gone"])]),
        ])
        let book = ReviewBook(diff: diff, provenance: Provenance()).marked(with: [:])
        #expect(book.units.count == 2)
        #expect(Set(book.units.map(\.id)).count == 2)
        #expect(book.chapters.flatMap(\.files).count == 2)
    }

    @Test func coloursAreKeptPerHunkNotPerChange() {
        let diff = WorkingDiff(root: Self.root, head: nil, files: [
            file("a.swift", [hunk([" a", " b", "+@MainActor", " c"]), hunk([" x", "+@MainActor", " y"], at: 30)]),
        ])
        let units = ReviewBook(diff: diff, provenance: Provenance()).marked(with: [:]).units
        #expect(units[0].fingerprint == units[1].fingerprint)
        #expect(units[0].colourKey != units[1].colourKey)
        #expect(units[0].id != units[1].id)
    }

    @Test func twoHunksMakingTheSameLineCanBothBeReviewed() {
        let marks = ReviewMarks(file: FileManager.default.temporaryDirectory.appending(path: "oricode-marks-\(UUID().uuidString).json"))
        let diff = WorkingDiff(root: Self.root, head: "abc", files: [
            file("a.swift", [hunk(["+return nil", "+// one"]), hunk(["+return nil", "+// two"], at: 30)]),
        ])
        let units = ReviewBook(diff: diff, provenance: Provenance()).units
        let current = Set(units.map(\.fingerprint))
        marks.mark([units[0]], in: Self.root, current: current)
        marks.mark([units[1]], in: Self.root, current: current)
        let book = ReviewBook(diff: diff, provenance: Provenance()).marked(with: marks.marks(in: Self.root))
        #expect(book.units.map(\.reviewed) == [true, true])
    }

    @Test func marksOutlastAStashAndGoOnceHeadMoves() {
        let marks = ReviewMarks(file: FileManager.default.temporaryDirectory.appending(path: "oricode-marks-\(UUID().uuidString).json"))
        let diff = WorkingDiff(root: Self.root, head: "abc", files: [file("a.swift", [hunk(["+let a = 1"])])])
        let unit = ReviewBook(diff: diff, provenance: Provenance()).units[0]
        marks.prune(in: Self.root, head: "abc", keeping: ["a.swift"])
        marks.mark([unit], in: Self.root, current: [unit.fingerprint])
        // Stashed: the file leaves the diff, HEAD stays.
        marks.prune(in: Self.root, head: "abc", keeping: [])
        #expect(marks.marks(in: Self.root)[unit.fingerprint] != nil)
        // Committed elsewhere: HEAD moves, and the file isn't in the diff.
        marks.prune(in: Self.root, head: "def", keeping: [])
        #expect(marks.marks(in: Self.root).isEmpty)
    }

    @Test func aNewFileStaysReviewedWhenItsAdded() {
        let untracked = file("n.swift", status: "?", [hunk(["+let n = 1"])])
        let added = file("n.swift", status: "A", [hunk(["+let n = 1"])])
        #expect(Fingerprint.of(path: "n.swift", status: untracked.status, hunk: untracked.hunks[0]) == Fingerprint.of(path: "n.swift", status: added.status, hunk: added.hunks[0]))
        // Its section keeps its name too, so staging it doesn't fold it under the reader.
        let section = { (file: FileDiff) in ReviewBook(diff: WorkingDiff(root: Self.root, head: nil, files: [file]), provenance: Provenance()).units[0].section }
        #expect(section(untracked) == section(added))
    }

    @Test func crlfLinesSplitWhereTheFileDoes() {
        let lines = AttributedString("one\r\ntwo\r\nthree").lines()
        #expect(lines.map { String($0.characters) } == ["one\r", "two\r", "three"])
    }

    @Test func theKeyboardReadsOneFileAtATime() {
        let diff = WorkingDiff(root: Self.root, head: nil, files: [
            file("a.swift", [hunk(["+let a = 1"])]),
            file("b.swift", [hunk(["+let b = 1"]), hunk(["+let b = 2"], at: 30)]),
            file("c.swift", [hunk(["+let c = 1"])]),
        ])
        let book = ReviewBook(diff: diff, provenance: Provenance())
        let units = book.units
        let (a, b, c) = (units[0].section, units[1].section, units[3].section)

        // The first look opens the top file with something to review, and only that one.
        let review = ReviewState()
        review.book = book.marked(with: [:])
        review.placeFiles()
        #expect(review.openFiles == [a])
        let reviewed = ReviewState()
        reviewed.book = book.marked(with: [units[0].fingerprint: ReviewMark(path: "a.swift", lines: ["+let a = 1"], at: .now)])
        reviewed.placeFiles()
        #expect(reviewed.openFiles == [b])

        // Going into a closed file opens it and closes the one left behind.
        review.move(1)
        #expect(review.selected == units[0].id)
        review.move(1)
        #expect(review.selected == units[1].id)
        #expect(review.openFiles == [b])
        #expect(review.selectedUnit?.id == units[1].id)

        // A file closed under the keyboard is passed over whole, and its hunk can't be acted on.
        review.toggle(book.chapters[0].files[1])
        #expect(review.selectedUnit == nil)
        review.move(1)
        #expect(review.selected == units[3].id)
        #expect(review.openFiles == [c])
    }

    @Test func aMarkFinishesItsFileBeforeGoingOn() {
        let diff = WorkingDiff(root: Self.root, head: nil, files: [
            file("a.swift", [hunk(["+let a = 1"]), hunk(["+let a = 2"], at: 20), hunk(["+let a = 3"], at: 40)]),
            file("b.swift", [hunk(["+let b = 1"])]),
            file("c.swift", [hunk(["+let c = 1"])]),
        ])
        let book = ReviewBook(diff: diff, provenance: Provenance())
        let units = book.units
        let marked = { (reviewed: [ReviewUnit]) in
            book.marked(with: Dictionary(uniqueKeysWithValues: reviewed.map {
                ($0.fingerprint, ReviewMark(path: $0.file.path, lines: $0.lines.map(\.signed), at: .now))
            }))
        }
        let review = ReviewState()

        // Marking a.swift's second hunk goes back for its first before leaving the file.
        review.book = marked([units[2]])
        #expect(review.next(after: units[1])?.id == units[0].id)
        // With a.swift done, it goes on to b.swift.
        review.book = marked([units[0], units[2]])
        #expect(review.next(after: units[1])?.id == units[3].id)
        // A whole file marked goes on to the first hunk to review after it, round to the top.
        #expect(review.next(afterFile: units[3].section)?.id == units[4].id)
        #expect(review.next(afterFile: units[4].section)?.id == units[1].id)

        // ⌥ opens or folds every file, and folding lets go of a note being written.
        review.openFiles = [units[0].section]
        review.noting = units[0].id
        review.toggle(book.chapters[0].files[1], all: true)
        #expect(review.openFiles == Set(units.map(\.section)))
        review.toggle(book.chapters[0].files[1], all: true)
        #expect(review.openFiles.isEmpty)
        #expect(review.noting == nil)
    }

    @Test func eachThreadGetsItsOwnFirstLook() {
        let diff = WorkingDiff(root: Self.root, head: nil, files: [
            file("a.swift", [hunk(["+let a = 1"])]),
            file("b.swift", [hunk(["+let b = 1"])]),
        ])
        // The first thread made b.swift; the second, in the same folder, made nothing.
        let first = ReviewBook(diff: diff, provenance: provenance([user("Add b"), edit("b.swift", ["+let b = 1"])])).marked(with: [:])
        let second = ReviewBook(diff: diff, provenance: Provenance()).marked(with: [:])
        let (one, two) = (UUID(), UUID())
        let review = ReviewState()
        review.look(at: Self.root, for: one)
        review.book = first
        review.placeFiles()
        review.move(1)
        #expect(review.openFiles == [first.chapters[0].files[0].id])
        #expect(review.selectedUnit != nil)

        // Another thread in the folder starts from nothing and gets a first look of its own.
        review.look(at: Self.root, for: two)
        #expect(review.openFiles.isEmpty && review.selected == nil && !review.placed)
        review.book = second
        review.placeFiles()
        #expect(review.openFiles == [second.units[0].section])
        review.look(at: Self.root, for: two)
        #expect(review.openFiles == [second.units[0].section])

        // A read whose book no longer has the open files lets them go and looks again.
        review.openFiles = [first.units[0].section]
        review.keepOpenFiles()
        #expect(review.openFiles.isEmpty && !review.placed)
        review.placeFiles()
        #expect(review.openFiles == [second.units[0].section])
        // Folding every file by hand isn't undone by the next read.
        review.toggle(second.chapters[0].files[0])
        review.keepOpenFiles()
        #expect(review.openFiles.isEmpty && review.placed)
    }

    /// git.diff's reply for one line of a.swift changed, read at `mark`.
    private func read(_ line: String, mark: String) -> JSON {
        let hunk: JSON = ["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1, "context": "", "lines": ["-let a = 0", .string("+" + line)]]
        let file: JSON = [
            "path": "a.swift", "oldPath": nil, "status": "M", "binary": false, "executable": false, "hunks": [hunk],
            "added": 1, "deleted": 1, "cut": false, "stamp": nil, "lossy": false,
        ]
        return ["root": .string(Self.root), "head": "abc", "mark": .string(mark), "files": [file]]
    }

    @Test func aReadThatFoundNothingMovedBuildsNothingAndAClosedReviewColoursNothing() async throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = AppModel(container: container)
        let review = model.review
        review.marks = ReviewMarks(file: FileManager.default.temporaryDirectory.appending(path: "oricode-marks-\(UUID().uuidString).json"))
        review.look(at: Self.root, for: nil)
        try await model.take(read("let a = 1", mark: "one"), in: Self.root)
        #expect(review.diff?.mark == "one")
        #expect(review.book.units.count == 1)
        // Closed, the review colours nothing, which would load JavaScriptCore for it.
        #expect(review.colours.isEmpty && review.colouring == nil)

        // Nothing moved: the book isn't built again, so one emptied here stays empty.
        let same: JSON = ["root": .string(Self.root), "same": true]
        review.base = ReviewBook()
        review.book = ReviewBook()
        try await model.take(same, in: Self.root)
        #expect(review.book.units.isEmpty)

        // Another thread in the folder gets a book of its own from the diff already read.
        review.look(at: Self.root, for: UUID())
        try await model.take(same, in: Self.root)
        #expect(review.book.units.count == 1)
        #expect(review.diff?.mark == "one")

        // A diff that moved is built.
        try await model.take(read("let a = 2", mark: "two"), in: Self.root)
        #expect(review.diff?.mark == "two")
        #expect(review.book.units.first?.lines.contains { $0.text == "let a = 2" } == true)
    }

    @Test func aCircleMovesOnAndFoldsWhatItLeaves() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = AppModel(container: container)
        let review = model.review
        review.marks = ReviewMarks(file: FileManager.default.temporaryDirectory.appending(path: "oricode-marks-\(UUID().uuidString).json"))
        let found = provenance([
            user("One"), edit("a.swift", ["+let a = 1", "+let a = 2"]), edit("b.swift", ["+let b = 1"]),
            user("Two"), edit("c.swift", ["+let c = 1"]), edit("d.swift", ["+let d = 1"]), edit("e.swift", ["+let e = 1"]),
        ])
        let diff = WorkingDiff(root: Self.root, head: "abc", files: [
            file("a.swift", [hunk(["+let a = 1"]), hunk(["+let a = 2"], at: 20)]),
            file("b.swift", [hunk(["+let b = 1"])]),
            file("c.swift", [hunk(["+let c = 1"])]),
            file("d.swift", [hunk(["+let d = 1"])]),
            file("e.swift", [hunk(["+let e = 1"])]),
        ])
        review.diff = diff
        review.base = ReviewBook(diff: diff, provenance: found)
        model.applyMarks()
        review.placeFiles()
        let sections = review.book.chapters.flatMap(\.files).map(\.id)
        let unit = { (index: Int) in review.book.units[index] }
        #expect(review.openFiles == [sections[0]])

        // A hunk's circle goes on to the file's next hunk.
        model.toggleReviewed(unit(0))
        #expect(review.selected == unit(1).id)
        #expect(review.openFiles == [sections[0]])

        // Finishing a.swift with a note being written on its first hunk lets the note go with it.
        review.unfolded.insert(unit(0).id)
        review.noting = unit(0).id
        model.toggleReviewed(unit(1))
        #expect(review.selected == unit(2).id)
        #expect(review.openFiles == [sections[1]])
        #expect(review.noting == nil)

        // Finishing the first turn folds it and opens only the next file, not the one that took
        // the finished hunk's place in the list.
        model.toggleReviewed(unit(2))
        #expect(review.selected == unit(3).id)
        #expect(review.openFiles == [sections[2]])

        // A file's circle folds its file and the one the keyboard was in, and opens the next.
        review.toggle(review.book.chapters[1].files[1])
        #expect(review.openFiles == [sections[2], sections[3]])
        model.toggleReviewed(review.book.chapters[1].files[1])
        #expect(unit(4).reviewed)
        #expect(review.selected == unit(5).id)
        #expect(review.openFiles == [sections[4]])

        // Pressed again, it unmarks the file and leaves the keyboard where it is.
        model.toggleReviewed(review.book.chapters[1].files[1])
        #expect(!unit(4).reviewed)
        #expect(review.selected == unit(5).id)
        #expect(review.openFiles == [sections[4]])
    }
}

