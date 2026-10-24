import Foundation
import SwiftUI

/// What a later agent's task took from an earlier agent's result: the runs of whole words, 24
/// characters or more, the two have in common. Words are compared as they are and what lies
/// between them without its whitespace or backticks, so a result the script reflowed or
/// indented, a structured one it printed again with spaces, or a line shown without its
/// Markdown, still matches.
enum Handoff {
    static let least = 24

    struct Runs: Equatable {
        /// Where they are in the task, in order, none overlapping.
        var task: [Range<String.Index>] = []
        /// Where they are in the result.
        var result: [Range<String.Index>] = []

        var isEmpty: Bool { task.isEmpty }
    }

    static func runs(task: String, result: String) -> Runs {
        let a = Words(task), b = Words(result)
        guard !a.words.isEmpty, !b.words.isEmpty else { return Runs() }
        var at: [Substring: [Int]] = [:]
        for (j, word) in b.words.enumerated() { at[word, default: []].append(j) }
        var found = Runs()
        for i in a.words.indices {
            guard let places = at[a.words[i]] else { continue }
            for j in places {
                // Only from where a common run starts, so each is walked once.
                if i > 0, j > 0, a.words[i - 1] == b.words[j - 1], a.gaps[i] == b.gaps[j] { continue }
                var n = 1
                while i + n < a.words.count, j + n < b.words.count,
                      a.words[i + n] == b.words[j + n], a.gaps[i + n] == b.gaps[j + n] {
                    n += 1
                }
                let (inTask, inResult) = widened(a.ranges[i].lowerBound..<a.ranges[i + n - 1].upperBound, in: task,
                                                 b.ranges[j].lowerBound..<b.ranges[j + n - 1].upperBound, in: result)
                guard task[inTask].count >= least else { continue }
                found.task.append(inTask)
                found.result.append(inResult)
            }
        }
        found.task = merged(found.task)
        found.result = merged(found.result)
        return found
    }

    /// The task as its well shows it, the matched runs in ink and the rest faint. A long task whose
    /// first run lies past what eight lines hold starts at that run's line, or just before it.
    static func well(_ task: String, runs: [Range<String.Index>]) -> AttributedString {
        var start = task.startIndex
        if let first = runs.first?.lowerBound, task.distance(from: start, to: first) > 200 {
            let line = task[..<first].lastIndex(of: "\n").map(task.index(after:)) ?? start
            if task.distance(from: line, to: first) <= 200 {
                start = line
            } else {
                let near = task.index(first, offsetBy: -80)
                start = task[near..<first].firstIndex(where: \.isWhitespace).map(task.index(after:)) ?? near
            }
        }
        var shown = AttributedString(start > task.startIndex ? "…" : "")
        shown.foregroundColor = Color.white.opacity(0.34)
        shown.append(inked(task, from: start, runs: runs))
        return shown
    }

    /// An agent's task whole, as it opens the agent's transcript: faint, and in ink what it took
    /// from the results before it.
    static func task(_ task: String, runs: [Range<String.Index>]) -> AttributedString {
        inked(task, from: task.startIndex, runs: merged(runs))
    }

    /// The task from `start`, past its leading whitespace, faint with the runs in ink.
    private static func inked(_ task: String, from start: String.Index, runs: [Range<String.Index>]) -> AttributedString {
        var start = start
        while start < task.endIndex, task[start].isWhitespace { start = task.index(after: start) }
        let end = task[start...].lastIndex { !$0.isWhitespace }.map(task.index(after:)) ?? start
        var rest = AttributedString(task[start..<end])
        rest.foregroundColor = Color.white.opacity(0.34)
        for run in runs where run.upperBound > start && run.lowerBound < end {
            let clipped = max(run.lowerBound, start)..<min(run.upperBound, end)
            let offset = task.distance(from: start, to: clipped.lowerBound)
            let lower = rest.index(rest.startIndex, offsetByCharacters: offset)
            let upper = rest.index(lower, offsetByCharacters: task.distance(from: clipped.lowerBound, to: clipped.upperBound))
            rest[lower..<upper].foregroundColor = Ink.primary
        }
        return rest
    }

    /// A source's result line, dimmed to 34% where the recipient's task took its words.
    static func source(_ line: String, task: String) -> AttributedString {
        var shown = AttributedString(line)
        shown.foregroundColor = Ink.secondary
        for run in runs(task: task, result: line).result {
            let lower = shown.index(shown.startIndex, offsetByCharacters: line.distance(from: line.startIndex, to: run.lowerBound))
            let upper = shown.index(lower, offsetByCharacters: line.distance(from: run.lowerBound, to: run.upperBound))
            shown[lower..<upper].foregroundColor = Color.white.opacity(0.34)
        }
        return shown
    }

    /// A text's words, letters, digits and underscores, with what lies before each.
    private struct Words {
        var words: [Substring] = []
        var ranges: [Range<String.Index>] = []
        /// What's between a word and the one before it, without whitespace or Markdown's code and
        /// emphasis marks, which a result's first line on its card has lost.
        var gaps: [Substring] = []

        init(_ text: String) {
            var i = text.startIndex
            var gap = i
            while i < text.endIndex {
                guard Self.inWord(text[i]) else {
                    i = text.index(after: i)
                    continue
                }
                var end = text.index(after: i)
                while end < text.endIndex, Self.inWord(text[end]) { end = text.index(after: end) }
                gaps.append(Substring(text[gap..<i].filter { !$0.isWhitespace && $0 != "`" && $0 != "*" }))
                words.append(text[i..<end])
                ranges.append(i..<end)
                i = end
                gap = end
            }
        }

        static func inWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    }

    /// A run of words taken out over the stops and brackets both sides share around it, so a
    /// sentence matched reads to its full stop. Quotes stay out: a structured result's are its own.
    private static func widened(_ a: Range<String.Index>, in task: String,
                                _ b: Range<String.Index>, in result: String) -> (Range<String.Index>, Range<String.Index>) {
        var (aLow, aHigh, bLow, bHigh) = (a.lowerBound, a.upperBound, b.lowerBound, b.upperBound)
        while aHigh < task.endIndex, bHigh < result.endIndex, task[aHigh] == result[bHigh], ".,;:!?)]}".contains(task[aHigh]) {
            aHigh = task.index(after: aHigh)
            bHigh = result.index(after: bHigh)
        }
        while aLow > task.startIndex, bLow > result.startIndex {
            let (p, q) = (task.index(before: aLow), result.index(before: bLow))
            guard task[p] == result[q], "([{".contains(task[p]) else { break }
            (aLow, bLow) = (p, q)
        }
        return (aLow..<aHigh, bLow..<bHigh)
    }

    private static func merged(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, range.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }
}
