import Foundation

/// Which turn of a thread wrote each changed line, read from the diffs of its own edits. A line
/// is known by its file and its text, so of two identical lines in a file both belong to the
/// latest turn that wrote either. What no edit wrote (a command's change, yours, another
/// thread's) has no turn, and the review says so rather than guess.
struct Provenance {
    /// Each turn's message, by its number: the first message is turn 1. Its head, as anything the
    /// app shows of a message is (`Item.headLength`).
    private(set) var prompts: [Int: String] = [:]
    /// Every edit in the order it was made, a worker's among them. A line is credited to one by
    /// where it stands here.
    private var made: [Edit] = []
    private var added: [String: [String: Int]] = [:]
    private var deleted: [String: [String: Int]] = [:]
    /// The last recorded edit of each file, by where it stands in `made`.
    private var lastMade: [String: Int] = [:]
    /// For each turn, the files it edited in the order it first did.
    private var order: [Int: [String: Int]] = [:]
    /// The latest turn that edited each file at all, for files the review can't read by line.
    private var lastEdit: [String: Int] = [:]
    /// What each turn ran to check its work: builds, tests, linters, and whether they passed.
    private(set) var checks: [Int: [Check]] = [:]

    struct Check: Hashable, Sendable {
        let command: String
        let failed: Bool
    }

    /// Every run of a build or a test, in the order they ran, the shell prompt's among them.
    private(set) var runs: [Run] = []
    /// Each recorded edit of a file: when it was made and how many runs had come before it.
    private var touches: [String: [Touch]] = [:]
    /// Where each file comes among all the files the thread edited, by its first edit.
    private var firsts: [String: Int] = [:]

    /// One run of a check. It says how the command ended only when that was the check's own
    /// ending, and never more than that.
    struct Run: Hashable, Sendable {
        enum Outcome: Hashable, Sendable {
            case exitedZero, failed
            /// Not known, and why, in words that follow "It was": "piped through tail".
            case unknown(String)
        }

        /// The check's own words, `make test`, which its clock is kept by.
        let check: String
        /// The whole line as it ran.
        let command: String
        let startedAt: Date?
        let outcome: Outcome
        /// Where what it printed is kept, which its row opens the end of.
        var source: Source?
    }

    /// The call or the prompt's block a run was: a tool call by its id, the thread's own or a
    /// subagent's, or the transcript's item for a command of yours.
    enum Source: Hashable, Sendable {
        case call(String)
        case shell(UUID)
    }

    /// One edit: the turn it was made in, the transcript's item that shows it, and what the agent
    /// last said in that turn before making it. A subagent's edit is shown by the call that
    /// started the subagent, and a worker's has no item.
    struct Edit: Hashable, Sendable {
        let turn: Int
        var item: UUID?
        var said: String?
    }

    private struct Touch: Hashable, Sendable {
        let at: Date?
        let runs: Int
    }

    init() {}

    /// The worker whose edits made a file's changes in a turn, by turn and path.
    private var rays: [Int: [String: Ray]] = [:]

    /// A head's worker, as the review names the ray that changed a file.
    struct Ray: Hashable, Sendable {
        let agent: String
        let label: String
    }

    /// When each subagent began whose own calls the thread doesn't hold: one from before they
    /// were kept, or an agent's that never tells them. What it ran isn't on the page.
    private(set) var unseenAgents: [Date?] = []

    /// `resolve` turns an edit's file, its view's path or Claude's file_path, into a path from the
    /// repository's top, or nil for a file outside it. A worker's edits count as their turn's,
    /// after the head's own in it. `under` is what each subagent called, by the call that
    /// started it: its commands and edits count as the thread's own, where that call stands.
    ///
    /// `exits` says whether the thread's agent's word that a command failed is the command's own
    /// ending, as Claude Code's is; a call that carries its exit code needs no such word, and
    /// without either a run ends "not known". `own` is the project's own check, as typed in
    /// Settings.
    init(items: [Item], under: [String: [ToolCall]] = [:], rayEdits: [RayEdit] = [], exits: Bool = true, own: String? = nil, resolve: (String) -> String?) {
        var turn = 0
        var said: String?
        var waiting = rayEdits[...]
        let inside = { (folder: String) in resolve((folder as NSString).appendingPathComponent("x")) != nil }
        for item in items {
            switch item {
            case .user(_, let text, _, let midTurn):
                // Taken up in the middle of a turn, a message is part of that turn.
                guard !midTurn else { continue }
                credit(&waiting, through: turn, resolve: resolve)
                turn += 1
                prompts[turn] = String(text.prefix(Item.headLength))
                said = nil
            case .text(_, let text):
                said = Self.sentence(of: text) ?? said
            case .shell(let id, let run):
                // A command of yours at the prompt checks the work as the agent's does.
                guard run.forModel, run.endedAt != nil else { continue }
                for found in Self.recognise(run.command, from: run.folder, own: own, inside: inside) {
                    let why = found.unknown ?? (run.exitCode == nil ? "ended with no exit code" : nil)
                    runs.append(Run(
                        check: found.check, command: run.command, startedAt: run.startedAt,
                        outcome: why.map(Run.Outcome.unknown) ?? (run.exitCode == 0 ? .exitedZero : .failed), source: .shell(id)))
                }
            case .tool(let id, let call):
                take(call, in: turn, by: nil, shown: Edit(turn: turn, item: id, said: said), under: under, exits: exits, own: own, inside: inside, resolve: resolve)
            default:
                break
            }
        }
        credit(&waiting, through: .max, resolve: resolve)
    }

    /// A call's part in the thread: a command's runs, an edit's lines, and under a call that
    /// started a subagent, each of the subagent's own in the order it made them. `parent` is
    /// that call for a subagent's, whose runs Legacy's line of checks leaves out as it always has.
    /// `shown` is the edit this call would be, were it one: its item in the transcript, or the
    /// item of the call a subagent's stands under.
    private mutating func take(
        _ call: ToolCall, in turn: Int, by parent: ToolCall?, shown: Edit, under: [String: [ToolCall]],
        exits: Bool, own: String?, inside: (String) -> Bool, resolve: (String) -> String?
    ) {
        if call.kind == .run {
            guard let command = call.shown("command"), let result = call.result else { return }
            let background = call.background || call.input["run_in_background"]?.bool == true
            for found in Self.recognise(command, own: own, inside: inside) {
                let why = found.unknown
                    // Its call's result is only that it went; how it ended comes after, if it does.
                    ?? (background && call.ended == nil ? "run in the background" : nil)
                    ?? (background && call.ended == "stopped" ? "stopped before it ended" : nil)
                    ?? (background || exits || call.exitCode != nil ? nil : "run by an agent that sends no exit code")
                    // A call the app closed itself, its engine gone, has an error and no words.
                    ?? (call.isError && result.isEmpty && call.exitCode == nil ? "cut off before it ended" : nil)
                    // The two disagree, and this agent's word isn't the command's own: neither is read.
                    ?? (!background && !exits && call.isError && call.exitCode == 0 ? "reported as failed with exit code 0" : nil)
                let failed = background ? call.ended != "completed" : call.isError || (call.exitCode ?? 0) != 0
                runs.append(Run(
                    check: found.check, command: command, startedAt: call.startedAt,
                    outcome: why.map(Run.Outcome.unknown) ?? (failed ? .failed : .exitedZero), source: .call(call.toolUseId)))
            }
            guard parent == nil, Self.checks(command) else { return }
            let check = Check(command: command, failed: call.isError)
            checks[turn, default: []].removeAll { $0.command == command }
            checks[turn, default: []].append(check)
            return
        }
        // A subagent sent to a worktree of its own, or a remote one, ran and edited a copy of the
        // repository: its check read none of what's uncommitted here, and its edits aren't here.
        if call.kind == .agent, call.input["isolation"]?.string != nil { return }
        // What a subagent called, or a workflow's agents, where the call that started them stands.
        if let calls = under[call.toolUseId] {
            for child in calls { take(child, in: turn, by: call, shown: shown, under: under, exits: exits, own: own, inside: inside, resolve: resolve) }
            return
        }
        if call.kind == .agent {
            if !call.keepsCalls { unseenAgents.append(call.startedAt) }
            return
        }
        guard call.isEdit, call.result != nil, !call.isError,
              let file = call.file, let path = resolve(file),
              let diff = Diff.of(call, cwd: "")
        else { return }
        lastEdit[path] = turn
        if order[turn, default: [:]][path] == nil { order[turn, default: [:]][path] = order[turn]?.count ?? 0 }
        if firsts[path] == nil { firsts[path] = firsts.count }
        touches[path, default: []].append(Touch(at: call.startedAt, runs: runs.count))
        made.append(shown)
        lastMade[path] = made.count - 1
        for line in diff.lines {
            switch line.kind {
            case .added: added[path, default: [:]][line.text] = made.count - 1
            case .deleted: deleted[path, default: [:]][line.text] = made.count - 1
            case .context, .gap: break
            }
        }
    }

    /// Workers' edits up to a turn, each line credited to its turn as the head's own edits' are.
    private mutating func credit(_ waiting: inout ArraySlice<RayEdit>, through last: Int, resolve: (String) -> String?) {
        while let edit = waiting.first, edit.turn <= last {
            waiting.removeFirst()
            made.append(Edit(turn: edit.turn))
            for file in edit.files {
                guard let path = resolve(file.path) else { continue }
                lastEdit[path] = edit.turn
                if order[edit.turn, default: [:]][path] == nil { order[edit.turn, default: [:]][path] = order[edit.turn]?.count ?? 0 }
                if firsts[path] == nil { firsts[path] = firsts.count }
                for line in file.hunks.flatMap(\.lines) {
                    let text = String(line.dropFirst())
                    if line.hasPrefix("+") { added[path, default: [:]][text] = made.count - 1 }
                    if line.hasPrefix("-") { deleted[path, default: [:]][text] = made.count - 1 }
                }
                rays[edit.turn, default: [:]][path] = edit.ray
            }
        }
    }

    /// The worker whose edits changed a file in a turn, when a worker's did.
    func ray(of path: String, in turn: Int) -> Ray? { rays[turn]?[path] }

    /// The turn whose edit put this line in, or took it out: a "+" or "-" line of git's diff.
    func turn(of line: String, in path: String) -> Int? {
        edit(of: line, in: path).map { made[$0].turn }
    }

    /// Where the edit that wrote a line of git's diff stands among all of them.
    private func edit(of line: String, in path: String) -> Int? {
        guard let sign = line.first else { return nil }
        let text = String(line.dropFirst())
        return sign == "+" ? added[path]?[text] : sign == "-" ? deleted[path]?[text] : nil
    }

    /// The edit behind a change: the one that wrote the most of its lines, signed as git's diff
    /// has them, and the later of two that wrote as many. A line is known by its text, so one a
    /// later edit wrote again elsewhere in the file, a `return nil`, is credited to that edit, and
    /// the latest edit to write any line would be the wrong one for a change with such a line in
    /// it. For a change no edit's lines match it is the last recorded edit of the file. `paths`
    /// are the file's names, the one it has now first.
    func edit(behind lines: [String], in paths: [String]) -> Edit? {
        var wrote: [Int: Int] = [:]
        for line in lines {
            if let edit = paths.lazy.compactMap({ edit(of: line, in: $0) }).first { wrote[edit, default: 0] += 1 }
        }
        let most = wrote.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
        return (most ?? paths.lazy.compactMap { lastMade[$0] }.first).map { made[$0] }
    }

    /// What the agent said, as the review quotes it: the first line of it with words in it,
    /// without the marks a heading, a list or bold text is written with.
    static func sentence(of text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let plain = line.drop { "#>-*• \t".contains($0) }.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            guard plain.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            return plain.count > 240 ? String(plain.prefix(239)) + "…" : plain
        }
        return nil
    }

    func lastTurn(editing path: String) -> Int? { lastEdit[path] }

    /// Where a file comes in its turn: the order the turn first edited its files, which is the
    /// order the review tells them in.
    func rank(of path: String, in turn: Int) -> Int { order[turn]?[path] ?? Int.max }

    var isEmpty: Bool { lastEdit.isEmpty }

    /// Where a file comes among everything the thread edited, by its first edit; nil for a file
    /// no recorded edit touched.
    func firstEdit(of path: String) -> Int? { firsts[path] }

    /// How often the thread's recorded edits changed a file since a moment, and how many runs
    /// came between the first of those edits and the last. An edit with no time is left out.
    ///
    /// A subagent's calls stand where the call that started it does, though it may have worked
    /// while the thread went on, so a run is between two edits by when it began. Where a time
    /// is missing, the edits' or the run's, it is by where their calls stand.
    func edits(of path: String, since: Date?) -> (count: Int, runsBetween: Int) {
        let told = story(of: path, since: since)
        return (told.count, told.between.count)
    }

    /// The same count, with the runs between by name.
    func story(of path: String, since: Date?) -> (count: Int, between: [Run]) {
        let counted = (touches[path] ?? []).filter { touch in
            guard let since else { return true }
            return touch.at.map { $0 >= since } ?? false
        }
        guard let first = counted.first, let last = counted.last else { return (0, []) }
        let times = counted.compactMap(\.at)
        let span = times.count == counted.count ? times.min().flatMap { from in times.max().map { (from, $0) } } : nil
        let stood = min(first.runs, last.runs)..<max(first.runs, last.runs)
        let between = runs.indices.filter { index in
            if let span, let started = runs[index].startedAt { return started > span.0 && started < span.1 }
            return stood.contains(index)
        }
        return (counted.count, between.map { runs[$0] })
    }

    private static let runners: Set = ["pytest", "jest", "vitest", "tsc", "eslint", "mypy", "ruff", "xcodebuild", "swiftlint", "rspec", "phpunit", "mvn", "gradle", "ctest", "tox"]
    private static let tools: Set = ["make", "npm", "pnpm", "yarn", "bun", "cargo", "go", "swift", "deno", "npx", "node", "python", "python3", "uv", "bundle", "dotnet", "mix", "just"]
    private static let asks: Set = ["test", "tests", "build", "lint", "check", "typecheck", "clippy", "vet", "--test", "pytest", "spec"]
    /// What xcodebuild is asked to do; without one of them it only answers a question.
    private static let xcodeActions: Set = ["build", "test", "analyze", "archive", "build-for-testing", "test-without-building"]
    /// What stands for a quoted string in a command's words: its text is an argument's, never a command's.
    private static let quoted: Character = "\u{FFFC}"
    /// What stands in front of a check without being it.
    private static let wrappers: Set = ["time", "env", "timeout", "xcrun", "caffeinate", "nice"]
    /// What asks a tool about itself or for a rehearsal: with one of them nothing of the code ran.
    private static let idle: Set = ["--version", "--help", "-h", "--dry-run", "-dry-run", "--collect-only", "--co", "--just-print", "--recon", "--list-tests", "--listTests"]

    /// A command that checks the work rather than looks around: a build, tests, a linter, run
    /// by a tool that does that. `cat test.txt` reads a file; `make test` checks.
    static func checks(_ command: String) -> Bool {
        for segment in command.components(separatedBy: CharacterSet(charactersIn: "&;|\n")) {
            // Leading VAR=value assignments set up the command; the tool comes after them.
            let words = segment.split(separator: " ").map(String.init).drop { $0.contains("=") }
            guard let first = words.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            if runners.contains(first) { return true }
            if tools.contains(first), words.dropFirst().contains(where: { asks.contains($0) || $0.hasPrefix("test:") }) { return true }
        }
        return false
    }

    /// A check found in a command line: its own words, and why its ending can't be read off the
    /// line's, when it can't.
    struct Recognised: Hashable {
        let check: String
        let unknown: String?
    }

    /// The checks in a command line, each with whether the line's exit code is its own: it is
    /// when nothing follows the check but `&&`. A pipe, a semicolon, `||` or `&` after it hands
    /// the ending to something else. What stands in front, `time`, `env`, `timeout 60`, `xcrun`,
    /// `caffeinate`, `nice` or a parenthesis, is stepped over.
    ///
    /// Three things are no run at all, so that a check's clock is only ever moved by a run of it
    /// here: one asked for its version, its help or a rehearsal; one after `||`, which runs only
    /// when what came before it failed; and one in a folder `inside` doesn't hold, which the
    /// line reached by `cd` or `make -C` from `folder`, or one it can't be read to have reached.
    ///
    /// `own` is a check the project names for itself, `./ci.sh`: a command of its words is that
    /// check, run by a shell or straight, with nothing after them but an option or a
    /// redirection. `rake db:migrate` is not `rake`. A check of several commands, `make build &&
    /// make test`, is those commands in a row, parted as it parts them.
    static func recognise(_ command: String, from folder: String = "", own: String? = nil, inside: (String) -> Bool = { _ in true }) -> [Recognised] {
        let parts = segments(command)
        var named = (own.map(segments) ?? []).map { part in
            (words: part.words.indices.drop { part.words[$0].contains("=") }.map(part.typed), then: part.then)
        }
        if named.contains(where: \.words.isEmpty) { named = [] }
        var taken = 0
        var found: [Recognised] = []
        var folder: String? = folder
        for (index, part) in parts.enumerated() where index >= taken {
            var words = part.words[...].drop { $0.contains("=") }
            while let front = words.first, wrappers.contains((front as NSString).lastPathComponent) {
                words = words.dropFirst().drop { $0.hasPrefix("-") || $0.contains("=") || $0.first?.isNumber == true }
            }
            guard let tool = words.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            if tool == "cd" || tool == "pushd" {
                folder = folder.flatMap { moved($0, to: words.indices.contains(words.startIndex + 1) ? part.typed(words.startIndex + 1) : nil) }
                continue
            }
            let rest = Array(words.dropFirst())
            if rest.contains(where: idle.contains) || (tool == "make" && rest.contains("-n")) || (tool == "tsc" && rest.contains("-v")) { continue }
            if index > 0, parts[index - 1].then == "||" { continue }
            var here = folder
            if tool == "make", let flag = words.firstIndex(of: "-C") {
                here = here.flatMap { moved($0, to: words.indices.contains(flag + 1) ? part.typed(flag + 1) : nil) }
            }
            guard let here, inside(here) else { continue }
            if let first = named.first, index + named.count <= parts.count,
               matches(words, of: part, first.words) || (shells.contains(tool) && matches(words.dropFirst(), of: part, first.words)),
               named.indices.dropFirst().allSatisfy({ step in
                   let next = parts[index + step]
                   return parts[index + step - 1].then == named[step - 1].then && matches(next.words[...].drop { $0.contains("=") }, of: next, named[step].words)
               })
            {
                taken = index + named.count
                // A check that pipes or goes on past a failure hands its ending on inside itself.
                let handed = named.indices.dropLast().first { named[$0].then != "&&" }
                found.append(Recognised(
                    check: (own ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    unknown: unknown(after: handed.map { index + $0 } ?? taken - 1, in: parts)))
                continue
            }
            // Its name is the tool and what was asked of it, without the flags, paths and filters
            // that differ from one run to the next: `xcodebuild test`, `make test`, `node --test`.
            let name: [String]
            if tool == "xcodebuild" {
                let actions = rest.filter(xcodeActions.contains)
                guard !actions.isEmpty else { continue }
                name = [tool] + actions
            } else if runners.contains(tool) {
                name = [tool]
            } else if tools.contains(tool), let ask = rest.firstIndex(where: { asks.contains($0) || $0.hasPrefix("test:") }) {
                name = [tool] + rest[...ask].filter { !$0.contains("=") && !$0.contains(">") && !$0.contains(quoted) }
            } else {
                continue
            }
            found.append(Recognised(check: name.joined(separator: " "), unknown: unknown(after: index, in: parts)))
        }
        return found
    }

    private static let shells: Set = ["sh", "bash", "zsh"]

    /// Whether a part's words run a check's own, `./ci.sh` and `ci.sh` being one script and a
    /// quoted string its text. After them options and redirections may stand; any other word
    /// asks for something the check didn't name, an option's own value among them.
    private static func matches(_ words: ArraySlice<String>, of part: Segment, _ named: [String]) -> Bool {
        let script = { (word: String) in word.hasPrefix("./") ? String(word.dropFirst(2)) : word }
        guard words.count >= named.count, zip(words.indices, named).allSatisfy({ script(part.typed($0)) == script($1) }) else { return false }
        // `> log.txt` is two words, and the second is where the first sends the output.
        var target = false
        for word in words.dropFirst(named.count) {
            let redirects = word.contains(">") || word.contains("<")
            guard target || redirects || word.hasPrefix("-") else { return false }
            target = redirects && (word.hasSuffix(">") || word.hasSuffix("<"))
        }
        return true
    }

    /// Where a `cd` leaves the line, or nil for a target only the shell could say.
    private static func moved(_ from: String, to target: String?) -> String? {
        guard var target, !target.isEmpty, target != "-", !target.contains("$"), !target.contains("`") else { return nil }
        if target == "~" || target.hasPrefix("~/") { target = NSHomeDirectory() + target.dropFirst() }
        return target.hasPrefix("/") ? target : (from as NSString).appendingPathComponent(target)
    }

    private struct Segment {
        var words: [String]
        /// Its quoted strings, in the order their marks stand in the words.
        var strings: [String] = []

        /// A word as it was typed, its quoted strings put back.
        func typed(_ index: Int) -> String {
            var strings = self.strings.dropFirst(words[..<index].joined().count { $0 == Provenance.quoted })
            return String(words[index].flatMap { $0 == Provenance.quoted ? Array(strings.popFirst() ?? "") : [$0] })
        }
        /// What parts it from the next: `&&`, `||`, `|`, `;` or `&`, and nothing after the last.
        var then = ""
    }

    private static func unknown(after index: Int, in parts: [Segment]) -> String? {
        guard let hand = parts[index...].firstIndex(where: { $0.then != "&&" && $0.then != "" }) else { return nil }
        guard hand == index else { return "followed by a command whose ending is the one reported" }
        switch parts[index].then {
        case "|": return "piped through \(parts.dropFirst(index + 1).first?.words.first.map { ($0 as NSString).lastPathComponent } ?? "another command")"
        case "&": return "run in the background"
        case "||": return "followed by ||"
        default: return "followed by another command"
        }
    }

    /// A command line cut where the shell would cut it, a quoted string one mark and a
    /// redirection's `&` left alone. A parenthesis around a group is dropped, and so are a
    /// comment and what a here-document feeds a command, which is a file's text.
    private static func segments(_ command: String) -> [Segment] {
        var parts: [Segment] = []
        var text = ""
        var strings: [String] = []
        var quote: Character?
        let characters = Array(withoutHereDocuments(command))
        func close(_ then: String) {
            let words = text.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()")) }.filter { !$0.isEmpty }
            text = ""
            defer { strings = [] }
            if words.isEmpty {
                // Nothing between two marks: `;` after `&`, or a line's end.
                if then == "", !parts.isEmpty, parts[parts.count - 1].then == ";" { parts[parts.count - 1].then = "" }
                return
            }
            parts.append(Segment(words: words, strings: strings, then: then))
        }
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if let open = quote {
                if character == open { quote = nil } else { strings[strings.count - 1].append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                text.append(quoted)
                strings.append("")
            } else if character == "#", text.last?.isWhitespace ?? true {
                // A comment runs to the line's end, and an apostrophe in it opens nothing.
                while index + 1 < characters.count, characters[index + 1] != "\n" { index += 1 }
            } else if character == "\\", let next {
                text.append(next == "\n" ? " " : next)
                index += 1
            } else if character == "&", next == "&" {
                close("&&")
                index += 1
            } else if character == "|", next == "|" {
                close("||")
                index += 1
            } else if character == "|" {
                close("|")
                if next == "&" { index += 1 }
            } else if character == "&", text.last == ">" || text.last == "<" || next == ">" {
                text.append(character)
            } else if character == "&" {
                close("&")
            } else if character == ";" || character == "\n" {
                close(";")
            } else {
                text.append(character)
            }
            index += 1
        }
        close("")
        return parts
    }

    /// The command without the lines between `<<EOF` and `EOF`. `<<<` feeds a word, not lines.
    private static func withoutHereDocuments(_ command: String) -> String {
        guard command.contains("<<") else { return command }
        var kept: [Substring] = []
        var until: String?
        for line in command.split(separator: "\n", omittingEmptySubsequences: false) {
            if let end = until {
                if line.trimmingCharacters(in: .whitespaces) == end { until = nil }
                continue
            }
            kept.append(line)
            let line = line.replacingOccurrences(of: "<<<", with: "   ")
            guard let mark = line.range(of: "<<") else { continue }
            let word = line[mark.upperBound...].drop { $0 == "-" || $0 == " " }.prefix { !$0.isWhitespace && !";|&)".contains($0) }
            let end = word.trimmingCharacters(in: CharacterSet(charactersIn: "'\"\\"))
            if !end.isEmpty { until = end }
        }
        return kept.joined(separator: "\n")
    }
}

/// What a worker brought into the thread's folder, from its `worker` event, and the turn it came in.
struct RayEdit: Hashable {
    struct File: Hashable {
        let path: String
        let hunks: [Hunk]
    }

    let turn: Int
    let ray: Provenance.Ray
    let files: [File]
}

extension RayEdit {
    /// Nil for a worker's turn that only cost something, with no edit here.
    init?(_ body: JSON, turn: Int) {
        let files = (body["files"]?.array ?? []).compactMap { file in
            file["path"]?.string.map { File(path: $0, hunks: Hunk.list(file["hunks"]) ?? []) }
        }
        guard !files.isEmpty, let agent = body["agent"]?.string else { return nil }
        self.init(turn: turn, ray: Provenance.Ray(agent: agent, label: body["label"]?.string ?? ""), files: files)
    }
}

enum RepoPath {
    /// An edit's file_path as a path from the repository's top, or nil when it's outside. Both
    /// sides are compared as real paths, since git reports the top with symlinks resolved.
    static func relative(_ file: String, cwd: String, root: String) -> String? {
        let absolute = file.hasPrefix("/") ? file : (cwd as NSString).appendingPathComponent(file)
        let standard = (absolute as NSString).standardizingPath
        if let inside = strip(root, from: standard) { return inside }
        return strip(real(root), from: real(standard))
    }

    private static func strip(_ root: String, from path: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// realpath(3), for a file that may be gone: its folder's real path and its name.
    static func real(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let folder = (path as NSString).deletingLastPathComponent
        guard !folder.isEmpty, folder != path else { return path }
        return (real(folder) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }
}
