import Foundation
import SwiftData
import Testing
@testable import OriCode

/// An edit's card in the transcript while Witness is the review: the numbers its diff keeps,
/// what the card lays out of it, and the change the review opens on from its header.
@MainActor
struct WitnessCardTests {
    private static let root = "/work/repo"

    private func edit(_ hunks: [Hunk], path: String = "a.swift") -> ToolCall {
        ToolCall(toolUseId: "e", name: "Edit", input: ["file_path": .string(Self.root + "/" + path)], result: "ok", patch: hunks)
    }

    // MARK: The diff's numbers

    @Test func aReportedEditKeepsEachLinesNumberAndTheNextHunksStarts() throws {
        let diff = try #require(Diff.of(edit([
            Hunk(oldStart: 211, newStart: 211, lines: [" let right = side == .right", "-let clear = shown && !pinned && !beside", "+let clear = shown && !pinned", " return clear"]),
            Hunk(oldStart: 300, newStart: 299, lines: ["+let more = true", "\\ No newline at end of file"]),
        ]), cwd: Self.root))
        #expect(diff.path == "a.swift")
        #expect(diff.lines.map(\.old) == [211, 212, nil, 213, 300, nil])
        #expect(diff.lines.map(\.new) == [211, nil, 212, 213, 299, 299])
        #expect(diff.lines[4].kind == .gap)
        #expect(diff.added == 2)
        #expect(diff.deleted == 1)
        #expect(diff.line == 212)

        let hunks = diff.hunks
        #expect(hunks.map(\.count) == [4, 1])
        #expect(hunks[0].map(\.kind) == [.context, .deleted, .added, .context])
        #expect(hunks[0][1].old == 212)
        #expect(hunks[0][1].new == nil)
        #expect(hunks[1][0].new == 299)
    }

    @Test func aPatchWithoutItsStartsAndAnEditNotYetMadeHaveNoNumbers() throws {
        let bare = try #require(Diff.of(edit([Hunk(oldStart: 0, newStart: 0, lines: ["-a", "+b"])]), cwd: Self.root))
        #expect(bare.lines.allSatisfy { $0.old == nil && $0.new == nil })
        #expect(bare.line == 0)
        #expect(WitnessDiff.lay(bare, rows: 12).digits == 0)

        let asked = try #require(Diff.of(tool: "Edit", input: ["file_path": "/work/repo/a.swift", "old_string": "one\ntwo", "new_string": "one\n2"], cwd: Self.root))
        #expect(asked.lines.allSatisfy { $0.old == nil && $0.new == nil })
        #expect(asked.deleted == 1)
    }

    @Test func aWrittenFilesLinesAreTheFilesOwn() throws {
        let written = try #require(Diff.of(tool: "Write", input: ["file_path": "/work/repo/new.swift", "content": "import Foundation\n\nlet a = 1"], cwd: Self.root))
        #expect(written.lines.map(\.new) == [1, 2, 3])
        #expect(written.line == 1)
        // A new file reported by its agent starts at line 1 of nothing.
        let reported = try #require(Diff.of(edit([Hunk(oldStart: 0, newStart: 1, lines: ["+hello", "+world"])]), cwd: Self.root))
        #expect(reported.lines.map(\.new) == [1, 2])
    }

    @Test func provenanceReadsAnEditAsItDid() {
        let call = edit([Hunk(oldStart: 4, newStart: 4, lines: [" keep()", "-two", "+2"]), Hunk(oldStart: 9, newStart: 9, lines: ["+ten"])])
        let found = Provenance(items: [.user(id: UUID(), text: "Do it"), .tool(id: UUID(), call: call)]) { RepoPath.relative($0, cwd: Self.root, root: Self.root) }
        #expect(found.turn(of: "+2", in: "a.swift") == 1)
        #expect(found.turn(of: "-two", in: "a.swift") == 1)
        #expect(found.turn(of: "+ten", in: "a.swift") == 1)
        #expect(found.turn(of: "+keep()", in: "a.swift") == nil)
    }

    // MARK: What the card lays out

    @Test func theCardShowsTwelveLinesAndCountsTheRest() throws {
        let twenty = (1...20).map { "+let value\($0) = \($0)" }
        let laid = WitnessDiff.lay(try #require(Diff.of(edit([Hunk(oldStart: 90, newStart: 90, lines: [" before()"] + twenty)]), cwd: Self.root)), rows: 12)
        #expect(laid.hunks.count == 1)
        #expect(laid.hunks[0].pieces == [.lines(0..<12, wraps: false)])
        #expect(laid.more == 9)
        // Its last number is 110: three digits, whatever the card shows.
        #expect(laid.digits == 3)

        // Thirteen lines are all drawn: the thirteenth takes the row that would have counted it.
        let thirteen = WitnessDiff.lay(try #require(Diff.of(edit([Hunk(oldStart: 1, newStart: 1, lines: Array(twenty.prefix(13)))]), cwd: Self.root)), rows: 12)
        #expect(thirteen.hunks[0].pieces == [.lines(0..<13, wraps: false)])
        #expect(thirteen.more == 0)

        let short = WitnessDiff.lay(try #require(Diff.of(edit([Hunk(oldStart: 1, newStart: 1, lines: ["-a", "+b"])]), cwd: Self.root)), rows: 12)
        #expect(short.more == 0)
        #expect(short.digits == 1)
    }

    @Test func aLaterHunkSaysItsPlaceAndOnePastTheTwelveIsCounted() throws {
        let diff = try #require(Diff.of(edit([
            Hunk(oldStart: 10, newStart: 10, lines: [" a()", "-let b = 0", "+let b = 1", " c()"]),
            Hunk(oldStart: 88, newStart: 88, lines: [" d()"] + (1...10).map { "+let e\($0) = \($0)" }),
            Hunk(oldStart: 200, newStart: 210, lines: ["+let f = 2"]),
        ]), cwd: Self.root))
        let laid = WitnessDiff.lay(diff, rows: 12)
        #expect(laid.hunks.map(\.place) == [nil, "lines 89–98"])
        #expect(laid.hunks[1].pieces == [.lines(0..<8, wraps: false)])
        #expect(laid.more == 4)

        let whole = WitnessDiff.lay(diff, rows: nil)
        #expect(whole.hunks.map(\.place) == [nil, "lines 89–98", "line 210"])
        #expect(whole.more == 0)
    }

    @Test func theOldLineIsOverItsNewOneWithTheWordsThatWent() throws {
        let diff = try #require(Diff.of(edit([Hunk(oldStart: 212, newStart: 212, lines: [
            "-let clear = model.drawerShown && !model.drawerPinned && !(beside != nil && right)",
            "+let clear = model.drawerShown && !model.drawerPinned",
        ])]), cwd: Self.root))
        let hunk = try #require(WitnessDiff.lay(diff, rows: 12).hunks.first)
        #expect(hunk.lines.map(\.kind) == [.deleted, .added])
        let old = Array(hunk.lines[0].text)
        let went = (hunk.words[0] ?? []).map { String(old[$0]) }.joined()
        #expect(went.contains("beside") && went.contains("right"))
        #expect(!went.contains("drawerPinned"))
        #expect(hunk.words[1] == nil)
    }

    @Test func aLongRemovalIsOneRowOnTheCardAndDrawnWholeInAnAsk() throws {
        let gone = (1...9).map { "-let gone\($0) = \($0)" }
        let diff = try #require(Diff.of(edit([Hunk(oldStart: 5, newStart: 5, lines: [" keep()"] + gone + [" after()"])]), cwd: Self.root))
        let card = WitnessDiff.lay(diff, rows: 12)
        #expect(card.hunks[0].pieces == [.lines(0..<1, wraps: false), .removal(1..<10), .lines(10..<11, wraps: false)])
        #expect(card.more == 0)
        let ask = WitnessDiff.lay(diff, rows: nil)
        #expect(ask.hunks[0].pieces == [.lines(0..<11, wraps: false)])
    }

    @Test func anAsksLongLineWrapsAndACardsIsOneRow() throws {
        let long = "let ok = verify(token) " + String(repeating: "/* padding */ ", count: 6) + "|| user.isAdmin"
        let diff = try #require(Diff.of(tool: "Edit", input: ["file_path": "/work/repo/a.swift", "old_string": "keep()\nlet ok = verify(token)", "new_string": .string("keep()\n" + long)], cwd: Self.root))
        let ask = WitnessDiff.lay(diff, rows: nil, columns: 60)
        #expect(ask.hunks[0].pieces == [.lines(0..<2, wraps: false), .lines(2..<3, wraps: true)])
        #expect(WitnessDiff.lay(diff, rows: nil, columns: 200).hunks[0].pieces == [.lines(0..<3, wraps: false)])
        #expect(WitnessDiff.lay(diff, rows: 12).hunks[0].pieces == [.lines(0..<3, wraps: false)])
    }

    @Test func aCardsRowIsCutWhereNoCardReachesAndNeverBreaks() {
        let plain = ReviewLine(kind: .added, text: "\tlet a = 1", old: nil, new: 4)
        #expect(WitnessDiff.row(plain) == plain)
        let minified = WitnessDiff.row(ReviewLine(kind: .added, text: String(repeating: "a", count: 300_000), old: nil, new: 1))
        #expect(minified.text.count == WitnessDiff.widest)
        #expect(minified.new == 1)
        let broken = WitnessDiff.row(ReviewLine(kind: .deleted, text: "one\u{2028}two\u{0C}three\rfour\r", old: 7, new: nil))
        #expect(broken.text == "one two three four")
        #expect(broken.old == 7)
        #expect(WitnessDiff.row(ReviewLine(kind: .context, text: "let ş = \"ğ\"", old: 1, new: 1)).text == "let ş = \"ğ\"")
    }

    @Test func aCardPairsWordsWithinItsBudgetAndDrawsWhatItCouldNotPair() throws {
        // Two hundred lines replaced by two hundred: more to pair than a card will in a frame.
        let old = (1...200).map { "-let value\($0) = compute(\($0), with: options, for: thread, in: folder) // was \($0)" }
        let new = (1...200).map { "+let value\($0) = compute(\($0), with: options, for: thread, in: folder) // now \($0)" }
        let big = try #require(Diff.of(edit([Hunk(oldStart: 1, newStart: 1, lines: [" keep()"] + old + new)]), cwd: Self.root))
        let laid = WitnessDiff.lay(big, rows: 12)
        #expect(laid.hunks[0].words.isEmpty)
        #expect(laid.hunks[0].pieces == [.lines(0..<12, wraps: false)])
        #expect(laid.more == 389)

        // A removal before the run that was too much is folded as the review folds it, and the
        // run itself, of which nothing is known, is drawn.
        let gone = (1...9).map { "-let gone\($0) = \($0)" }
        let mixed = try #require(Diff.of(edit([Hunk(oldStart: 1, newStart: 1, lines: gone + [" keep()"] + old + new)]), cwd: Self.root))
        #expect(WitnessDiff.lay(mixed, rows: 12).hunks[0].pieces == [.removal(0..<9), .lines(9..<20, wraps: false)])

        // A later hunk isn't paired once one has gone without.
        let two = try #require(Diff.of(edit([Hunk(oldStart: 1, newStart: 1, lines: Array(old.prefix(100)) + Array(new.prefix(100))), Hunk(oldStart: 900, newStart: 900, lines: ["-let a = 0", "+let a = 1"])]), cwd: Self.root))
        #expect(WitnessDiff.lay(two, rows: 300).hunks.map(\.words.isEmpty) == [true, true])

        var budget = 100
        let lines = ReviewBook.lines(of: DiffHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, context: "", lines: ["-let a = 0", "+let a = 1", " keep()", "-let b = [" + String(repeating: "1, ", count: 23) + "0]", "+let b = [" + String(repeating: "1, ", count: 23) + "9]"]))
        let found = WordDiff.ranges(in: lines, spending: &budget)
        #expect(found.known == 3)
        #expect(found.words[0] != nil)
        #expect(found.words[3] == nil)
        #expect(budget == 82)
        #expect(WordDiff.ranges(in: lines)[3] != nil)
    }

    @Test func aLaterHunkOfAnEditWithoutNumbersIsPartedByTheGapsMark() throws {
        let diff = try #require(Diff.of(edit([Hunk(oldStart: 0, newStart: 0, lines: ["-a", "+b"]), Hunk(oldStart: 0, newStart: 0, lines: ["-c", "+d"])]), cwd: Self.root))
        #expect(WitnessDiff.lay(diff, rows: 12).hunks.map(\.place) == [nil, "⋯"])
    }

    @Test func theRowsAskedForStopThePieces() {
        let lines = ReviewBook.lines(of: DiffHunk(oldStart: 1, oldLines: 0, newStart: 1, newLines: 0, context: "", lines: (1...30).map { "+let a\($0) = \($0)" }))
        #expect(WitnessHunk.pieces(lines, words: [:], opened: false, whole: true, columns: 80, rows: 5) == [.lines(0..<5, wraps: false)])
        #expect(WitnessHunk.pieces(lines, words: [:], opened: false, whole: true, columns: 80) == [.lines(0..<30, wraps: false)])
    }

    // MARK: The review opened from a card

    private func model() throws -> AppModel {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = AppModel(container: container)
        model.review.marks = ReviewMarks(file: FileManager.default.temporaryDirectory.appending(path: "oricode-marks-\(UUID().uuidString).json"))
        model.review.design = .witness
        model.review.look(at: Self.root, for: nil)
        return model
    }

    private func reply(_ files: [(path: String, starts: [Int])], mark: String) -> JSON {
        let files = files.map { file -> JSON in
            let hunks = file.starts.map { start -> JSON in
                ["oldStart": .number(Double(start)), "oldLines": 1, "newStart": .number(Double(start)), "newLines": 1, "context": "",
                 "lines": [.string("-let a\(start) = 0"), .string("+let a\(start) = 1")]]
            }
            return [
                "path": .string(file.path), "oldPath": nil, "status": "M", "binary": false, "executable": false, "hunks": .array(hunks),
                "added": 1, "deleted": 1, "cut": false, "stamp": nil, "lossy": false, "changedAt": 1_800_000_001_000,
            ]
        }
        return ["root": .string(Self.root), "head": "abc", "headAt": 1_800_000_000_000, "mark": .string(mark), "files": .array(files)]
    }

    @Test func aCardsHeaderPutsTheKeyboardOnItsFilesNearestChange() async throws {
        let model = try model()
        let review = model.review
        try await model.take(reply([("a.swift", [10]), ("b.swift", [20, 300, 900])], mark: "one"), in: Self.root)
        #expect(review.selected == nil)

        review.landing = (Self.root + "/b.swift", 310)
        #expect(model.land())
        let on = try #require(review.selectedUnit)
        #expect(on.file.path == "b.swift")
        #expect(on.hunk?.newStart == 300)
    }

    @Test func anEditMadeSinceTheLastReadIsLandedOnWhenTheReadBringsIt() async throws {
        let model = try model()
        let review = model.review
        // The book from the turn before: b.swift has one change, far from the edit clicked.
        try await model.take(reply([("b.swift", [20])], mark: "one"), in: Self.root)
        review.landing = (Self.root + "/b.swift", 900)
        #expect(model.land())
        #expect(review.selectedUnit?.hunk?.newStart == 20)
        #expect(review.landing != nil)

        try await model.take(reply([("b.swift", [20, 900])], mark: "two"), in: Self.root)
        #expect(review.selectedUnit?.hunk?.newStart == 900)
        #expect(review.landing == nil)

        // A later book moves the keyboard nowhere.
        review.move(-1)
        #expect(review.selectedUnit?.hunk?.newStart == 20)
        try await model.take(reply([("b.swift", [20, 900, 950])], mark: "three"), in: Self.root)
        #expect(review.selectedUnit?.hunk?.newStart == 20)
    }

    @Test func aFileTheBookDoesNotHaveYetIsLandedOnWhenTheReadBringsIt() async throws {
        let model = try model()
        let review = model.review
        try await model.take(reply([("a.swift", [10])], mark: "one"), in: Self.root)
        review.move(1)
        let first = review.selected

        review.landing = (Self.root + "/c.swift", 40)
        #expect(!model.land())
        #expect(review.selected == first)
        #expect(review.landing != nil)

        try await model.take(reply([("a.swift", [10]), ("c.swift", [5, 44])], mark: "two"), in: Self.root)
        #expect(review.selectedUnit?.file.path == "c.swift")
        #expect(review.selectedUnit?.hunk?.newStart == 44)
        #expect(review.landing == nil)

        // Put away with a card's file still waited for, the review forgets it.
        review.landing = (Self.root + "/gone.swift", 1)
        model.closeReview()
        #expect(review.landing == nil)
    }

    @Test func legacyIsNotLandedIn() async throws {
        let model = try model()
        model.review.design = .legacy
        try await model.take(reply([("a.swift", [10])], mark: "one"), in: Self.root)
        model.review.landing = (Self.root + "/a.swift", 10)
        #expect(!model.land())
        #expect(model.review.selected == nil)
    }
}
