import Foundation

/// Which review ⌘⇧D opens, chosen in Settings › Source Control. Both read the same book and
/// keep the same marks, notes and commits.
enum ReviewDesign: String, CaseIterable, Sendable {
    case witness, legacy

    static let key = "reviewDesign"
    /// Either review is this wide at most.
    static let width: CGFloat = 960
    /// And never narrower than a column of a pair is: under this its buttons and a line of code
    /// have no room, and a pinned drawer stands aside for it.
    static let least: CGFloat = 440

    /// What's chosen, Witness until something is.
    static var chosen: ReviewDesign {
        UserDefaults.standard.string(forKey: key).flatMap(ReviewDesign.init(rawValue:)) ?? .witness
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

    /// Every change in the order the page shows it.
    var order: [String] { readFirst.flatMap(\.units) + rest.flatMap(\.units) + quiet.map(\.id) }

    /// What the keyboard walks: the changes in that order, and each run's row where it stands,
    /// over what last changed before it or, with nothing under the runs, at the top.
    var walk: [String] {
        let rows = runs.map(Self.id)
        guard !rest.isEmpty else { return rows + order }
        return readFirst.flatMap(\.units) + rows + rest.flatMap(\.units) + quiet.map(\.id)
    }

    /// A run's row, as the keyboard and the page know it.
    static func id(of run: Provenance.Run) -> String { "r:" + run.check }

    func run(_ id: String?) -> Provenance.Run? {
        guard let id, id.hasPrefix("r:") else { return nil }
        return runs.first { Self.id(of: $0) == id }
    }

    /// What the thread says of a change, which the caption under the page tells for the one the
    /// keyboard is on. None of it orders the page or stands beside a run's result.
    struct Account: Hashable, Sendable {
        /// Which change it is on the page, counted from 1.
        var number = 0
        /// The message that asked for it, by its first words; nil when no edit here made it.
        var asked: String?
        /// How often its file was edited and what ran between, in words.
        var edits: String?
        /// The worker whose edits made it.
        var ray: Provenance.Ray?
        /// The transcript's item that shows the edit behind it.
        var edit: UUID?
        /// What the agent said in that turn before it made the edit.
        var said: String?
    }

    private(set) var accounts: [String: Account] = [:]
    /// For each check on the page, the files it reads that changed after its last run.
    private(set) var changedAfter: [String: [String]] = [:]
    /// How many digits the page's longest line number has: one number column for every file,
    /// so code starts at the same x in all of them.
    private(set) var digits = 2
    /// The line each change is on: its file's, or its own when it needs no reading. Tab walks these.
    private(set) var lineOf: [String: String] = [:]

    /// Whether a change is one of those that need no reading, a line until it's opened.
    func isQuiet(_ id: String) -> Bool { lineOf[id] == id }

    /// The page's files in its order, each once, with the first change it has here.
    var files: [(file: FileDiff, first: String)] {
        var seen = Set<String>()
        var files: [(FileDiff, String)] = []
        for line in readFirst + rest {
            guard let first = line.units.first, seen.insert(line.file.path + "\u{0}" + line.file.status).inserted else { continue }
            files.append((line.file, first))
        }
        let units = Dictionary(quietFiles.map { ($0.id, $0.file) }) { first, _ in first }
        for line in quiet {
            guard let file = units[line.id], seen.insert(file.path + "\u{0}" + file.status).inserted else { continue }
            files.append((file, line.id))
        }
        return files
    }

    /// The file of each change that needs no reading, which its line names by path alone.
    private var quietFiles: [(id: String, file: FileDiff)] = []

    /// Three edits of a file with two runs among them put it first.
    static let manyEdits = 3
    static let manyRuns = 2

    init() {}

    init(diff: WorkingDiff, units: [ReviewUnit], provenance: Provenance) {
        let committed = diff.headAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        // Each check's last run. One from before the last commit says nothing of what's here.
        var last: [String: Provenance.Run] = [:]
        // A subagent's stand where its call does, so the later of two is told by their starts.
        for run in provenance.runs {
            if let had = last[run.check]?.startedAt, let started = run.startedAt, started < had { continue }
            last[run.check] = run
        }
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
        let longest = units.compactMap(\.hunk).map { max($0.oldStart + $0.oldLines, $0.newStart + $0.newLines) }.max() ?? 0
        digits = max(2, String(longest).count)

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
            let story = provenance.story(of: known ?? file.path, since: committed)
            if story.count >= Self.manyEdits, story.between.count >= Self.manyRuns {
                whole.append("edited \(story.count) times with \(story.between.count) runs between")
            }
            for unit in entry.units {
                var account = Account(asked: unit.turn.flatMap { provenance.prompts[$0] }.map(Self.firstWords), edits: Self.edits(story))
                // A change no edit here made has none to show, whatever else was done to its file.
                if let turn = unit.turn {
                    let changed = unit.lines.filter { $0.kind != .context }.map(\.signed)
                    let telling = changed.filter(ReviewBook.significant)
                    let edit = provenance.edit(behind: telling.isEmpty ? changed : telling, in: [file.path, file.oldPath].compactMap { $0 })
                    // The message is the one that edit answered, where a later turn wrote a line of it again.
                    if let asked = edit.flatMap({ provenance.prompts[$0.turn] }) { account.asked = Self.firstWords(asked) }
                    account.ray = provenance.ray(of: file.path, in: edit?.turn ?? turn)
                    account.edit = edit?.item
                    account.said = edit?.said
                }
                accounts[unit.id] = account
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
                    quietFiles.append((unit.id, file))
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

        for line in readFirst + rest {
            for unit in line.units { lineOf[unit] = line.id }
        }
        for line in quiet { lineOf[line.id] = line.id }
        for (index, id) in order.enumerated() { accounts[id]?.number = index + 1 }
        for run in runs { changedAfter[run.check] = read.filter { $0.later.contains(run) }.map(\.path) }

        if !rest.isEmpty, !runs.isEmpty {
            let it = runs.count == 1 ? "it" : "them"
            below = proseSince ? "everything below but prose last changed before \(it)" : "everything below last changed before \(it)"
        }
        sentence = Self.sentence(runs: runs, any: !provenance.runs.isEmpty, read: read, proseSince: proseSince)
        // A subagent whose calls the thread doesn't hold may have run a check nobody saw.
        let unseen = provenance.unseenAgents.contains { started in
            guard let committed, let started else { return true }
            return started >= committed
        }
        if unseen { sentence += " " + Self.unseenSubagent }
    }

    /// A message as a menu or the caption names it: its first line's first words.
    static func firstWords(_ prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard line.count > 48 else { return line.isEmpty ? "A message with no words" : line }
        let cut = line.prefix(48)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    /// A file's recorded edits and the runs between its first and its last, in words; nil for a
    /// file no recorded edit touched.
    static func edits(_ story: (count: Int, between: [Provenance.Run])) -> String? {
        guard story.count > 0 else { return nil }
        guard story.count > 1 else { return "edited once" }
        let checks = story.between.map(\.check).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let between = switch (story.between.count, checks.count) {
        case (0, _): "no run between"
        case (1, _): "a run of \(checks[0]) between"
        case (let runs, 1): "\(runs) runs of \(checks[0]) between"
        case (let runs, _): "\(runs) runs between, of \(list(checks))"
        }
        return "edited \(story.count) times with \(between)"
    }

    /// The line A leaves in a note for the agent: the check to run again, unpiped so that its
    /// ending is its own, and what changed after it last ran. It is for the run whose row the
    /// keyboard is on, or for the check a change's file changed after, and failing that the one
    /// the page's sentence is about. Nil when no check has run.
    func askAgain(for path: String?, on row: Provenance.Run? = nil) -> String? {
        let after = path.flatMap { path in runs.first { changedAfter[$0.check]?.contains(path) == true } }
        guard let run = row ?? after ?? runs.first(where: { $0.outcome == .failed }) ?? runs.first else { return nil }
        var how = ", unpiped"
        if case .unknown(let why) = run.outcome {
            if why.hasPrefix("followed") { how += " and with nothing after it" }
            if why == "run in the background" || why.hasPrefix("stopped") { how += " and in the foreground" }
        }
        let names = (changedAfter[run.check] ?? []).map { ($0 as NSString).lastPathComponent }
        let what: String
        switch names.count {
        case 0:
            guard case .unknown = run.outcome else { return "Run \(run.check) again\(how)." }
            what = "its result is not known"
        case 1, 2: what = "\(Self.list(names)) changed after it last ran"
        default: what = "\(names[0]), \(names[1]) and \(names.count - 2) more \(names.count == 3 ? "file" : "files") changed after it last ran"
        }
        return "Run \(run.check) again\(how): \(what)."
    }

    /// The end of what a command printed, as it is: its last lines, without the empty ones after them.
    static func tail(of output: String, lines count: Int = 12) -> (lines: [String], of: Int) {
        var lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return (Array(lines.suffix(count)), lines.count)
    }

    static let unseenSubagent = "A subagent worked in this thread and what it ran was not recorded, so a check of its own is not on this page."

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
