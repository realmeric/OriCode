import SwiftUI

/// A row of the command center (⌘K): a command, a thread, a project, a choice from a list, or
/// something said in a thread.
struct PaletteItem: Identifiable {
    /// Also the order ties are broken in.
    enum Kind: Int {
        case command, thread, project, choice, message
    }

    let id: String
    let kind: Kind
    let title: String
    var subtitle: String?
    /// Found by a search, never shown.
    var keywords: [String] = []
    var shortcut: String?
    var icon: String?
    /// Threads and projects show the project's badge, and a message shows it by its thread's name.
    var project: Project?
    /// The current model, level or mode in a list.
    var checked = false
    /// Why it can't run now: drawn faint, with this as its line.
    var unavailable: String?
    let action: PaletteAction

    var opensLevel: Bool {
        switch action {
        case .list, .input: true
        case .run, .task: false
        }
    }
}

enum PaletteAction {
    /// Closes the command center, then runs.
    case run(@MainActor () -> Void)
    /// Stays open, saying what it's doing, while it runs; closes once it's done with what it
    /// returns as the note under the composer, and shows an error in place.
    case task(String, @MainActor () async throws -> String?)
    /// A level of its own: a list to pick from, or a line to type.
    case list(PaletteList)
    case input(PaletteInput)
}

struct PaletteList {
    let title: String
    let placeholder: String
    let items: @MainActor () async throws -> [PaletteItem]
    /// A row made of what's typed, when no row is called that: Create branch “name”.
    var typed: (@MainActor (String) -> PaletteItem?)? = nil
    /// The typed row goes first and is what Return runs, and only a row called exactly that, case
    /// and all, stands in for it: a command to run mustn't be swapped for a near match.
    var typedFirst = false
}

struct PaletteInput {
    let title: String
    let placeholder: String
    var initial = ""
    /// The line under the field for what's typed so far; a problem keeps Return from running.
    var hint: @MainActor (String) -> PaletteHint = { _ in .none }
    let submit: @MainActor (String) async throws -> String?
}

enum PaletteHint: Equatable {
    case none
    case info(String)
    case problem(String)
}

/// Where the command center is: the levels open, what's typed at each, and what it's doing.
@MainActor @Observable final class PaletteState {
    struct Level {
        enum Kind {
            case root
            case list(PaletteList)
            case input(PaletteInput)
        }

        var kind: Kind
        var query = ""
        var selected = 0
        var items: [PaletteItem] = []
        var loading = false
    }

    var stack = [Level(kind: .root)]
    /// What a running task is doing, and what went wrong last.
    var busy: String?
    var problem: String?

    var level: Level {
        get { stack[stack.count - 1] }
        set { stack[stack.count - 1] = newValue }
    }

    func reset() {
        stack = [Level(kind: .root)]
        busy = nil
        problem = nil
    }

    func push(_ kind: Level.Kind, query: String = "") {
        stack.append(Level(kind: kind, query: query))
        problem = nil
    }

    /// Back one level; false at the top, where Esc closes the command center instead.
    func pop() -> Bool {
        guard stack.count > 1 else { return false }
        stack.removeLast()
        problem = nil
        return true
    }
}

enum Palette {
    /// A typed search: the rows whose title, words or line match, best first. Rows used lately
    /// come ahead, the choices from inside lists behind, and on a tie commands come before
    /// threads, projects and choices. A blank query keeps the order given.
    static func rank(_ items: [PaletteItem], by query: String, recents: [String] = []) -> [PaletteItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items
            .compactMap { item -> (PaletteItem, Int)? in
                let line = item.kind == .thread || item.kind == .project ? [item.subtitle ?? ""] : []
                guard var score = Fuzzy.score(query, in: ([item.title] + item.keywords + line).joined(separator: " ")) else { return nil }
                if let at = recents.firstIndex(of: item.id) { score += (20 - min(at, 20)) * 2 }
                if item.kind == .choice { score -= 12 }
                return (item, score)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.kind.rawValue < $1.0.kind.rawValue }
            .map(\.0)
    }
}

/// ⌘K's search through what was said. A message holds a query when every word typed is in it,
/// whatever the case or accents, which a subsequence match would find in any long reply.
enum MessageSearch {
    /// The words typed, or none before two characters are.
    static func words(_ query: String) -> [String] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard typed.count >= 2 else { return [] }
        return typed.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Where the earliest of the words is in the text, when every one of them is there.
    static func match(_ words: [String], in text: String) -> Range<String.Index>? {
        let folded = fold(text)
        var earliest: Range<Int>?
        for word in words {
            guard let found = folded.range(of: fold(word), options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
            let from = folded.distance(from: folded.startIndex, to: found.lowerBound)
            let range = from..<(from + folded.distance(from: found.lowerBound, to: found.upperBound))
            if earliest.map({ range.lowerBound < $0.lowerBound }) ?? true { earliest = range }
        }
        return earliest.map { text.index(text.startIndex, offsetBy: $0.lowerBound)..<text.index(text.startIndex, offsetBy: $0.upperBound) }
    }

    /// Whether a text holds every word, the words already folded: MessageIndex's test for each
    /// message, on an NSString because Foundation searches its own strings many times faster.
    static func holds(_ folded: [String], in text: NSString) -> Bool {
        folded.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]).location != NSNotFound }
    }

    /// The dotless ı and dotted İ read as i, which diacritic folding leaves alone, so "kirildi"
    /// finds "kırıldı". One character for one, so offsets carry back to the text.
    static func fold(_ text: String) -> String {
        String(text.map { $0 == "ı" || $0 == "İ" ? "i" : $0 })
    }

    /// The text on one line, about `length` characters of it around the match, cut between words
    /// with … where it's cut; nil when a word isn't there.
    static func snippet(_ words: [String], in text: String, length: Int = 40) -> String? {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty, let found = match(words, in: line) else { return nil }
        let characters = Array(line)
        let from = line.distance(from: line.startIndex, to: found.lowerBound)
        let to = line.distance(from: line.startIndex, to: found.upperBound)
        // A few words before the match and the rest after it, since a line reads on from there.
        var lower = max(0, min(from - 12, characters.count - length))
        var upper = min(characters.count, max(lower + length, to))
        if lower > 0, characters[lower - 1] != " ", let space = characters[lower..<from].firstIndex(of: " ") { lower = space + 1 }
        if upper < characters.count, characters[upper] != " ", let space = characters[to..<upper].lastIndex(of: " ") { upper = space }
        return (lower > 0 ? "…" : "") + String(characters[lower..<upper]) + (upper < characters.count ? "…" : "")
    }
}
