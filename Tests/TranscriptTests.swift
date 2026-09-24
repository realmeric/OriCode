import Foundation
import Testing
@testable import OriCode

struct ToolRunTests {
    private static func tool(_ name: String, _ input: JSON = [:], id: String = UUID().uuidString) -> Item {
        .tool(id: UUID(), call: ToolCall(toolUseId: id, name: name, input: input))
    }

    private static func read(_ path: String) -> Item { tool("Read", ["file_path": .string(path)]) }
    private static func bash() -> Item { tool("Bash", ["command": "make test"]) }
    private static func text() -> Item { .text(id: UUID(), text: "Here's what I found.") }
    private static func thinking() -> Item { .thinking(id: UUID(), text: "Let me check.") }

    private static func shape(_ entries: [TranscriptEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .run(let items): "run of \(items.count)"
            case .item(.tool): "tool"
            case .item(.thinking): "thinking"
            case .item(.text): "text"
            case .item(.ask): "ask"
            case .item: "other"
            }
        }
    }

    @Test func callsBetweenTwoTextsFoldWithTheirThinking() {
        let items = [Self.text(), Self.thinking(), Self.read("/p/a.swift"), Self.thinking(), Self.bash(), Self.text()]
        let entries = TranscriptEntry.fold(items)
        #expect(Self.shape(entries) == ["text", "run of 4", "text"])
        #expect(entries[1].id == items[1].id)
    }

    @Test func aLoneCallAndThinkingAloneStayItems() {
        let items = [Self.thinking(), Self.text(), Self.bash(), Self.thinking(), Self.text()]
        #expect(Self.shape(TranscriptEntry.fold(items)) == ["thinking", "text", "tool", "thinking", "text"])
    }

    @Test func anAskEndsTheRun() {
        let ask = Item.ask(id: UUID(), ask: PendingAsk(requestId: "r", kind: "permission", tool: "Bash", input: [:], options: nil, state: .allowed))
        let items = [Self.bash(), Self.bash(), ask, Self.bash(), Self.read("/p/a.swift")]
        #expect(Self.shape(TranscriptEntry.fold(items)) == ["run of 2", "ask", "run of 2"])
    }

    @Test func wordsInClaudeCodesOrderWithFilesCountedOnce() {
        let calls = [Self.read("/p/a.swift"), Self.bash(), Self.read("/p/a.swift"), Self.read("/p/b.swift"), Self.bash(), Self.bash(),
                     Self.tool("Grep", ["pattern": "TODO"])]
            .compactMap { item -> ToolCall? in if case .tool(_, let call) = item { call } else { nil } }
        #expect(ToolSummary.run(calls) == "Read 2 files, ran 3 commands, searched for 1 pattern")
    }

    @Test func editsAndTheRest() {
        let calls = [
            ToolCall(toolUseId: "1", name: "Edit", input: ["file_path": "/p/a.swift"]),
            ToolCall(toolUseId: "2", name: "MultiEdit", input: ["file_path": "/p/a.swift"]),
            ToolCall(toolUseId: "3", name: "Write", input: ["file_path": "/p/b.swift"]),
            ToolCall(toolUseId: "4", name: "WebSearch", input: ["query": "swift"]),
            ToolCall(toolUseId: "5", name: "mcp__linear__get_issue", input: [:]),
        ]
        #expect(ToolSummary.run(calls) == "Edited 2 files, searched the web, used 1 tool")
    }
}
