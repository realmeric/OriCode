import Foundation

/// Which words changed inside a changed line. A run of deleted lines is paired line by line
/// with the added run after it, and a pair that is still mostly the same line gets the parts
/// that differ; a pair that isn't gets nothing, since highlighting every word says less than
/// highlighting none.
enum WordDiff {
    /// Character ranges that changed, by the line's index in the hunk.
    static func ranges(in lines: [ReviewLine]) -> [Int: [Range<Int>]] {
        var result: [Int: [Range<Int>]] = [:]
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .deleted else {
                index += 1
                continue
            }
            let deleted = Array(index..<(lines[index...].firstIndex { $0.kind != .deleted } ?? lines.count))
            let afterDeleted = deleted.last! + 1
            let added = Array(afterDeleted..<(lines[afterDeleted...].firstIndex { $0.kind != .added } ?? lines.count))
            for (old, new) in zip(deleted, added) {
                guard let (a, b) = pair(lines[old].text, lines[new].text) else { continue }
                if !a.isEmpty { result[old] = a }
                if !b.isEmpty { result[new] = b }
            }
            index = max(afterDeleted, added.last.map { $0 + 1 } ?? afterDeleted)
        }
        return result
    }

    /// The ranges that differ on each side, or nil when the two lines aren't one line edited.
    static func pair(_ old: String, _ new: String) -> ([Range<Int>], [Range<Int>])? {
        guard old.count <= 600, new.count <= 600, old != new else { return nil }
        let a = tokens(old), b = tokens(new)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.map(\.text).difference(from: a.map(\.text)) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Mostly the same line: most of its non-space text survives, or a short line changed in
        // one place, like a string's value.
        let kept = a.indices.filter { !removed.contains($0) && !a[$0].blank }.reduce(0) { $0 + a[$1].range.count }
        let longest = max(a.filter { !$0.blank }.reduce(0) { $0 + $1.range.count }, b.filter { !$0.blank }.reduce(0) { $0 + $1.range.count })
        let (was, now) = (merge(a, removed), merge(b, inserted))
        guard longest > 0, kept > 0, Double(kept) / Double(longest) >= 0.4 || (was.count <= 1 && now.count <= 1) else { return nil }
        return (was, now)
    }

    private struct Token {
        let text: Substring
        let range: Range<Int>
        let blank: Bool
    }

    /// Words, runs of spaces, and every other character on its own.
    private static func tokens(_ line: String) -> [Token] {
        var tokens: [Token] = []
        var start = line.startIndex, offset = 0
        var kind = 0
        var begun = 0
        func close(at end: String.Index, _ endOffset: Int) {
            guard start < end else { return }
            tokens.append(Token(text: line[start..<end], range: begun..<endOffset, blank: kind == 2))
        }
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let now = character.isLetter || character.isNumber || character == "_" ? 1 : character.isWhitespace ? 2 : 3
            if now != kind || now == 3 {
                close(at: index, offset)
                start = index
                begun = offset
                kind = now
            }
            index = line.index(after: index)
            offset += 1
        }
        close(at: line.endIndex, offset)
        return tokens
    }

    /// The changed tokens as ranges, neighbours joined, a space between two changed words too.
    private static func merge(_ tokens: [Token], _ changed: Set<Int>) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for index in tokens.indices where changed.contains(index) {
            let range = tokens[index].range
            if let last = ranges.last, last.upperBound == range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else if let last = ranges.last, index >= 2, changed.contains(index - 2), tokens[index - 1].blank,
                      last.upperBound == tokens[index - 1].range.lowerBound
            {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }
}
