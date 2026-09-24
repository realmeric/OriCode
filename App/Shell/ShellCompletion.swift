import Foundation

/// Tab at the shell prompt, the way zsh does it before its menu: the word being typed completes
/// as far as every match agrees. The first word is a command, from what the user's shell knows;
/// any other word, or one with a slash in it, is a path from the thread's folder. A folder gets its
/// slash and a file its space; when several match, they're what the list shows.
enum ShellCompletion {
    struct Result: Equatable {
        /// The line with its last word completed as far as it goes.
        let text: String
        /// Every match, when there's more than one, as the last word would read with each.
        let candidates: [String]
    }

    static func complete(_ line: String, folder: String, commands: [String]) -> Result? {
        let (head, word) = split(line)
        let first = head.trimmingCharacters(in: .whitespaces).isEmpty
        if first, !word.isEmpty, !word.contains("/"), !word.hasPrefix("~") {
            let names = Array(Set(commands.filter { $0.hasPrefix(word) })).sorted()
            return finish(head: head, word: word, matches: names.map { (escape($0), false) })
        }
        return path(word, head: head, folder: folder)
    }

    /// A path after an `@` in a message, for Claude, from the thread's folder.
    static func mention(_ line: String, folder: String) -> Result? {
        let (head, word) = split(line)
        guard word.hasPrefix("@") else { return nil }
        guard let result = path(String(word.dropFirst()), head: head + "@", folder: folder) else { return nil }
        return Result(text: result.text, candidates: result.candidates.map { "@" + $0 })
    }

    private static func path(_ word: String, head: String, folder: String) -> Result? {
        let typed = unescape(word)
        let slash = typed.lastIndex(of: "/")
        let directory = slash.map { String(typed[...$0]) } ?? ""
        let prefix = slash.map { String(typed[typed.index(after: $0)...]) } ?? typed
        let expanded = directory.hasPrefix("~") ? NSHomeDirectory() + directory.dropFirst() : directory
        let base = expanded.hasPrefix("/") ? expanded : (folder as NSString).appendingPathComponent(expanded)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.isEmpty ? "/" : base) else { return nil }
        let visible = names.filter { prefix.hasPrefix(".") || !$0.hasPrefix(".") }
        var matches = visible.filter { $0.hasPrefix(prefix) }
        if matches.isEmpty { matches = visible.filter { $0.lowercased().hasPrefix(prefix.lowercased()) } }
        let entries = matches.sorted().map { name -> (String, Bool) in
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: (base as NSString).appendingPathComponent(name), isDirectory: &isFolder)
            return (escape(directory) + escape(name), isFolder.boolValue)
        }
        return finish(head: head, word: word, matches: entries)
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
        return Result(text: head + longer, candidates: matches.map { $0.word + ($0.folder ? "/" : "") })
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
