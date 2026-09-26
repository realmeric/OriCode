import AppKit
import MarkdownUI
import SwiftUI
import Testing
@testable import OriCode

@MainActor
struct ReplyTests {
    static let text = """
    # Title

    A paragraph with `code` and a [link](App/Foo.swift),
    and a second line.

    - one
    - two

    1. loose

    2. list

       with a second paragraph

    ```swift
    let a = 1

    let b = 2
    ```
    Straight after the fence.
    | a | b |
    |---|---|
    | 1 | 2 |

    > quoted
    > twice

    ---

    Setext
    ======

    ```
    still open
    """

    @Test func blocksAreCutWhereEachTopLevelBlockStarts() throws {
        let blocks = Reply.split(Self.text)
        try #require(blocks.count == 11)
        #expect(blocks.joined() == Self.text)
        #expect(blocks[2] == "- one\n- two\n\n")
        #expect(blocks[3].hasPrefix("1. loose") && blocks[3].hasSuffix("with a second paragraph\n\n"))
        #expect(blocks[4] == "```swift\nlet a = 1\n\nlet b = 2\n```\n")
        #expect(blocks[5] == "Straight after the fence.\n")
        #expect(blocks[6].hasPrefix("| a | b |"))
        #expect(blocks[9] == "Setext\n======\n\n")
        #expect(blocks[10] == "```\nstill open")
    }

    @Test func aLinkDefinedInOneBlockKeepsTheReplyWhole() {
        let text = "See [the file][f].\n\n[f]: App/Foo.swift\n\nMore."
        #expect(Reply.split(text) == [text])
        #expect(Reply.split("") == [])
    }

    /// The blocks laid out apart come to the height of the same text in one Markdown, which only
    /// holds if they're spaced as MarkdownUI spaces them.
    @Test func blocksAreSpacedAsOneMarkdownSpacesThem() async throws {
        let text = Self.text + "\n```\n\n### Last\n\nDone."
        func height(_ view: some View) async throws -> CGFloat {
            let host = NSHostingView(rootView: view.frame(width: 640).environment(\.colorScheme, .dark))
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 2000)
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            return host.fittingSize.height
        }
        let whole = try await height(
            Markdown(text)
                .markdownTheme(.glass)
                .markdownSoftBreakMode(.lineBreak)
                .markdownCodeSyntaxHighlighter(TranscriptCodeHighlighter.shared)
                .frame(maxWidth: .infinity, alignment: .leading))
        let apart = try await height(Reply(id: UUID(), text: text, live: false))
        #expect(whole > 400)
        #expect(abs(whole - apart) < 0.5)
    }
}
