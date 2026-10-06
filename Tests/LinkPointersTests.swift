import AppKit
import MarkdownUI
import SwiftUI
import Testing
@testable import OriCode

/// Where a block's links are in the text MarkdownUI draws for it.
struct LinkSpansTests {
    private func spans(_ markdown: String, lines: Bool = true) -> LinkSpans? {
        LinkSpans.of(markdown, softBreaksAreLines: lines)
    }

    private func ranges(_ markdown: String, lines: Bool = true) -> [Range<Int>]? {
        spans(markdown, lines: lines)?.links.map(\.range)
    }

    @Test func aLinkIsTheCharactersOfItsText() {
        let found = spans("See [the file](App/Foo.swift) for it.")
        #expect(found?.text == ["See the file for it."])
        #expect(found?.links == [.init(line: 0, range: 4..<12, url: URL(string: "App/Foo.swift")!)])
    }

    @Test func twoLinksInOneParagraph() {
        let found = spans("[One](https://one.example) and [two](https://two.example).")
        #expect(found?.links.map(\.range) == [0..<3, 8..<11])
        #expect(found?.links.map(\.url.absoluteString) == ["https://one.example", "https://two.example"])
    }

    @Test func noLinksIsNothingToDo() {
        #expect(spans("Plain words, a file: `App/Foo.swift`.") == nil)
        #expect(spans("No punctuation at all") == nil)
        #expect(spans("") == nil)
    }

    /// What a block's source says before anything is parsed, rendered or laid out: a block that
    /// can hold no link is never handed to `of`.
    @Test func aSourceThatCanHoldALink() {
        for source in ["See [the file](App/Foo.swift).", "Read https://example.com/a first.", "At www.example.com today.",
                       "Write to me@example.com.", "Read <https://example.com>.", "See [the guide].\n\n[the guide]: guide.md"] {
            #expect(LinkSpans.canHold(source), "\(source)")
        }
        for source in ["", "Plain words.", "A file: `App/Foo.swift`, **bold**, 3.5 and a list [1] of things.",
                       "- one\n- two\n- three", "| a | b |\n|---|---|\n| c | d |", "Version 2.0: what's new (and why)", "wwww and w.w.w"] {
            #expect(!LinkSpans.canHold(source), "\(source)")
        }
    }

    /// MarkdownUI hands a block's text on with its escapes read, and written out again the
    /// address that was escaped to be no link is one. The source says so first.
    @Test func anEscapedAddressIsNoLink() {
        for source in ["See www\\.example.com today.", "See http&#58;//x.com today.", "Write to a\\@b.com today.",
                       "See http&colon;//x.com today.", "See www&period;example.com today.", "A [link](x.md) and a \\* star."] {
            #expect(!LinkSpans.canHold(source), "\(source)")
            #expect(LinkPointing.of(source) == .none, "\(source)")
        }
        // An ampersand that starts no character reference.
        #expect(LinkSpans.canHold("[Search](https://example.com/?q=a&page=2) & more"))
    }

    @Test func aBlockStillGrowingWaits() {
        #expect(LinkPointing.of("See [the file](App/Foo.swift).") == .wanted)
        #expect(LinkPointing.of("See [the file](App/Foo.swift).", open: true) == .waiting)
        #expect(LinkPointing.of("Plain words.", open: true) == .none)
    }

    /// A block being written changes its mind once, at its first mark: an escape written after
    /// it leaves the block waiting, and only the whole block is told there's nothing to find.
    @Test func aBlockStillGrowingWaitsWhateverComesNext() {
        let written = ["See", "See [the file](App/Foo.swift)", "See [the file](App/Foo.swift) and a \\* star", "See [the file](App/Foo.swift) and a \\* star &amp; more."]
        #expect(written.map { LinkPointing.of($0, open: true) } == [.none, .waiting, .waiting, .waiting])
        #expect(written.map { LinkPointing.of($0) } == [.none, .wanted, .none, .none])
        #expect(LinkPointing.of("Write to a\\@b.com today.", open: true) == .waiting)
        #expect(LinkPointing.of("Write to a\\@b.com today.") == .none)
    }

    /// MarkdownUI draws raw HTML as the words it's written in, and hands it on as a paragraph of
    /// one text that starts with an escaped `<`. An address in it is no link.
    @Test func anAddressInRawHTMLIsNoLink() {
        for html in ["<p>See https://example.com</p>", "<p>See https://example.com today</p>", "<div>At www.example.com today", "<p>Write to me@example.com today</p>"] {
            let handed = MarkdownContent { Paragraph { html } }.renderMarkdown()
            #expect(handed.hasPrefix("\\<"), "\(handed)")
            #expect(spans(handed) == nil, "\(handed)")
        }
        #expect(spans("  \\<p>See https://example.com today") == nil)
        // The same address in a paragraph's words, and after a `<` that doesn't start them.
        #expect(ranges(MarkdownContent { Paragraph { "See https://example.com today" } }.renderMarkdown()) == [4..<23])
        #expect(ranges("1 \\< 2, see https://example.com today") == [11..<30])
    }

    @Test func aBareAddressIsALink() {
        #expect(ranges("Read https://example.com/a first.") == [5..<26])
        #expect(ranges("Read <https://example.com/a> first.") == [5..<26])
    }

    @Test func whatIsInsideALinkCounts() {
        #expect(ranges("A [**bold** and `code`](x.md) link.") == [2..<15])
        #expect(ranges("**In [bold](x.md)** text") == [3..<7])
    }

    /// The text is counted as a layout counts it, in UTF-16.
    @Test func charactersOutsideTheBasicPlaneAreTwo() {
        #expect(ranges("👍 [ok](x.md)") == [3..<5])
    }

    @Test func aHeadingsLink() {
        #expect(ranges("## The [guide](guide.md)") == [4..<9])
    }

    /// A layout counts from the start of each line the text breaks into. A reply's line break
    /// also makes MarkdownUI drop the spaces that start the next text it writes at the block's
    /// top level, even with a link in between.
    @Test func aBreakStartsTheCountAgain() {
        let markdown = "First line\n[link](x.md) and more"
        #expect(spans(markdown)?.text == ["First line", "linkand more"])
        #expect(spans(markdown)?.links == [.init(line: 1, range: 0..<4, url: URL(string: "x.md")!)])
        #expect(spans(markdown, lines: false)?.text == ["First line link and more"])
        #expect(ranges(markdown, lines: false) == [11..<15])
        #expect(spans("One<br>[two](x.md)")?.links == [.init(line: 1, range: 0..<3, url: URL(string: "x.md")!)])
    }

    @Test func aLinkWithABreakInItIsOneOnEachSide() {
        let found = spans("See [the long\nname](x.md).")
        #expect(found?.text == ["See the long", "name."])
        #expect(found?.links.map(\.line) == [0, 1])
        #expect(found?.links.map(\.range) == [4..<12, 0..<4])
    }

    /// A destination that's no URL is underlined and opens nothing, so it gets no pointer.
    @Test func aLinkThatOpensNothing() {
        #expect(spans("[nowhere]()") == nil)
    }

    /// An image is a character once it loads and none before.
    @Test func anImageInTheTextIsNotGuessedAt() {
        #expect(spans("![alt](a.png) and [a link](x.md)") == nil)
    }

    private func piece(_ character: Int, _ x: CGFloat, _ y: CGFloat) -> LinkSpans.Piece<Int> {
        .init(character: character, frame: CGRect(x: x, y: y, width: 10, height: 12))
    }

    @Test func rectsAreOnePerLinkAndRow() {
        let found = LinkSpans(text: ["abcdef"], links: [.init(line: 0, range: 1..<3, url: URL(string: "a")!), .init(line: 0, range: 4..<6, url: URL(string: "b")!)])
        let rects = found.rects(in: [
            [piece(0, 0, 0), piece(1, 10, 0), piece(2, 20, 0), piece(3, 30, 0), piece(4, 40, 0)],
            [piece(5, 0, 15)],
        ])
        #expect(rects?.map(\.frame) == [
            CGRect(x: 10, y: 0, width: 20, height: 12),
            CGRect(x: 40, y: 0, width: 10, height: 12),
            CGRect(x: 0, y: 15, width: 10, height: 12),
        ])
        #expect(rects?.map(\.link) == [0, 1, 1])
        #expect(rects?.map(\.url.relativeString) == ["a", "b", "b"])
    }

    @Test func aRowThatCountsFromTheStartIsTheNextLine() {
        let found = LinkSpans(text: ["ab", "", "cd"], links: [.init(line: 2, range: 0..<1, url: URL(string: "a")!)])
        let rects = found.rects(in: [[piece(0, 0, 0), piece(1, 10, 0)], [], [piece(0, 0, 30), piece(1, 10, 30)]])
        #expect(rects?.map(\.frame) == [CGRect(x: 0, y: 30, width: 10, height: 12)])
        #expect(rects?.map(\.row) == [2])
    }

    /// A layout's indices are only so far from each other: a line's characters are counted from
    /// where its first row starts, wherever that is.
    @Test func aLayoutCountsFromWhereItLikes() {
        let found = LinkSpans(text: ["abcd", "efgh"], links: [.init(line: 0, range: 3..<4, url: URL(string: "a")!), .init(line: 1, range: 1..<2, url: URL(string: "b")!)])
        let rects = found.rects(in: [
            [piece(40, 0, 0), piece(41, 10, 0)],
            [piece(42, 0, 15), piece(43, 10, 15)],
            [piece(7, 0, 30), piece(8, 10, 30), piece(9, 20, 30), piece(10, 30, 30)],
        ])
        #expect(rects?.map(\.frame) == [CGRect(x: 10, y: 15, width: 10, height: 12), CGRect(x: 10, y: 30, width: 10, height: 12)])
        #expect(rects?.map(\.link) == [0, 1])
    }

    /// A layout of some other text puts the pointer nowhere.
    @Test func aLayoutThatIsNotTheTextWritten() {
        let found = LinkSpans(text: ["abcdef"], links: [.init(line: 0, range: 1..<3, url: URL(string: "a")!)])
        #expect(found.rects(in: [(0..<9).map { piece($0, 0, 0) }]) == nil)
        #expect(found.rects(in: [(0..<2).map { piece($0, 0, 0) }]) == nil)
        #expect(found.rects(in: [(0..<6).map { piece($0, 0, 0) }, (0..<6).map { piece($0, 0, 15) }]) == nil)
        #expect(found.rects(in: [[LinkSpans.Piece<Int>]]()) == nil)
        #expect(found.rects(in: [(0..<6).map { piece($0, 0, 0) }]) != nil)
    }

    /// One glyph draws all of an emoji, so the line ends before its last unit.
    @Test func aLineThatEndsInAnEmoji() {
        let found = LinkSpans(text: ["ab👍"], links: [.init(line: 0, range: 0..<1, url: URL(string: "a")!)])
        #expect(found.rects(in: [(0..<3).map { piece($0, 0, 0) }])?.count == 1)
    }
}

/// The same, through MarkdownUI and the layout SwiftUI makes of its text.
@MainActor
struct LinkPointersTests {
    /// The link rectangles of the one block of `markdown`, laid out `width` wide as a reply lays
    /// it out, and the rows of its text.
    private func layout(_ markdown: String, width: CGFloat) async throws -> (rects: [LinkSpans.Rect]?, rows: [CGRect]) {
        final class Found { var layouts: [Text.Layout] = [] }
        let found = Found()
        let view = Markdown(markdown)
            .markdownTheme(.glass)
            .markdownSoftBreakMode(.lineBreak)
            .environment(\.softBreaksAreLines, true)
            .frame(width: width, alignment: .leading)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                let _ = found.layouts = layouts.map(\.layout)
                Color.clear
            }
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let text = try #require(found.layouts.first)
        #expect(found.layouts.count == 1)
        let spans = try #require(LinkSpans.of(MarkdownContent(markdown).renderMarkdown(), softBreaksAreLines: true))
        return (spans.rects(in: text), text.map(\.typographicBounds.rect))
    }

    @Test func aLinkOnOneLine() async throws {
        let (rects, rows) = try await layout("See [the file](App/Foo.swift) for it.", width: 600)
        let rect = try #require(rects?.first)
        #expect(rects?.count == 1)
        #expect(rows.count == 1)
        // After "See " and before " for it.", on the line.
        #expect(rect.frame.minX > 15 && rect.frame.maxX < rows[0].maxX - 20)
        #expect(rect.frame.width > 30 && rect.frame.width < 80)
        #expect(rows[0].insetBy(dx: -1, dy: -1).contains(rect.frame))
    }

    @Test func aLinkThatWrapsIsARectOnEachRow() async throws {
        let (rects, rows) = try await layout("Start with [a link whose text is long enough to wrap onto the line below](https://example.com) and end.", width: 300)
        let found = try #require(rects)
        #expect(rows.count == 2)
        #expect(found.map(\.row) == [0, 1])
        #expect(found.allSatisfy { $0.link == 0 })
        // The first runs to the end of its row, the second starts the next and stops before " and end."
        #expect(found[0].frame.minX > 30)
        #expect(abs(found[0].frame.maxX - rows[0].maxX) < 1)
        #expect(found[1].frame.minX < 1)
        #expect(found[1].frame.minY >= found[0].frame.maxY - 1)
        #expect(found[1].frame.maxX < rows[1].maxX - 20)
    }

    @Test func twoLinksAreTwoRects() async throws {
        let (rects, _) = try await layout("[One](https://one.example) and 👍 [two](https://two.example), ~~struck~~ **bold** with a `code` word 👍", width: 600)
        let found = try #require(rects)
        #expect(found.map(\.link) == [0, 1])
        #expect(found[0].frame.minX < 1)
        #expect(found[1].frame.minX > found[0].frame.maxX + 30)
    }

    /// A reply's line break, after which the layout counts from nothing again.
    @Test func aLinkAfterALineBreak() async throws {
        let (rects, rows) = try await layout("First line\n[link](x.md) and more", width: 600)
        let found = try #require(rects)
        #expect(rows.count == 2)
        #expect(found.map(\.row) == [1])
        #expect(found[0].frame.minX < 1)
        #expect(found[0].frame.width > 15 && found[0].frame.width < 40)
    }

    @Test func aHeadingsLink() async throws {
        let (rects, _) = try await layout("## The [guide](guide.md)", width: 600)
        #expect(rects?.count == 1)
    }

    /// The reply as the transcript draws it, in a window that takes clicks.
    private func window(_ markdown: String, live: Bool = false, opened: @escaping (URL) -> Void = { _ in }) async throws -> NSWindow {
        try await window(
            Reply(id: UUID(), text: markdown, live: live)
                .frame(width: 600, height: 200, alignment: .topLeading)
                .environment(\.openURL, OpenURLAction { url in
                    opened(url)
                    return .handled
                })
        )
    }

    private func window(_ view: some View) async throws -> NSWindow {
        let host = ClickHost(rootView: view.environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        let window = ClickWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        return window
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    /// Mouse events at a point counted from the window's top left, as a reply's layout counts.
    private func send(_ types: [NSEvent.EventType], to window: NSWindow, x: CGFloat, y: CGFloat, clicks: Int = 1) {
        for type in types {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 200 - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
            window.sendEvent(event)
        }
    }

    /// The view a mouse event at the point is sent to.
    private func hit(_ window: NSWindow, x: CGFloat, y: CGFloat) throws -> NSView? {
        let content = try #require(window.contentView)
        let point = NSPoint(x: x, y: 200 - y)
        return content.hitTest(content.superview?.convert(point, from: nil) ?? point)
    }

    private final class Seen {
        var urls: [String] = []
    }

    /// The titles of the menu a right-click at the point would open. A right-click sent would
    /// open it and wait in it for a pointer that isn't coming, so the view it would go to is
    /// asked for its menu instead.
    private func menu(_ window: NSWindow, x: CGFloat, y: CGFloat) throws -> NSMenu? {
        let right = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: x, y: 200 - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        return try hit(window, x: x, y: y)?.menu(for: right)
    }

    private static let linkMenu = ["Open Link", "Copy Link"]

    /// Whether a link's area is under the point: nothing else in a reply has its menu.
    private func linked(_ window: NSWindow, x: CGFloat, y: CGFloat) throws -> Bool {
        try menu(window, x: x, y: y)?.items.map(\.title) == Self.linkMenu
    }

    /// Where a reply's link areas are, counted from the window's top left and found by asking
    /// every few points of it, so to within that many points.
    private func areas(_ markdown: String, live: Bool = false) async throws -> [CGRect] {
        let window = try await window(markdown, live: live)
        defer { close(window) }
        var found: [CGRect] = []
        for y in stride(from: CGFloat(1), to: 200, by: 3) {
            var run: ClosedRange<CGFloat>?
            for x in stride(from: CGFloat(1), through: 601, by: 2) {
                if x < 600, try linked(window, x: x, y: y) {
                    run = (run?.lowerBound ?? x)...x
                } else if let ended = run {
                    run = nil
                    let rect = CGRect(x: ended.lowerBound, y: y, width: ended.upperBound - ended.lowerBound, height: 3)
                    // The row below one already found is more of the same area.
                    if let index = found.firstIndex(where: { $0.maxY == y && $0.minX <= rect.maxX && rect.minX <= $0.maxX }) {
                        found[index] = found[index].union(rect)
                    } else {
                        found.append(rect)
                    }
                }
            }
        }
        return found
    }

    private let markdown = "See [the file](App/Foo.swift) for it."

    /// The link's rectangle in `markdown`, and a window with the reply in it that says what it
    /// opened.
    private func reply(live: Bool = false) async throws -> (rect: CGRect, window: NSWindow, seen: Seen) {
        let rect = try #require(try await layout(markdown, width: 600).rects?.first).frame
        let seen = Seen()
        let window = try await window(markdown, live: live) { seen.urls.append($0.relativeString) }
        return (rect, window, seen)
    }

    /// The link's area lies over its words and no others.
    @Test func theAreaIsOverALinksWords() async throws {
        let (rect, window, _) = try await reply()
        defer { close(window) }
        #expect(rect.width > 30 && rect.height > 10)
        for (x, y) in [(rect.minX + 2, rect.midY), (rect.midX, rect.midY), (rect.maxX - 2, rect.midY), (rect.midX, rect.minY + 2), (rect.midX, rect.maxY - 2)] {
            #expect(try linked(window, x: x, y: y), "\(x) \(y)")
        }
        for (x, y) in [(rect.minX - 3, rect.midY), (rect.maxX + 3, rect.midY), (rect.midX, rect.maxY + 3), (300, rect.midY), (rect.midX, 100)] {
            #expect(try !linked(window, x: x, y: y), "\(x) \(y)")
        }
        // The words beside it are still the text's, with the text's own menu.
        let beside = try #require(try menu(window, x: rect.minX - 3, y: rect.midY))
        #expect(beside.items.contains { $0.title == "Copy" })
    }

    /// A link that wraps has an area on each row, and either opens it.
    @Test func aWrappedLinkIsAnAreaOnEachRow() async throws {
        let markdown = "Start with [a link whose text is long enough to wrap onto the line below, which at this width takes a good many more words than one would think](https://example.com) and end."
        let rects = try #require(try await layout(markdown, width: 600).rects)
        #expect(rects.map(\.row) == [0, 1])
        let seen = Seen()
        let window = try await window(markdown) { seen.urls.append($0.absoluteString) }
        defer { close(window) }
        for rect in rects {
            #expect(try linked(window, x: rect.frame.midX, y: rect.frame.midY))
        }
        send([.leftMouseDown, .leftMouseUp], to: window, x: rects[1].frame.midX, y: rects[1].frame.midY)
        try await Task.sleep(for: .milliseconds(250))
        #expect(seen.urls == ["https://example.com"])
    }

    /// A click on a link's words opens it, once, through the action the transcript set. The same
    /// reply still being written has no area over the link, and the click made here, which is
    /// no click to the text under it, opens nothing: it's the area that opened it.
    @Test func aClickOpensTheLink() async throws {
        let (rect, window, seen) = try await reply()
        defer { close(window) }
        send([.leftMouseDown, .leftMouseUp], to: window, x: rect.midX, y: rect.midY)
        try await Task.sleep(for: .milliseconds(250))
        #expect(seen.urls == ["App/Foo.swift"])

        let (_, growing, none) = try await reply(live: true)
        defer { close(growing) }
        #expect(try !linked(growing, x: rect.midX, y: rect.midY))
        send([.leftMouseDown, .leftMouseUp], to: growing, x: rect.midX, y: rect.midY)
        try await Task.sleep(for: .milliseconds(250))
        #expect(none.urls == [])
    }

    /// A double-click is two taps and opens the link once. A click after the double-click's time
    /// is a click of its own.
    @Test func aDoubleClickOpensTheLinkOnce() async throws {
        let (rect, window, seen) = try await reply()
        defer { close(window) }
        send([.leftMouseDown, .leftMouseUp], to: window, x: rect.midX, y: rect.midY)
        send([.leftMouseDown, .leftMouseUp], to: window, x: rect.midX, y: rect.midY, clicks: 2)
        try await Task.sleep(for: .milliseconds(250))
        #expect(seen.urls == ["App/Foo.swift"])
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.2))
        send([.leftMouseDown, .leftMouseUp], to: window, x: rect.midX, y: rect.midY)
        try await Task.sleep(for: .milliseconds(250))
        #expect(seen.urls == ["App/Foo.swift", "App/Foo.swift"])
    }

    /// A press on a link's words that moves before it's let go is no click, and opens nothing.
    @Test func aPressThatMovesOpensNothing() async throws {
        let (rect, window, seen) = try await reply()
        defer { close(window) }
        #expect(rect.width > 16)
        send([.leftMouseDown], to: window, x: rect.midX - 6, y: rect.midY)
        send([.leftMouseDragged], to: window, x: rect.midX, y: rect.midY)
        send([.leftMouseDragged, .leftMouseUp], to: window, x: rect.midX + 6, y: rect.midY)
        try await Task.sleep(for: .milliseconds(250))
        #expect(seen.urls == [])
        // And the next click there still opens it.
        send([.leftMouseDown, .leftMouseUp], to: window, x: rect.midX, y: rect.midY)
        try await Task.sleep(for: .milliseconds(250))
        #expect(seen.urls == ["App/Foo.swift"])
    }

    /// A click on the words beside a link isn't the link's.
    @Test func aClickBesideALinkOpensNothing() async throws {
        let (rect, window, seen) = try await reply()
        defer { close(window) }
        for (x, y) in [(rect.minX - 3, rect.midY), (rect.maxX + 3, rect.midY), (rect.midX, rect.maxY + 3)] {
            send([.leftMouseDown, .leftMouseUp], to: window, x: x, y: y)
            try await Task.sleep(for: .milliseconds(250))
            #expect(seen.urls == [], "\(x) \(y)")
        }
        send([.leftMouseDown, .leftMouseUp], to: window, x: rect.minX + 2, y: rect.midY)
        try await Task.sleep(for: .milliseconds(250))
        #expect(seen.urls == ["App/Foo.swift"])
    }

    /// A right-click on a link's words offers to open it and to copy it.
    @Test func aLinksMenuOpensAndCopies() async throws {
        let (rect, window, seen) = try await reply()
        defer { close(window) }
        let menu = try #require(try menu(window, x: rect.midX, y: rect.midY))
        #expect(menu.items.map(\.title) == Self.linkMenu)
        menu.performActionForItem(at: 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(seen.urls == ["App/Foo.swift"])
    }

    /// Copy Link writes the address, and a file's path as the reply wrote it.
    @Test func aCopiedLinkIsWhatWasWritten() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("LinkPointersTests-\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString("something else", forType: .string)
        for written in ["App/Foo.swift", "https://example.com/a?b=c#d", "../notes/To%20do.md"] {
            LinkArea.copy(try #require(URL(string: written)), to: board)
            #expect(board.string(forType: .string) == written)
            #expect(board.pasteboardItems?.count == 1)
        }
    }

    /// A list's item, a quote's paragraph and a table's cell are blocks of their own inside the
    /// reply's, each with its own text.
    @Test func linksInsideAListAQuoteAndATable() async throws {
        let list = try await areas("- one\n- two [link](a.md) here\n- three")
        #expect(list.count == 1, "\(list)")
        #expect(list.allSatisfy { $0.width > 12 && $0.width < 45 && $0.height > 8 && $0.height < 24 }, "\(list)")
        let quote = try await areas("> Quoted, with [a link](b.md) in it.")
        #expect(quote.count == 1, "\(quote)")
        #expect(quote.allSatisfy { $0.width > 22 && $0.width < 60 }, "\(quote)")
        let table = try await areas("| a | b |\n|---|---|\n| [cell](c.md) | x |\n| y | [other](d.md) |")
        #expect(table.count == 2, "\(table)")
        #expect(table.allSatisfy { $0.width > 12 && $0.width < 50 }, "\(table)")
    }

    /// A reply with no link in it has no area over it.
    @Test func aReplyWithNoLinkHasNoArea() async throws {
        #expect(try await areas("Nothing to open here: `App/Foo.swift`, **bold**.") == [])
        #expect(try await areas("- one\n- two\n- three\n\n| a | b |\n|---|---|\n| c | d |") == [])
        #expect(try await areas("Something to open here: [the file](App/Foo.swift), **bold**.").count == 1)
    }

    /// An address escaped to be no link is drawn as plain words, and gets no area. The same
    /// address unescaped gets one.
    @Test func anEscapedAddressHasNoArea() async throws {
        for markdown in ["See www\\.example.com today.", "See http&#58;//x.com today.", "Write to a\\@b.com today."] {
            #expect(try await areas(markdown) == [], "\(markdown)")
        }
        #expect(try await areas("See www.example.com today.").count == 1)
    }

    /// Raw HTML is drawn as its own words, and an address in them is no link.
    @Test func anAddressInRawHTMLHasNoArea() async throws {
        #expect(try await areas("<p>See https://example.com</p>") == [])
        #expect(try await areas("<p>See https://example.com today</p>") == [])
        #expect(try await areas("<p>See https://example.com today</p>\n\nSee https://example.com today").count == 1)
    }

    /// The block a reply is still writing is laid out again with every word, and waits for its
    /// areas until it's whole.
    @Test func theBlockStillGrowingHasNone() async throws {
        let markdown = "Done with this.\n\nSee [the file](App/Foo.swift) for it."
        #expect(try await areas(markdown, live: true) == [])
        #expect(try await areas("See [one](a.md).\n\nAnd [two](b.md).", live: true).count == 1)
        #expect(try await areas(markdown).count == 1)
    }
}

/// A borderless window that takes clicks as the app's key window does, though the test host isn't
/// the active app.
private final class ClickWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}

private final class ClickHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
