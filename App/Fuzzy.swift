import Foundation

/// Subsequence matching with a score: every query character must appear in order. Matches at
/// the start of a word and runs of consecutive characters score higher; nil means no match.
enum Fuzzy {
    static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let hay = Array(candidate.lowercased())
        var score = 0
        var index = 0
        var previous = -2
        for character in needle {
            guard let found = hay[index...].firstIndex(of: character) else { return nil }
            let wordStart = found == 0 || !(hay[found - 1].isLetter || hay[found - 1].isNumber)
            score += 1
            if wordStart { score += 8 }
            if found == previous + 1 { score += 5 }
            score -= min(found - index, 10) / 2
            previous = found
            index = found + 1
        }
        // Shorter candidates win ties, so "Changes" beats "Show changes for this long thread".
        return score * 4 - hay.count / 8
    }

    static func rank<T>(_ items: [T], by query: String, text: (T) -> String) -> [T] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items
            .compactMap { item in score(query, in: text(item)).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}
