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
        // Each block lays out on whole points, so a reply split in eleven can round a point away;
        // a broken spacing rule is off by a block margin, 8pt or more.
        #expect(abs(whole - apart) < 2)
    }

    @Test func aFencedBlockStopsGrowingAtItsClosingFence() {
        #expect(!Reply.fenced("```swift\nlet a = 1\nlet b"))
        #expect(!Reply.fenced("```swift\nlet a = 1\n``"))
        #expect(Reply.fenced("```swift\nlet a = 1\n```"))
        #expect(Reply.fenced("  ~~~\nlet a = 1\n~~~\n\n"))
        #expect(!Reply.fenced("```swift\nlet a = 1\n~~~"))
        #expect(!Reply.fenced("```swift"))
        #expect(!Reply.fenced("A paragraph\nwith two lines"))
        #expect(!Reply.fenced(""))
    }

    @Test func aBlocksCodeIsWhatTheHighlighterIsAskedFor() {
        #expect(Reply.code(in: "```swift\nlet a = 1\nlet b = 2\n```\n\n")! == ("let a = 1\nlet b = 2", "swift"))
        // A reply that ended inside its block.
        #expect(Reply.code(in: "```swift\nlet a = 1\nlet")! == ("let a = 1\nlet", "swift"))
        #expect(Reply.code(in: "~~~\nplain\n~~~")! == ("plain", ""))
        // The last of a block's, which a list can hold several of.
        #expect(Reply.code(in: "- one\n  ```sh\n  ls\n  ```\n- two\n  ```sh\n  pwd\n  ```")! == ("pwd", "sh"))
        #expect(Reply.code(in: "A paragraph with `code` in it.") == nil)
        #expect(Reply.code(in: "") == nil)
    }

    /// A reply in a window, and how many of its texts can be selected, which AppKit gives a view each.
    @MainActor
    private final class Shown {
        let host: NSHostingView<AnyView>
        let window: NSWindow

        init(_ text: String, live: Bool) {
            host = NSHostingView(rootView: Self.reply(text, live: live))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
        }

        private static let id = UUID()

        static func reply(_ text: String, live: Bool) -> AnyView {
            AnyView(Reply(id: id, text: text, live: live).frame(width: 640).environment(\.colorScheme, .dark))
        }

        func become(_ text: String, live: Bool) { host.rootView = Self.reply(text, live: live) }

        var selectable: Int {
            host.layoutSubtreeIfNeeded()
            func count(_ view: NSView) -> Int {
                (String(describing: type(of: view)).contains("TextInteraction") ? 1 : 0) + view.subviews.map(count).reduce(0, +)
            }
            return count(host)
        }

        /// Whether it comes to have that many, in two seconds: a block is made selectable a frame
        /// after it stops, and code once it's coloured.
        func comes(to count: Int) async throws -> Bool {
            for _ in 0..<100 {
                if selectable == count { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }

        /// What it has after a moment in which nothing more would come.
        func rests() async throws -> Int {
            for _ in 0..<10 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            return selectable
        }
    }

    @Test func everyBlockButTheOneStillGrowingCanBeSelected() async throws {
        let text = "First paragraph.\n\nSecond paragraph.\n\nThe third is still"
        let stored = Shown(text, live: false)
        defer { stored.window.close() }
        // A stored reply waits for nothing.
        #expect(stored.selectable == 3)
        let live = Shown(text, live: true)
        defer { live.window.close() }
        #expect(try await live.rests() == 2)
        let only = Shown("Only this, still", live: true)
        defer { only.window.close() }
        #expect(try await only.rests() == 0)
        let open = Shown("Here:\n\n```swift\nlet a = 1\nlet", live: true)
        defer { open.window.close() }
        #expect(try await open.rests() == 1)
        let ended = Shown("Here:\n\n```swift\nlet a = 1\nlet", live: false)
        defer { ended.window.close() }
        #expect(ended.selectable == 2)
    }

    @Test func aBlockCanBeSelectedOnceItStops() async throws {
        let shown = Shown("First paragraph.\n\nThe second is still", live: true)
        defer { shown.window.close() }
        #expect(try await shown.rests() == 1)
        // The reply moves on to a third block, and the second has stopped.
        shown.become("First paragraph.\n\nThe second is whole.\n\nA third", live: true)
        #expect(try await shown.comes(to: 2))
        // The turn ends.
        shown.become("First paragraph.\n\nThe second is whole.\n\nA third", live: false)
        #expect(try await shown.comes(to: 3))
    }

    /// Claude's last sentence before a long tool input is the reply's last block for as long as
    /// the input takes to write. It has stopped, and reads so.
    @Test func aBlockThatHasPausedCanBeSelectedUntilItGrowsAgain() async throws {
        let shown = Shown("First paragraph.\n\nI'll write [the plan](PLAN.md) now.", live: true)
        defer { shown.window.close() }
        #expect(try await shown.rests() == 1)
        #expect(try await shown.comes(to: 2))
        // A word more and it is growing again, with nothing laid out over it at each delta.
        shown.become("First paragraph.\n\nI'll write [the plan](PLAN.md) now. And", live: true)
        #expect(try await shown.rests() == 1)
        shown.become("First paragraph.\n\nI'll write [the plan](PLAN.md) now. And then", live: true)
        #expect(try await shown.rests() == 1)
        #expect(try await shown.comes(to: 2))
        // The turn moves on and the block stays as it was made.
        shown.become("First paragraph.\n\nI'll write [the plan](PLAN.md) now. And then", live: false)
        #expect(try await shown.rests() == 2)
    }

    /// Code whose fence has closed has nothing left to gain, though the reply hasn't moved on, and
    /// code the reply ended inside has stopped too. Each waits for its colours and no longer.
    @Test func codeCanBeSelectedOnceItIsColoured() async throws {
        let shown = Shown("Here:\n\n```swift\nlet growing = 1\nlet", live: true)
        defer { shown.window.close() }
        #expect(try await shown.rests() == 1)
        shown.become("Here:\n\n```swift\nlet growing = 1\nlet b = 2\n```\n", live: true)
        #expect(try await shown.comes(to: 2))
        let ended = Shown("Here:\n\n```swift\nlet ended = 1\nlet", live: true)
        defer { ended.window.close() }
        #expect(try await ended.rests() == 1)
        ended.become("Here:\n\n```swift\nlet ended = 1\nlet", live: false)
        #expect(try await ended.comes(to: 2))
    }
}

struct CodeCopyTests {
    /// A block wholly below the line keeps its button at its own top right.
    @Test func restsWhileTheBlockIsBelowTheLine() {
        #expect(CodeCopy.travel(top: 300, block: 600, line: 48) == 0)
        #expect(CodeCopy.travel(top: 48, block: 600, line: 48) == 0)
    }

    /// Scrolled past, the button stays on the line for as long as the block has room for it.
    @Test func ridesTheLineDownTheBlock() {
        #expect(CodeCopy.travel(top: -152, block: 600, line: 48) == 200)
        #expect(CodeCopy.travel(top: -2000, block: 600, line: 48) == 600 - CodeCopy.side - 2 * CodeCopy.inset)
    }

    /// A block no taller than the button gives it nowhere to go.
    @Test func staysPutInAOneLineBlock() {
        #expect(CodeCopy.travel(top: -40, block: 44, line: 48) == 2)
        #expect(CodeCopy.travel(top: -40, block: 30, line: 48) == 0)
    }
}
