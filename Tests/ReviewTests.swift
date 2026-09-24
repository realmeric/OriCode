import Foundation
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
    }

    @Test func crlfLinesSplitWhereTheFileDoes() {
        let lines = AttributedString("one\r\ntwo\r\nthree").lines()
        #expect(lines.map { String($0.characters) } == ["one\r", "two\r", "three"])
    }
}

