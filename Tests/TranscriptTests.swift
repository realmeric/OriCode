import Foundation
import SwiftData
import SwiftUI
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

    @Test func thinkingIsLeftOutWhenSettingsSaySo() {
        let items: [Item] = [.thinking(id: UUID(), text: "Hm."), .text(id: UUID(), text: "Done.")]
        #expect(TranscriptEntry.fold(items).count == 2)
        let shown = TranscriptEntry.fold(items, thinking: false)
        #expect(shown.count == 1)
        if case .item(.text) = shown[0] {} else { Issue.record("the reply should be what's left") }
    }
}

/// A message pasted a megabyte long, which froze the window and left its thread hard to open
/// (REA-233): what the transcript draws of it, and what ⌘K and the title read of it.
@MainActor
struct LongMessageTests {
    /// One line of 1.6 million characters, the shape of the paste in REA-233.
    private static let pasted = String(repeating: "ÇAĞRI ÜZÜMLÜ ", count: 123_077)

    private final class Found { var layouts: [Text.Layout] = [] }

    /// Your message in its row at 700pt, not yet laid out, and what its Texts were laid out as
    /// once it is.
    private static func row(_ text: String) throws -> (NSView, Found) {
        let found = Found()
        let model = AppModel(container: try TestStore.memory())
        let view = ItemView(item: .user(id: UUID(), text: text), cwd: "/tmp", listening: nil, live: false)
            .frame(width: 700)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                let _ = found.layouts = layouts.map(\.layout)
                Color.clear
            }
            .environment(model)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 800)
        return (host, found)
    }

    private static func layouts(_ host: NSView, _ found: Found) async throws -> [Text.Layout] {
        for _ in 0..<5 where found.layouts.isEmpty {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        return found.layouts
    }

    @Test func itsBubbleShowsItsFirstLinesLaidOutAtOnce() async throws {
        let (host, found) = try Self.row(Self.pasted)
        // Laid out whole it took a second, at every layout.
        let took = ContinuousClock().measure { host.layoutSubtreeIfNeeded() }
        #expect(took < .milliseconds(250))
        #expect(try await Self.layouts(host, found).map(\.count).max() == 12)
    }

    /// What a folded message hands its Text (K-280): of a pasted file, its first twelve lines and
    /// the thirteenth, so the twelfth ends in an ellipsis; of one long line, twelve rows of 200
    /// characters at most.
    @Test func aFoldedMessageHandsItsTextOnlyWhatItShows() {
        let file = (0..<2_500).map { "line \($0)" }.joined(separator: "\n")
        #expect(MessageText.fold(Substring(file)) == (0..<13).map { "line \($0)" }.joined(separator: "\n"))
        #expect(MessageText.fold(Substring(String(repeating: "a step ", count: 30_000))).count == 2_400)
    }

    /// 200,000 characters pasted as lines of code or as one line, as the bench pastes them: what
    /// it's folded to still fills the bubble's twelve rows. One line's twelfth row ends in an
    /// ellipsis; here a line of code takes two rows, and a row that ends where a line does gets
    /// none from TextKit, whatever follows it.
    @Test(arguments: ["\n", " "]) func aLongPasteFillsTwelveRows(between: String) async throws {
        let line = "    let value = items.filter { $0.id == index }.map(\\.name).joined(separator: \", \") // a step"
        let (host, found) = try Self.row(Array(repeating: line, count: 2_100).joined(separator: between))
        let bubble = try #require(try await Self.layouts(host, found).first { $0.count == 12 })
        if between == " " { #expect(bubble.isTruncated) }
    }

    @Test func searchAndTheTitleReadItsHead() throws {
        let container = try TestStore.memory()
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        let chat = Chat(project: project)
        container.mainContext.insert(chat)
        let index = MessageIndex()
        let conversation = Conversation(chat: chat, context: container.mainContext, said: index)
        conversation.userSent(Self.pasted + "\nand the last line")
        #expect(chat.title == String(Self.pasted.prefix(59)).trimmingCharacters(in: .whitespaces) + "…")
        #expect(index.search(["çağrı"], in: [chat.id]).first?.text.length == Item.headLength)
        #expect(index.search(["last"], in: [chat.id]).isEmpty)
        // The thread keeps all of it, which is what goes to the agent.
        #expect(conversation.items.first?.text == Self.pasted + "\nand the last line")
    }
}
