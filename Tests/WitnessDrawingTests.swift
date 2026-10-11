import Foundation
import SwiftData
import Testing
@testable import OriCode

/// What Witness draws of a hunk and how its keyboard walks, on books made here: no git, no engine.
@MainActor
struct WitnessDrawingTests {
    private static let root = "/work/repo"

    private func lines(_ signed: [String], at start: Int = 1) -> [ReviewLine] {
        ReviewBook.lines(of: DiffHunk(oldStart: start, oldLines: 0, newStart: start, newLines: 0, context: "", lines: signed))
    }

    private func pieces(_ signed: [String], opened: Bool = false, whole: Bool = false, columns: Int = 80) -> [WitnessHunk.Piece] {
        let lines = lines(signed)
        return WitnessHunk.pieces(lines, words: WordDiff.ranges(in: lines), opened: opened, whole: whole, columns: columns)
    }

    private func model() throws -> AppModel {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = AppModel(container: container)
        model.review.marks = ReviewMarks(file: FileManager.default.temporaryDirectory.appending(path: "oricode-marks-\(UUID().uuidString).json"))
        model.review.design = .witness
        model.review.look(at: Self.root, for: nil)
        return model
    }

    /// A reply whose files have a hunk for each list of lines, starting where it says.
    private func reply(_ files: [(path: String, hunks: [(start: Int, lines: [String])])], mark: String) -> JSON {
        let files = files.map { file -> JSON in
            let hunks = file.hunks.map { hunk -> JSON in
                let old = hunk.lines.count { !$0.hasPrefix("+") }, new = hunk.lines.count { !$0.hasPrefix("-") }
                return ["oldStart": .number(Double(hunk.start)), "oldLines": .number(Double(old)), "newStart": .number(Double(hunk.start)),
                        "newLines": .number(Double(new)), "context": "", "lines": .array(hunk.lines.map(JSON.string))]
            }
            return [
                "path": .string(file.path), "oldPath": nil, "status": "M", "binary": false, "executable": false, "hunks": .array(hunks),
                "added": 1, "deleted": 1, "cut": false, "stamp": nil, "lossy": false, "changedAt": 1_800_000_001_000,
            ]
        }
        return ["root": .string(Self.root), "head": "abc", "headAt": 1_800_000_000_000, "mark": .string(mark), "files": .array(files)]
    }

    private func change(_ name: String) -> [String] { ["-let \(name) = 0", "+let \(name) = 1"] }

    // MARK: The hunk

    @Test func aRemovalOfSixLinesIsDrawnAndALongerOneIsARowUntilOpened() {
        let six = (1...6).map { "-let gone\($0) = \($0)" }
        #expect(pieces([" keep()"] + six + [" after()"]) == [.lines(0..<8, wraps: false)])
        let seven = six + ["-let gone7 = 7"]
        #expect(pieces([" keep()"] + seven + [" after()"]) == [.lines(0..<1, wraps: false), .removal(1..<8), .lines(8..<9, wraps: false)])
        #expect(pieces([" keep()"] + seven + [" after()"], opened: true) == [.lines(0..<9, wraps: false)])
    }

    @Test func anOldLineWhoseWordsWentIsDrawnAboveItsNewOneWhateverFollowsIt() {
        // The first old line was edited into the new one; the nine after it only went.
        let old = ["-if ready && open { go() }"] + (1...9).map { "-let gone\($0) = \($0)" }
        let found = pieces(old + ["+if ready { go() }"])
        #expect(found == [.lines(0..<1, wraps: false), .removal(1..<10), .lines(10..<11, wraps: false)])
        let lines = lines(old + ["+if ready { go() }"])
        #expect(WordDiff.ranges(in: lines)[0] != nil)
    }

    @Test func aFoldedRemovalIsNamedByItsFirstLineThatStartsNoComment() {
        let gone = lines(["-    // Checks the open thread.", "-    /// And the composer.", "-", "-    func composerShowsOpenThread() {", "-        #expect(true)", "-    }"])
        #expect(WitnessHunk.naming(gone[...]) == "func composerShowsOpenThread() {")
        #expect(WitnessHunk.naming(lines(["-# a note", "-#include <stdio.h>"])[...]) == "#include <stdio.h>")
        // Nothing but comments is named by the first of them.
        #expect(WitnessHunk.naming(lines(["-// one", "-// two"])[...]) == "// one")
    }

    @Test func aLineThatMayWrapStandsAloneSoTheNumbersAfterItStayBesideTheirLines() {
        let long = "+let text = \"" + String(repeating: "a", count: 90) + "\""
        #expect(pieces([" one()", long, " two()", " three()"]) == [.lines(0..<1, wraps: false), .lines(1..<2, wraps: true), .lines(2..<4, wraps: false)])
        // A character the code's font doesn't have comes from another at a width of its own.
        #expect(!WitnessHunk.fits("let a = \"日本\"", columns: 80))
        #expect(!WitnessHunk.fits("let a = \"👍\"", columns: 80))
        #expect(WitnessHunk.fits("let a = 1", columns: 9))
        #expect(!WitnessHunk.fits("let a = 1", columns: 8))
    }

    @Test func aTabIndentedOrCRLFOrAccentedFileSharesItsTextsLikeAnyOther() {
        // Go's tabs, a Windows file's \r and a Turkish string: none of them a view a line.
        let go = [" func main() {\r", "-\tif ready && open {\r", "+\tif ready {\r", " \t\tname := \"ışık, değer\"\r", " \t}\r"]
        #expect(pieces(go) == [.lines(0..<5, wraps: false)])
        #expect(WitnessHunk.drawn("\tif a {\r") == "    if a {")
        #expect(WitnessHunk.drawn("ab\tc\t\td") == "ab  c       d")
        #expect(WitnessHunk.fits(lines(["+\t\tx"])[0], columns: 9) && !WitnessHunk.fits(lines(["+\t\tx"])[0], columns: 8))
        // The words WordDiff found are washed where the spaces put them.
        let lines = lines(go)
        let words = WordDiff.ranges(in: lines)[1]!
        let washed = WitnessHunk.drawn(words, of: lines[1].text).map { range -> String in
            let drawn = Array(WitnessHunk.drawn(lines[1].text))
            return String(drawn[range])
        }
        #expect(washed.joined().contains("&& open"))
        #expect(WitnessHunk.drawn([1..<3], of: "\tab") == [4..<6])
    }

    @Test func aLastLineWithNoNewlineLeavesRoomForItsMark() {
        var last = lines(["-let a = 1"])[0]
        #expect(WitnessHunk.fits(last, columns: 9))
        last.noNewline = true
        #expect(!WitnessHunk.fits(last, columns: 9 + WitnessHunk.noNewlineColumns - 1))
        #expect(WitnessHunk.fits(last, columns: 9 + WitnessHunk.noNewlineColumns))
    }

    @Test func aRemovedLineSeenBeforeIsStillRedAndNeverReadsAsCodeThatIsThere() async throws {
        let model = try model()
        let review = model.review
        let first = ["-        return nil", "+        return value"]
        try await model.take(reply([("F.swift", [(10, first)])], mark: "one"), in: Self.root)
        model.setReviewed([review.book.units[0]], true)
        // The agent edits that hunk again, and removes the same line in a second one.
        try await model.take(reply([("F.swift", [
            (10, first + ["+        log(value)"]), (200, [" func other() {", "-        return nil", " }"]),
        ])], mark: "two"), in: Self.root)
        let units = review.book.units
        #expect(units.count == 2 && units.allSatisfy { $0.changedSince && !$0.reviewed })
        let context = units[1].lines[0], gone = units[1].lines[1]
        #expect(gone.seen && gone.kind == .deleted)
        #expect(WitnessHunk.ink(gone) == Ink.deleted.opacity(0.6))
        #expect(WitnessHunk.ink(gone) != WitnessHunk.ink(context))
        #expect(WitnessHunk.numberInk(gone, reviewed: false) != WitnessHunk.numberInk(context, reviewed: false))
        // An added line seen before is as quiet as the code around it, and its number still says it was added.
        let again = units[0].lines[1], fresh = units[0].lines[2]
        #expect(again.seen && !fresh.seen)
        #expect(WitnessHunk.ink(again) == Ink.secondary && WitnessHunk.ink(fresh) == Ink.primary)
        #expect(WitnessHunk.numberInk(again, reviewed: false) == Ink.added.opacity(0.6))
        #expect(WitnessHunk.numberInk(fresh, reviewed: false) == Ink.added)
        // Marked reviewed, every number dims and a removed line stays red.
        #expect(WitnessHunk.numberInk(fresh, reviewed: true) == Ink.secondary)
        #expect(WitnessHunk.ink(units[0].lines[0]) == Ink.deleted.opacity(0.6))
    }

    @Test func aHunkPastFourHundredLinesShowsItsStartUntilAsked() {
        let fresh = (1...450).map { "+let line\($0) = \($0)" }
        #expect(pieces(fresh) == [.lines(0..<200, wraps: false)])
        #expect(pieces(fresh, whole: true) == [.lines(0..<450, wraps: false)])
        // A long removal across the cut is one row that counts every line that went.
        let gone = (1...450).map { "-let line\($0) = \($0)" }
        #expect(pieces([" keep()"] + gone + [" after()"]) == [.lines(0..<1, wraps: false), .removal(1..<451)])
        // Opened, it is cut where any hunk is.
        #expect(pieces([" keep()"] + gone + [" after()"], opened: true) == [.lines(0..<200, wraps: false)])
    }

    @Test func oneNumberColumnIsAsWideAsThePagesLongestNumber() async throws {
        let model = try model()
        try await model.take(reply([("a.swift", [(8, change("a"))]), ("b.swift", [(1412, change("b"))])], mark: "one"), in: Self.root)
        #expect(model.review.page.digits == 4)
        #expect(WitnessHunk.codeX(4) > WitnessHunk.codeX(2))
        #expect(WitnessHunk.line(of: model.review.book.units[1]) == 1412)
    }

    // MARK: The walk

    @Test func tabGoesByFileAndBackTabToTheTopOfThisOneFirst() async throws {
        let model = try model()
        let review = model.review
        try await model.take(reply([
            ("a.swift", [(1, change("a")), (100, change("b"))]),
            ("b.swift", [(1, change("c")), (100, change("d"))]),
            ("c.swift", [(1, change("e"))]),
        ], mark: "one"), in: Self.root)
        let units = review.visibleUnits
        review.walkFile(1)
        #expect(review.selected == units[0].id)
        review.walkFile(1)
        #expect(review.selected == units[2].id)
        review.move(1)
        review.walkFile(-1)
        #expect(review.selected == units[2].id)
        review.walkFile(-1)
        #expect(review.selected == units[0].id)
        review.walkFile(-1)
        #expect(review.selected == units[0].id)
        review.selected = units[3].id
        review.walkFile(1)
        #expect(review.selected == units[4].id)
        // Past the last file and before the first there is nowhere to walk, and the key is let go.
        #expect(!review.walkFile(1))
        #expect(review.selected == units[4].id)
        review.selected = units[0].id
        #expect(!review.walkFile(-1))
        #expect(review.walkFile(1))
    }

    @Test func spaceMarksAndWalksOnAndNothingFoldsOrCloses() async throws {
        let model = try model()
        let review = model.review
        let seven = (1...7).map { "-let gone\($0) = \($0)" }
        try await model.take(reply([("a.swift", [(1, seven), (100, change("b"))])], mark: "one"), in: Self.root)
        let units = review.visibleUnits
        review.select(units[0])
        #expect(review.opens(units[0]) && !review.opens(units[1]))
        review.open(true)
        #expect(review.unfolded.contains(units[0].id))
        model.toggleSelectedReviewed()
        // Reviewed, it is still on the page whole, its long removal as open as it was.
        #expect(review.book.units[0].reviewed)
        #expect(review.unfolded.contains(units[0].id))
        #expect(!review.folded(review.book.units[0]))
        #expect(review.visibleUnits.map(\.id) == units.map(\.id))
        #expect(review.selected == units[1].id)
        // In Legacy the same mark folds the hunk to a line.
        review.design = .legacy
        #expect(review.folded(review.book.units[0]) == false)
        review.unfolded = []
        #expect(review.folded(review.book.units[0]))
    }

    @Test func spaceOnTheLastChangeToReviewKeepsTheKeyboardOnIt() async throws {
        let model = try model()
        let review = model.review
        try await model.take(reply([("a.swift", [(1, change("a")), (100, change("b"))])], mark: "one"), in: Self.root)
        let units = review.visibleUnits
        model.setReviewed([units[0]], true)
        review.select(units[1])
        model.toggleSelectedReviewed()
        #expect(review.book.toReview == 0 && review.selected == units[1].id)
        // And Space again unmarks it there.
        model.toggleSelectedReviewed()
        #expect(review.book.toReview == 1 && review.selected == units[1].id)
    }

    @Test func aNoteBeingWrittenStaysWhenAMenuMovesTheKeyboardToAnotherFile() async throws {
        let model = try model()
        let review = model.review
        try await model.take(reply([("a.swift", [(1, change("a"))]), ("b.swift", [(1, change("b"))]), ("c.swift", [(1, change("c"))])], mark: "one"), in: Self.root)
        let units = review.visibleUnits
        model.note(on: units[0])
        // Mark Reviewed from the menu walks on to the next file; picking a file in the header does too.
        model.toggleReviewed(units[0])
        #expect(review.selected == units[1].id && review.noting == units[0].id)
        review.select(units[2])
        #expect(review.noting == units[0].id)
        // In Legacy the file folds as the keyboard leaves it, and its note goes with it.
        review.design = .legacy
        review.select(units[0])
        review.noting = units[0].id
        review.select(units[1])
        #expect(review.noting == nil)
    }

    @Test func aSpacingOnlyChangeThatIsReadSaysSoOverItsLines() async throws {
        let model = try model()
        let review = model.review
        let indent = ["-  key: value", "+    key: value"]
        try await model.take(reply([("conf.yml", [(1, indent)]), ("a.swift", [(1, ["-let a = 1", "+let  a = 1"])])], mark: "one"), in: Self.root)
        let yml = try #require(review.book.units.first { $0.file.path == "conf.yml" })
        let swift = try #require(review.book.units.first { $0.file.path == "a.swift" })
        // Where spacing is syntax the change is read, and its label is the caption's to say.
        #expect(!review.page.isQuiet(yml.id) && yml.labels.contains("spacing only"))
        // Elsewhere it is a quiet line that says it, and the line is what the caption leaves out.
        #expect(review.page.isQuiet(swift.id) && review.page.quiet.first?.what == "spacing only")
    }

    @Test func shiftSpaceMarksTheFileAndGoesToTheNextNotReviewed() async throws {
        let model = try model()
        let review = model.review
        try await model.take(reply([
            ("a.swift", [(1, change("a")), (100, change("b"))]),
            ("b.swift", [(1, change("c"))]),
        ], mark: "one"), in: Self.root)
        let units = review.visibleUnits
        review.select(units[1])
        model.toggleFileReviewed()
        #expect(review.book.units.filter(\.reviewed).map(\.file.path) == ["a.swift", "a.swift"])
        #expect(review.selected == units[2].id)
        // On a file all marked, it unmarks them.
        review.select(units[0])
        model.toggleFileReviewed()
        #expect(review.book.toReview == 3)
    }

    @Test func aClickInTheNumberColumnMarksAndUnmarksWithoutWalkingOn() async throws {
        let model = try model()
        let review = model.review
        try await model.take(reply([("a.swift", [(1, change("a")), (100, change("b"))])], mark: "one"), in: Self.root)
        let unit = review.visibleUnits[1]
        model.markByClick(unit)
        #expect(review.book.units[1].reviewed && review.selected == unit.id)
        model.markByClick(review.book.units[1])
        #expect(!review.book.units[1].reviewed && review.selected == unit.id)
    }

    @Test func escClosesANoteThenWhatWasOpenedThenTheReview() async throws {
        let model = try model()
        let review = model.review
        let seven = (1...7).map { "-let gone\($0) = \($0)" }
        try await model.take(reply([("a.swift", [(1, seven)])], mark: "one"), in: Self.root)
        model.reviewShown = true
        review.select(review.visibleUnits[0])
        review.open(true)
        model.note(on: review.visibleUnits[0])
        #expect(model.escape())
        #expect(review.noting == nil && review.unfolded.count == 1 && model.reviewShown)
        #expect(model.escape())
        #expect(review.unfolded.isEmpty && model.reviewShown)
        #expect(model.escape())
        #expect(!model.reviewShown)
    }

    // MARK: The place

    @Test func afterAReadTheKeyboardGoesToTheNearestChangeInItsFile() async throws {
        let model = try model()
        let review = model.review
        try await model.take(reply([
            ("a.swift", [(1, change("a"))]),
            ("b.swift", [(10, change("b")), (200, change("c")), (400, change("d"))]),
            ("c.swift", [(1, change("e"))]),
        ], mark: "one"), in: Self.root)
        review.select(review.visibleUnits.first { $0.hunk?.newStart == 200 })
        // The agent edits that change again: it comes back as another hunk, three lines down.
        try await model.take(reply([
            ("a.swift", [(1, change("a"))]),
            ("b.swift", [(10, change("b")), (203, ["-let c = 0", "+let c = 2"]), (400, change("d"))]),
            ("c.swift", [(1, change("e"))]),
        ], mark: "two"), in: Self.root)
        #expect(review.selectedUnit?.hunk?.newStart == 203)
        #expect(review.place == ReviewPlace(path: "b.swift", line: 200))
        // Its file gone from the diff, the change that took its place in the order.
        try await model.take(reply([("a.swift", [(1, change("a"))]), ("c.swift", [(1, change("e"))])], mark: "three"), in: Self.root)
        #expect(review.selectedUnit?.file.path == "c.swift")
    }

    @Test func legacyKeepsNoPlace() async throws {
        let model = try model()
        let review = model.review
        review.design = .legacy
        try await model.take(reply([("a.swift", [(1, change("a")), (100, change("b"))])], mark: "one"), in: Self.root)
        review.select(review.book.units[1])
        try await model.take(reply([("a.swift", [(1, change("a")), (100, change("b"))])], mark: "two"), in: Self.root)
        #expect(review.place == nil)
    }

    // MARK: What opens, and what it says

    @Test func withNothingChosenTheReviewIsWitness() {
        // The test host's own defaults, put back after: what's stored there decides, and unset is Witness.
        let stored = UserDefaults.standard.string(forKey: ReviewDesign.key)
        UserDefaults.standard.removeObject(forKey: ReviewDesign.key)
        defer { UserDefaults.standard.set(stored, forKey: ReviewDesign.key) }
        #expect(ReviewDesign.chosen == .witness)
        UserDefaults.standard.set("legacy", forKey: ReviewDesign.key)
        #expect(ReviewDesign.chosen == .legacy)
    }

    @Test func theShortcutsSheetsReviewRowsAreTheChosenReviews() {
        let witness = ShortcutList.groups(review: .witness).last!, legacy = ShortcutList.groups(review: .legacy).last!
        #expect(witness.title == "Review" && legacy.title == "Review")
        #expect(witness.rows.map(\.title).contains("Next and previous file"))
        #expect(legacy.rows == [
            .fixed("Next and previous hunk", keys: "↓ ↑  or  J K"), .fixed("Fold or open the file", keys: "← →"),
            .fixed("Mark reviewed, then the next", keys: "Space"), .fixed("Add a note", keys: "N"), .fixed("Take it back", keys: "⌫"),
            .fixed("Undo that", keys: "⌘Z"), .fixed("Open the file", keys: "O"), .fixed("Commit", keys: "⌘Return"),
        ])
    }

    @Test func theCommitButtonNamesWhatItTakesAndLegacysSaysWhatItDid() async throws {
        let model = try model()
        let review = model.review
        try await model.take(reply([("a.swift", [(1, change("a")), (100, change("b"))]), ("b.swift", [(1, change("c"))])], mark: "one"), in: Self.root)
        #expect(ReviewFooter.commitTitle(review.book, in: .witness) == "Commit 2 Files")
        #expect(ReviewFooter.commitTitle(review.book, in: .legacy) == "Commit")
        model.setReviewed([review.book.units[0]], true)
        #expect(ReviewFooter.commitTitle(review.book, in: .witness) == "Commit 1 Reviewed")
        #expect(ReviewFooter.commitTitle(review.book, in: .legacy) == "Commit Reviewed")
    }

    @Test func theHeadersMenuNamesTheKeyboardsFileAmongThePages() async throws {
        let model = try model()
        let review = model.review
        try await model.take(reply([
            ("App/a.swift", [(1, change("a"))]), ("App/b.swift", [(1, ["-if ready && open { go() }", "+if ready { go() }"]), (100, change("b"))]),
        ], mark: "one"), in: Self.root)
        // b.swift has a line first and a line below, and is one file in the menu.
        let files = review.page.files
        #expect(files.map(\.file.path) == ["App/b.swift", "App/a.swift"])
        #expect(WitnessHeader.place(of: nil, in: files) == (nil, "2 files"))
        #expect(WitnessHeader.place(of: review.book.units.first { $0.file.path == "App/a.swift" }, in: files) == ("a.swift", "2 of 2"))
    }

    @Test func aTurnIsNamedByItsMessagesFirstWords() {
        let long = ReviewChapter(turn: 3, prompt: "Put a composer under each thread, with its own draft and queue\nand more", files: [])
        #expect(AppModel.turnName(long) == "Put a composer under each thread, with its own…")
        #expect(AppModel.turnName(ReviewChapter(turn: 1, prompt: "Fix it", files: [])) == "Fix it")
        #expect(AppModel.turnName(ReviewChapter(turn: nil, prompt: nil, files: [])) == "Changes no edit here made")
    }
}
