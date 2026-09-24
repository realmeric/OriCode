import Foundation

/// A line of a hunk as the review draws it.
struct ReviewLine: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case context, added, deleted
    }

    let kind: Kind
    let text: String
    /// Its number in HEAD's file and in the working tree's.
    let old: Int?
    let new: Int?
    /// The file ends without a newline after it.
    var noNewline = false
    /// A changed line no edit of the thread's made, in a hunk one of them did.
    var foreign = false
    /// There when you last marked the hunk reviewed, before it changed again.
    var seen = false
    /// Part of a block that moved here from elsewhere, or away from here, unchanged.
    var moved = false

    /// The line as git's diff spells it, sign first.
    var signed: String {
        switch kind {
        case .context: " " + text
        case .added: "+" + text
        case .deleted: "-" + text
        }
    }
}

/// What the review marks and takes back: one hunk, or a whole file when that's all there is to
/// show (binary, too large, or a change with no lines, like a mode or a pure rename).
struct ReviewUnit: Identifiable, Hashable, Sendable {
    let id: String
    let file: FileDiff
    let hunk: DiffHunk?
    let fingerprint: String
    /// What its colours are cached by: every line, context too, since two hunks can make the
    /// same change among different lines.
    let colourKey: String
    var lines: [ReviewLine]
    /// The turn whose edits made it; nil when none did.
    let turn: Int?
    var reviewed = false
    /// Reviewed once, then changed: its seen lines are the ones you looked at.
    var changedSince = false
    /// Nothing but spacing changed.
    let whitespaceOnly: Bool
    /// What the signals found: a move, a test's expectation changed, a lockfile.
    var labels: [String] = []
    /// The words that changed inside its changed lines, by line.
    var words: [Int: [Range<Int>]] = [:]

    /// A lockfile's hunk starts folded, like a reviewed one, and says what it is.
    var lockfile: Bool { Signals.isLockfile(file.path) }

    var added: Int { hunk == nil ? file.added : lines.count { $0.kind == .added } }
    var deleted: Int { hunk == nil ? file.deleted : lines.count { $0.kind == .deleted } }

    /// The file section it's shown under: its turn's changes to its file.
    var section: String { "\(turn ?? 0)/\(file.status)/\(file.path)" }
}

struct ReviewFileSection: Identifiable, Hashable, Sendable {
    let id: String
    let file: FileDiff
    var units: [ReviewUnit]
}

/// A turn's changes under the message that asked for them, or the changes no edit here made.
struct ReviewChapter: Identifiable, Hashable, Sendable {
    /// nil for the changes no edit of the thread's made.
    let turn: Int?
    let prompt: String?
    /// The builds and tests the turn ran, last run of each command.
    var checks: [Provenance.Check] = []
    var files: [ReviewFileSection]

    var id: String { turn.map { "turn-\($0)" } ?? "other" }
    var units: [ReviewUnit] { files.flatMap(\.units) }
}

/// A mark left by marking something reviewed: the lines it changed then, so that when it
/// changes again the review can show what's new since.
struct ReviewMark: Codable, Hashable, Sendable {
    let path: String
    let lines: [String]
    let at: Date
}

/// The working tree's diff told as the thread's story: its turns in order, each under your
/// message, each file in the order the turn first edited it, and whatever no edit made after.
struct ReviewBook: Sendable {
    var chapters: [ReviewChapter] = []
    /// Whether the thread made any edit at all; if not, there's no story to tell apart from.
    var threadEdited = false

    var units: [ReviewUnit] { chapters.flatMap(\.units) }
    var added: Int { chapters.flatMap(\.files).reduce(0) { $0 + $1.units.reduce(0) { $0 + $1.added } } }
    var deleted: Int { chapters.flatMap(\.files).reduce(0) { $0 + $1.units.reduce(0) { $0 + $1.deleted } } }
    var toReview: Int { units.count { !$0.reviewed } }

    init() {}

    /// The book without marks: what a read of the diff has to work out once.
    init(diff: WorkingDiff, provenance: Provenance) {
        threadEdited = !provenance.isEmpty
        var units = diff.files.flatMap { Self.units(of: $0, provenance: provenance) }
        Signals.findMoves(in: &units)
        for index in units.indices {
            units[index].words = WordDiff.ranges(in: units[index].lines)
            units[index].labels += Signals.testLabels(units[index])
            if units[index].whitespaceOnly { units[index].labels.append("spacing only") }
            if units[index].lockfile { units[index].labels.append("lockfile") }
        }
        // A file is known by its path and status together: git can list one path twice, deleted
        // from the index and back on disk untracked.
        var byTurn: [Int?: [String: ReviewFileSection]] = [:]
        for unit in units {
            let file = unit.file
            let key = file.path + "\u{0}" + file.status
            byTurn[unit.turn, default: [:]][key, default: ReviewFileSection(id: unit.section, file: file, units: [])]
                .units.append(unit)
        }
        let order = Dictionary(diff.files.enumerated().map { ($1.path + "\u{0}" + $1.status, $0) }) { first, _ in first }
        chapters = byTurn.keys.sorted { ($0 ?? .max) < ($1 ?? .max) }.map { turn in
            let files = byTurn[turn]!.values.sorted { a, b in
                if let turn {
                    let (x, y) = (provenance.rank(of: a.file.path, in: turn), provenance.rank(of: b.file.path, in: turn))
                    if x != y { return x < y }
                }
                return order[a.file.path + "\u{0}" + a.file.status, default: 0] < order[b.file.path + "\u{0}" + b.file.status, default: 0]
            }
            return ReviewChapter(
                turn: turn, prompt: turn.flatMap { provenance.prompts[$0] }, checks: turn.flatMap { provenance.checks[$0] } ?? [], files: files)
        }
    }

    /// The book with marks laid over it: which hunks are reviewed, and in a hunk that changed
    /// since it was, which lines you saw then. Marks of hunks no longer in the diff are what
    /// you saw of them.
    func marked(with marks: [String: ReviewMark]) -> ReviewBook {
        let current = Set(units.map(\.fingerprint))
        var stale: [String: Set<String>] = [:]
        for (fingerprint, mark) in marks where !current.contains(fingerprint) {
            stale[mark.path, default: []].formUnion(mark.lines.filter(Self.significant))
        }
        var book = self
        for c in book.chapters.indices {
            for f in book.chapters[c].files.indices {
                for u in book.chapters[c].files[f].units.indices {
                    var unit = book.chapters[c].files[f].units[u]
                    unit.reviewed = marks[unit.fingerprint] != nil
                    unit.changedSince = false
                    let seen = unit.reviewed ? [] : stale[unit.file.path] ?? []
                    for index in unit.lines.indices {
                        let line = unit.lines[index]
                        unit.lines[index].seen = line.kind != .context && seen.contains(line.signed)
                        if unit.lines[index].seen { unit.changedSince = true }
                    }
                    book.chapters[c].files[f].units[u] = unit
                }
            }
        }
        return book
    }

    static func units(of file: FileDiff, provenance: Provenance) -> [ReviewUnit] {
        guard !file.hunks.isEmpty, !file.binary, !file.cut else {
            return [ReviewUnit(
                id: file.path + "#" + file.status, file: file, hunk: nil, fingerprint: Fingerprint.of(file: file),
                colourKey: "", lines: [], turn: provenance.lastTurn(editing: file.path), whitespaceOnly: false)]
        }
        var occurrences: [String: Int] = [:]
        return file.hunks.map { hunk in
            let fingerprint = Fingerprint.of(path: file.path, status: file.status, hunk: hunk)
            // The same change twice in a file is two hunks with one fingerprint.
            let occurrence = occurrences[fingerprint, default: 0]
            occurrences[fingerprint] = occurrence + 1
            var lines = Self.lines(of: hunk)
            let turns = lines.indices.map { index -> Int? in
                lines[index].kind == .context ? nil : provenance.turn(of: lines[index].signed, in: file.path)
            }
            let changed = lines.indices.filter { lines[$0].kind != .context }
            let significant = changed.filter { Self.significant(lines[$0].signed) }
            let turn = significant.compactMap { turns[$0] }.max() ?? changed.compactMap { turns[$0] }.max()
            if turn != nil {
                for index in significant where turns[index] == nil { lines[index].foreign = true }
            }
            return ReviewUnit(
                id: "\(file.path)#\(fingerprint)#\(occurrence)", file: file, hunk: hunk, fingerprint: fingerprint,
                colourKey: Fingerprint.colours(path: file.path, hunk: hunk), lines: lines, turn: turn,
                whitespaceOnly: Self.whitespaceOnly(lines))
        }
    }

    /// git's lines numbered on both sides, with the no-newline marker folded onto its line.
    static func lines(of hunk: DiffHunk) -> [ReviewLine] {
        var lines: [ReviewLine] = []
        var old = hunk.oldStart, new = hunk.newStart
        for raw in hunk.lines {
            let text = String(raw.dropFirst())
            switch raw.first {
            case "+":
                lines.append(ReviewLine(kind: .added, text: text, old: nil, new: new))
                new += 1
            case "-":
                lines.append(ReviewLine(kind: .deleted, text: text, old: old, new: nil))
                old += 1
            case "\\":
                if !lines.isEmpty { lines[lines.count - 1].noNewline = true }
            default:
                lines.append(ReviewLine(kind: .context, text: text, old: old, new: new))
                old += 1
                new += 1
            }
        }
        return lines
    }

    /// A line that says something: a brace or a blank line matches too much to prove anything.
    static func significant(_ signed: String) -> Bool {
        signed.dropFirst().contains { $0.isLetter || $0.isNumber }
    }

    /// Only spacing changed: the same text either side once every space, tab and newline is out.
    static func whitespaceOnly(_ lines: [ReviewLine]) -> Bool {
        let squeeze = { (kind: ReviewLine.Kind) in
            lines.filter { $0.kind == kind }.map { $0.text.filter { !$0.isWhitespace } }.joined()
        }
        guard lines.contains(where: { $0.kind != .context }) else { return false }
        return squeeze(.added) == squeeze(.deleted)
    }
}
