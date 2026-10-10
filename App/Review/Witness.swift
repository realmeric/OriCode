import Foundation

/// Which review ⌘⇧D opens, chosen in Settings › Source Control. Both read the same book and
/// keep the same marks, notes and commits.
enum ReviewDesign: String, CaseIterable, Sendable {
    case witness, legacy

    static let key = "reviewDesign"
    /// Either review is this wide at most.
    static let width: CGFloat = 960

    /// What's chosen, Legacy until something is.
    static var chosen: ReviewDesign {
        UserDefaults.standard.string(forKey: key).flatMap(ReviewDesign.init(rawValue:)) ?? .legacy
    }

    var title: String {
        switch self {
        case .witness: "Witness"
        case .legacy: "Legacy"
        }
    }
}

/// Witness's reading of the book: the changes to read before any other, each with its reason in
/// words, then the runs, then what last changed before them, then what needs no reading. It
/// comes from the order things happened in the thread and from the disk's own times, so it
/// calls no model. A run is never a mark on a change: all it can do is fail to put one first.
struct WitnessPage: Sendable {
    /// A file's line and the changes under it. A file can have two: one first, for the changes
    /// with a reason of their own, and one after with the rest.
    struct FileLine: Identifiable, Hashable, Sendable {
        let id: String
        let file: FileDiff
        var reasons: [String] = []
        /// Said beside the path, in secondary ink: what the thread doesn't know of the file.
        var aside: String?
        var units: [String] = []
    }

    /// A change that needs no reading, on one line until it's opened.
    struct Quiet: Identifiable, Hashable, Sendable {
        let id: String
        let path: String
        let what: String
    }

    var sentence = ""
    var readFirst: [FileLine] = []
    /// The last run of each check since the last commit, the one that ran longest ago first.
    var runs: [Provenance.Run] = []
    /// Under the last run's row, what holds of everything below it.
    var below: String?
    var rest: [FileLine] = []
    var quiet: [Quiet] = []
    /// How many changes the page holds, and how many of them are first.
    var total = 0
    var first: Int { readFirst.reduce(0) { $0 + $1.units.count } }
    /// Whether the first ones are a queue: not when every change that's read is among them.
    var queued: Bool { !readFirst.isEmpty && !rest.isEmpty }

    /// Every change in the order the page shows it, which is the order the keyboard walks.
    var order: [String] { readFirst.flatMap(\.units) + rest.flatMap(\.units) + quiet.map(\.id) }

    /// Three edits of a file with two runs among them put it first.
    static let manyEdits = 3
    static let manyRuns = 2

    init() {}

    init(diff: WorkingDiff, units: [ReviewUnit], provenance: Provenance) {
        let committed = diff.headAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        // Each check's last run. One from before the last commit says nothing of what's here.
        var last: [String: Provenance.Run] = [:]
        for run in provenance.runs { last[run.check] = run }
        runs = last.values
            .filter { run in
                guard let committed, let started = run.startedAt else { return true }
                return started >= committed
            }
            .sorted { ($0.startedAt ?? .distantFuture, $0.check) < ($1.startedAt ?? .distantFuture, $1.check) }

        struct Entry {
            let file: FileDiff
            var units: [ReviewUnit] = []
        }
        var keys: [String] = []
        var files: [String: Entry] = [:]
        for unit in units {
            let key = unit.file.path + "\u{0}" + unit.file.status
            if files[key] == nil {
                keys.append(key)
                files[key] = Entry(file: unit.file)
            }
            files[key]!.units.append(unit)
        }
        total = units.count

        // Every file a check reads, with the runs it changed after: a lockfile's change or a
        // re-indented file after a run is the sentence's business as much as an edit is.
        var read: [(path: String, later: [Provenance.Run])] = []
        var proseSince = false
        var firstLines: [(line: FileLine, rank: Int)] = []
        var restLines: [(line: FileLine, rank: Int, changed: Double)] = []
        for (position, key) in keys.enumerated() {
            guard var entry = files[key] else { continue }
            entry.units.sort { ($0.hunk?.newStart ?? 0) < ($1.hunk?.newStart ?? 0) }
            let file = entry.file
            let later = runs.filter { Self.changed(file, after: $0) }
            if Self.prose(file.path) {
                if !later.isEmpty, file.status != "D" { proseSince = true }
            } else {
                read.append((file.path, later))
            }

            // What brings the whole file first, then what brings one change of it.
            var whole: [String] = []
            if file.status == "D" {
                whole.append("deleted")
            } else if file.changedAt == nil {
                whole.append("no time known")
            } else if !later.isEmpty, !Self.prose(file.path) {
                whole.append(Self.reason(later, of: runs))
            }
            // A file renamed after its edits has them under the name it had then.
            let known = [file.path, file.oldPath].compactMap { $0 }.first { provenance.firstEdit(of: $0) != nil }
            let edits = provenance.edits(of: known ?? file.path, since: committed)
            if edits.count >= Self.manyEdits, edits.runsBetween >= Self.manyRuns {
                whole.append("edited \(edits.count) times with \(edits.runsBetween) runs between")
            }
            let own = entry.units.map { unit in Self.wordsTakenOut(unit) ? ["words taken out of a line"] : [] }
                .enumerated().map { $1 + entry.units[$0].labels.filter(Signals.testWarnings.contains) }
            let rank = known.flatMap(provenance.firstEdit(of:)) ?? Self.firstUnknown + position
            var lead = FileLine(id: "first:" + key, file: file)
            var rest = FileLine(id: "rest:" + key, file: file)
            for (index, unit) in entry.units.enumerated() {
                if !whole.isEmpty || !own[index].isEmpty {
                    lead.units.append(unit.id)
                    for reason in own[index] where !lead.reasons.contains(reason) { lead.reasons.append(reason) }
                } else if let what = Self.quiet(unit) {
                    quiet.append(Quiet(id: unit.id, path: file.path, what: what))
                } else {
                    rest.units.append(unit.id)
                }
            }
            lead.reasons += whole
            if known == nil, !provenance.isEmpty { rest.aside = "no edit record" }
            if !later.isEmpty, Self.prose(file.path) { rest.aside = "changed since, and no check reads prose" }
            if !lead.units.isEmpty { firstLines.append((lead, rank)) }
            if !rest.units.isEmpty { restLines.append((rest, rank, file.changedAt ?? .infinity)) }
        }
        // More reasons come higher; among equals, the order the thread first touched the files.
        readFirst = firstLines.sorted { ($1.line.reasons.count, $0.rank) < ($0.line.reasons.count, $1.rank) }.map(\.line)
        // The rest in that order too, and a file no recorded edit explains after them, by its time on disk.
        rest = restLines.sorted { a, b in
            if a.rank < Self.firstUnknown || b.rank < Self.firstUnknown { return a.rank < b.rank }
            return (a.changed, a.rank) < (b.changed, b.rank)
        }.map(\.line)

        if !rest.isEmpty, !runs.isEmpty {
            let it = runs.count == 1 ? "it" : "them"
            below = proseSince ? "everything below but prose last changed before \(it)" : "everything below last changed before \(it)"
        }
        sentence = Self.sentence(runs: runs, any: !provenance.runs.isEmpty, read: read, proseSince: proseSince)
    }

    /// Ranks from here on are files no recorded edit touched.
    private static let firstUnknown = 1_000_000

    /// Whether a file changed after a run began, by the disk's time for it. With either time
    /// missing it did: what isn't known is read.
    static func changed(_ file: FileDiff, after run: Provenance.Run) -> Bool {
        guard let changed = file.changedAt, let started = run.startedAt else { return true }
        return changed >= started.timeIntervalSince1970 * 1000
    }

    /// Words no check reads, so a run that came before them says nothing against them.
    static func prose(_ path: String) -> Bool {
        ["md", "txt", "rst"].contains((path as NSString).pathExtension.lowercased())
    }

    /// Where a line's indentation is the code, so a change of spacing alone can be the change.
    static func spacingIsSyntax(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return ["py", "yml", "yaml"].contains((name as NSString).pathExtension.lowercased()) || name == "Makefile"
    }

    /// What a change that needs no reading is, or nil for one that's read: a lockfile's, one
    /// where only spacing changed, or a block that moved with nothing in it changed. Never a
    /// change a test's label is on.
    static func quiet(_ unit: ReviewUnit) -> String? {
        guard unit.hunk != nil, unit.labels.allSatisfy({ !Signals.testWarnings.contains($0) }) else { return nil }
        if unit.lockfile { return "lockfile" }
        if unit.whitespaceOnly { return spacingIsSyntax(unit.file.path) ? nil : "spacing only" }
        let changed = unit.lines.filter { $0.kind != .context }
        guard !changed.isEmpty, changed.allSatisfy(\.moved),
              let move = unit.labels.first(where: { $0.hasPrefix("moved ") }), !move.hasSuffix("changed on the way")
        else { return nil }
        return move
    }

    /// A replaced line whose old side lost words and whose new side gained none: a clause
    /// dropped, a condition loosened. Punctuation alone going isn't it.
    static func wordsTakenOut(_ unit: ReviewUnit) -> Bool {
        let lines = unit.lines
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .deleted else {
                index += 1
                continue
            }
            let end = lines[index...].firstIndex { $0.kind != .deleted } ?? lines.count
            let added = lines[end...].prefix { $0.kind == .added }.count
            for offset in 0..<min(end - index, added) {
                guard let gone = unit.words[index + offset], unit.words[end + offset] == nil else { continue }
                let old = Array(lines[index + offset].text)
                if gone.contains(where: { range in old[range.clamped(to: 0..<old.count)].contains { $0.isLetter || $0.isNumber } }) { return true }
            }
            index = end + added
        }
        return false
    }

    /// Why a file is first for having changed after runs: which checks it changed after, and
    /// which have run since.
    private static func reason(_ later: [Provenance.Run], of runs: [Provenance.Run]) -> String {
        let since = runs.filter { !later.contains($0) }.map(\.check)
        if since.isEmpty, later.count > 2 { return "changed after every check last ran" }
        let changed = "changed after \(list(later.map(\.check))) last ran"
        return since.isEmpty ? changed : "\(changed), only \(list(since)) \(since.count == 1 ? "has" : "have") run since"
    }

    private static func list(_ names: [String]) -> String {
        names.count < 2 ? names.first ?? "" : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// What a run's row says of how it ended.
    static func result(_ run: Provenance.Run) -> String {
        switch run.outcome {
        case .exitedZero: "exited 0"
        case .failed: "failed"
        case .unknown(let why): "result not known, \(why)"
        }
    }

    /// The sentence the page stands under: a check against what has changed since it last ran,
    /// and how that run ended when its ending was its own. It is about the check that failed,
    /// when one did, and else about the one that ran longest ago; the others are named after.
    private static func sentence(runs: [Provenance.Run], any: Bool, read: [(path: String, later: [Provenance.Run])], proseSince: Bool) -> String {
        guard let at = runs.firstIndex(where: { $0.outcome == .failed }) ?? runs.indices.first else {
            return any
                ? "No build or test OriCode recognises has run in this thread since the last commit."
                : "No build or test OriCode recognises ran in this thread."
        }
        let run = runs[at]
        let changed = read.filter { $0.later.contains(run) }
        let before = runs[..<at].map(\.check), after = runs[(at + 1)...].map(\.check)
        let others = (before.isEmpty ? "" : " \(list(before)) last ran before it.")
            + (after.isEmpty ? "" : " Only \(list(after)) \(after.count == 1 ? "has" : "have") run since.")
        let nothing = proseSince ? "nothing but prose has changed since" : "nothing here has changed since"
        if changed.isEmpty {
            switch run.outcome {
            case .exitedZero: return "\(run.check) exited 0 and \(nothing).\(others)"
            case .failed: return "\(run.check) failed and \(nothing).\(others)"
            case .unknown(let why): return "\(run.check) last ran and \(nothing). It was \(why), so its result is not known.\(others)"
            }
        }
        let ended = switch run.outcome {
        case .exitedZero: " It exited 0 then."
        case .failed: " It failed then."
        case .unknown(let why): " It was \(why), so its result is not known."
        }
        if changed.count == read.count { return "Everything here changed after \(run.check) last ran.\(ended)\(others)" }
        let what = changed.count == 1 ? (changed[0].path as NSString).lastPathComponent : "\(changed.count) of the \(read.count) files here"
        return "\(run.check) last ran before \(what) last changed.\(ended)\(others)"
    }
}
