import Foundation

/// What a thread has said so far, for the agent it moves to: its session has none of the old one's
/// history. What was asked and answered, each tool call as one line, and nothing else, cut to a
/// size the new agent takes with the latest exchange kept whole. The engine puts it ahead of the
/// first message in its own words (`handover` on `send`); the transcript never shows it.
enum Handover {
    /// Characters, about ten thousand tokens: what any model an agent offers takes with room to
    /// work, since the models' own windows aren't in what the agents list.
    static let cap = 40_000
    /// What an older message or reply keeps of itself. The latest exchange keeps all of it.
    static let older = 1_200
    /// A tool call's line.
    static let line = 160

    private struct Entry {
        var text: String
        /// Whether it belongs to the latest exchange, from the last message the user sent.
        var recent = false
    }

    /// The thread as text, or nothing when the user has said nothing yet. `items` are what came
    /// before the message being sent.
    static func text(from items: [Item], cwd: String, cap: Int = Handover.cap) -> String {
        var entries: [Entry] = []
        let lastUser = items.lastIndex(where: \.startsTurn)
        for (index, item) in items.enumerated() {
            let recent = lastUser.map { index >= $0 } ?? false
            switch item {
            case .user(_, let text, let images, _):
                let extra = images.isEmpty ? "" : " [\(images.count) image\(images.count == 1 ? "" : "s")]"
                entries.append(Entry(text: "User: \(text)\(extra)", recent: recent))
            case .text(_, let text) where !text.isEmpty:
                // The parts of one reply, split by the tools it ran between them, read as one voice.
                if let last = entries.last, last.text.hasPrefix("Assistant: "), last.recent == recent, index > 0, case .text = items[index - 1] {
                    entries[entries.count - 1].text += "\n\(text)"
                } else {
                    entries.append(Entry(text: "Assistant: \(text)", recent: recent))
                }
            case .tool(_, let call):
                var line = ToolSummary.line(for: call, cwd: cwd).replacingOccurrences(of: "\n", with: " ")
                if line.count > Self.line { line = String(line.prefix(Self.line)) + "…" }
                entries.append(Entry(text: "Tool: \(line)", recent: recent))
            default:
                break
            }
        }
        guard entries.contains(where: { $0.text.hasPrefix("User: ") }) else { return "" }
        // Newest first, until the cap is reached: the latest exchange whole (each part cut only when
        // it alone would fill the cap), older parts cut to what an older part keeps.
        // The note that something is left out is counted in the cap.
        var kept: [String] = []
        var used = 60
        var left = 0
        for entry in entries.reversed() {
            let limit = entry.recent ? cap / 2 : Self.older
            var text = entry.text
            if text.count > limit { text = String(text.prefix(limit)) + "…" }
            if used + text.count + 1 > cap {
                left = entries.count - kept.count
                break
            }
            kept.append(text)
            used += text.count + 1
        }
        let cut = left > 0 ? ["[\(left) earlier parts of the thread are left out.]"] : []
        return (cut + kept.reversed()).joined(separator: "\n")
    }
}
