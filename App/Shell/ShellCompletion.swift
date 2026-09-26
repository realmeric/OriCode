import Foundation

/// Tab at the shell prompt, the way zsh does it before its menu: the word being typed completes
/// as far as every match agrees. A zsh user's own zsh says what matches (ZshCompletion); otherwise,
/// or when it has nothing, the first word is a command from what the user's shell knows, and any
/// other word, or one with a slash in it, is a path from the thread's folder. A folder gets its
/// slash and a file its space; when several match, they're what the list shows.
enum ShellCompletion {
    struct Result: Equatable {
        /// The line with its last word completed as far as it goes.
        let text: String
        /// The line before the word each candidate takes the place of.
        var head = ""
        /// Every match, when there's more than one, as the last word would read with each.
        let candidates: [String]
        /// What zsh lists beside a candidate, a git command's line say.
        var descriptions: [String: String] = [:]
    }

    static func complete(_ line: String, folder: String, commands: [String]) -> Result? {
        let (head, word) = split(line)
        let first = head.trimmingCharacters(in: .whitespaces).isEmpty
        if first, !word.isEmpty, !word.contains("/"), !word.hasPrefix("~") {
            let names = Array(Set(commands.filter { $0.hasPrefix(word) })).sorted()
            return finish(head: head, word: word, matches: names.map { (escape($0), false) })
        }
        guard let entries = listing(unescape(word), folder: folder) else { return nil }
        return finish(head: head, word: word, matches: entries.map { (escape($0.path), $0.folder) })
    }

    /// What the user's zsh made of the line, as Completion.zsh prints it: a row for each match,
    /// with where its word starts in the line, the word, what zsh lists it as and its group, then
    /// the line as zsh left it after a ␝. Nil when zsh had nothing, for the paths to try.
    static func zsh(_ answer: String, line: String) -> Result? {
        var completed: String?
        var groups: [(name: String, matches: [(start: Int, word: String, shown: String)])] = []
        for row in answer.split(separator: "\n") {
            if let mark = row.firstIndex(of: "\u{1D}") {
                completed = String(row[row.index(after: mark)...])
                continue
            }
            let fields = row.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, let start = Int(fields[0]), (0...line.unicodeScalars.count).contains(start) else { continue }
            let match = (start, fields[1], fields[2])
            if let group = groups.firstIndex(where: { $0.name == fields[3] }) {
                groups[group].matches.append(match)
            } else {
                groups.append((fields[3], [match]))
            }
        }
        // zsh lists each group sorted, unless it was added -V or unsorted.
        let matches = groups.flatMap { $0.name.hasPrefix("V") ? $0.matches : $0.matches.sorted { $0.word < $1.word } }
        guard let completed, let start = matches.map(\.start).min() else { return nil }
        let scalars = line.unicodeScalars
        let head = String(String.UnicodeScalarView(scalars.prefix(start)))
        var candidates: [String] = []
        var descriptions: [String: String] = [:]
        for match in matches {
            // A word that starts further on, after an `--option=` say, keeps what's between.
            let between = String(String.UnicodeScalarView(scalars.dropFirst(start).prefix(match.start - start)))
            let candidate = between + match.word
            guard !candidates.contains(candidate) else { continue }
            candidates.append(candidate)
            if let dashes = match.shown.range(of: " -- ") {
                descriptions[candidate] = match.shown[dashes.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        if candidates.count == 1 { return Result(text: completed, head: head, candidates: []) }
        return Result(text: completed, head: head, candidates: candidates, descriptions: descriptions)
    }

    /// A path after an `@` in a message, from the thread's folder, as the agent reads it: up to the
    /// next space, or between quotes when it has one, `@"My Notes/todo.txt"`. Nothing is escaped,
    /// and a Tab inside an open `@"` goes on from there.
    static func mention(_ text: String, folder: String) -> Result? {
        let head: Substring
        let typed: Substring
        var quoted = false
        if let open = text.range(of: "@\"", options: .backwards), !text[open.upperBound...].contains("\""),
           open.lowerBound == text.startIndex || text[text.index(before: open.lowerBound)].isWhitespace {
            head = text[..<open.lowerBound]
            typed = text[open.upperBound...]
            quoted = true
        } else {
            let start = text.lastIndex(where: \.isWhitespace).map(text.index(after:)) ?? text.startIndex
            guard text[start...].hasPrefix("@") else { return nil }
            head = text[..<start]
            typed = text[text.index(after: start)...]
        }
        guard let entries = listing(String(typed), folder: folder), let only = entries.first else { return nil }
        func mention(_ path: String, closed: Bool) -> String {
            quoted || path.contains(where: \.isWhitespace) ? "@\"" + path + (closed ? "\"" : "") : "@" + path
        }
        let paths = entries.map { $0.folder ? $0.path + "/" : $0.path }
        if entries.count == 1 {
            return Result(text: head + mention(paths[0], closed: !only.folder) + (only.folder ? "" : " "), candidates: [])
        }
        var common = paths[0]
        for path in paths.dropFirst() {
            common = String(common.commonPrefix(with: path))
        }
        let longer = common.count > typed.count ? common : String(typed)
        return Result(text: head + mention(longer, closed: false), head: String(head),
                      candidates: zip(entries, paths).map { mention($1, closed: !$0.folder) })
    }

    /// What's in the folder a typed path points into, the thread's folder unless it starts with /
    /// or ~, whose names start with its last part: hidden entries only after a dot, and case-blind
    /// when nothing matches as typed. Each comes back as the whole path, as typed up to the name.
    private static func listing(_ typed: String, folder: String) -> [(path: String, folder: Bool)]? {
        let slash = typed.lastIndex(of: "/")
        let directory = slash.map { String(typed[...$0]) } ?? ""
        let prefix = slash.map { String(typed[typed.index(after: $0)...]) } ?? typed
        let expanded = directory.hasPrefix("~") ? NSHomeDirectory() + directory.dropFirst() : directory
        let base = expanded.hasPrefix("/") ? expanded : (folder as NSString).appendingPathComponent(expanded)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.isEmpty ? "/" : base) else { return nil }
        let visible = names.filter { prefix.hasPrefix(".") || !$0.hasPrefix(".") }
        var matches = visible.filter { $0.hasPrefix(prefix) }
        if matches.isEmpty { matches = visible.filter { $0.lowercased().hasPrefix(prefix.lowercased()) } }
        return matches.sorted().map { name in
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: (base as NSString).appendingPathComponent(name), isDirectory: &isFolder)
            return (directory + name, isFolder.boolValue)
        }
    }

    /// One match completes whole; several complete as far as they agree and are listed.
    private static func finish(head: String, word: String, matches: [(word: String, folder: Bool)]) -> Result? {
        guard let only = matches.first else { return nil }
        if matches.count == 1 {
            return Result(text: head + only.word + (only.folder ? "/" : " "), candidates: [])
        }
        var common = only.word
        for match in matches.dropFirst() {
            common = String(common.commonPrefix(with: match.word))
        }
        // The case of the typed word when every match starts with it another way.
        let longer = common.count > word.count ? common : word
        return Result(text: head + longer, head: head, candidates: matches.map { $0.word + ($0.folder ? "/" : "") })
    }

    /// The line up to the word being typed, and that word: the last run of text after a space no
    /// backslash escapes.
    static func split(_ line: String) -> (head: String, word: String) {
        var index = line.endIndex
        while index > line.startIndex {
            let before = line.index(before: index)
            if line[before] == " " {
                let escaped = before > line.startIndex && line[line.index(before: before)] == "\\"
                if !escaped { break }
            }
            index = before
        }
        return (String(line[..<index]), String(line[index...]))
    }

    private static let special = Set(" '\"\\()&;|<>$`!*?[]#{}")

    static func escape(_ name: String) -> String {
        String(name.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    static func unescape(_ word: String) -> String {
        var out = ""
        var escaped = false
        for character in word {
            if escaped || character != "\\" {
                out.append(character)
                escaped = false
            } else {
                escaped = true
            }
        }
        return out
    }
}
