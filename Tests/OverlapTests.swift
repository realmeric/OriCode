import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import OriCode

/// No two words in one place. The whole window is laid out in a window that draws nothing,
/// with everything long a thread can have, each surface is opened over it at three widths, and
/// the accessibility tree is read from the window down, AppKit's own title included, for words
/// drawn over words, a word cut by a surface's edge, a word that runs out of its surface or
/// off the window, and a button or a label squeezed in a surface's top or bottom row.
@MainActor
struct OverlapTests {
    /// Every surface over a titled thread, a pair and a new thread, the drawer pinned and not,
    /// at the narrowest window, the default one and a wide one: 154 states and some forty
    /// seconds. make test walks the 58 where words have the least room, one thread at 720pt and
    /// two at 1180pt, and the rest while scratch/frames/overlap exists, which a card that
    /// touches layout makes before it's called done.
    @Test func noTwoWordsShareAPlace() async throws {
        let stage = try OverlapStage()
        defer { stage.close() }
        var states = 0
        for threads in OverlapStage.Threads.allCases {
            for width in OverlapStage.widths {
                for pinned in [false, true] {
                    for over in OverlapStage.Over.allCases {
                        guard OverlapStage.whole || OverlapStage.quick(width: width, threads: threads) else { continue }
                        guard let state = try await stage.show(width: width, pinned: pinned, threads: threads, over: over) else { continue }
                        states += 1
                        stage.look(state)
                    }
                }
            }
        }
        // A tree with no words in it would pass whatever was drawn.
        #expect(stage.most > 40, "the accessibility tree had \(stage.most) words at most")
        #expect(states == (OverlapStage.whole ? 154 : 58))
        // Under no pointer, so what was read doesn't turn on where one rests.
        #expect(!stage.onScreen)
        for fault in stage.verdict() {
            Issue.record(Comment(rawValue: fault))
        }
    }

    /// The frame Meriç sent on 2026-10-10: a window nobody titled is "Untitled" to AppKit, which
    /// draws the word in the toolbar's row where the review's header says Review. The app's
    /// window hides its title (OriCodeApp) and the stage above gives its own an empty one; this
    /// one doesn't, and reading from the window down is what finds the word.
    @Test func aWindowsOwnTitleIsRead() async throws {
        let stage = try OverlapStage(titled: true)
        defer { stage.close() }
        let state = try #require(try await stage.show(width: 1180, pinned: false, threads: .titled, over: .witness))
        stage.look(state)
        let faults = stage.verdict()
        #expect(faults.contains { $0.contains("“Untitled” and “Review”") || $0.contains("“Review” and “Untitled”") }, "\(faults)")
    }

    /// The drawer that stood aside for the review comes back over it, by the pointer, ⌘1 or a
    /// rename, and the review is no narrower for it.
    @Test func aDrawerCalledBackLiesOverTheReview() async throws {
        let stage = try OverlapStage()
        defer { stage.close() }
        _ = try await stage.show(width: 720, pinned: true, threads: .titled, over: .witness)
        let alone = try #require(stage.read().surfaces.first { $0.name == "Review" })
        #expect(alone.frame.width > 420)
        try await stage.callDrawer()
        let surfaces = stage.read().surfaces
        #expect(surfaces.contains { $0.name == "Threads" })
        #expect(surfaces.first { $0.name == "Review" }?.frame == alone.frame)
    }

    @Test func theLaneStopsShortOfTheReviewsButton() {
        #expect(Island.trail(button: 60, update: false) == Island.side)
        // +12.345 −1.234 makes the button 134pt.
        #expect(Island.trail(button: 134, update: false) == 156)
        #expect(Island.trail(button: 60, update: true) == Island.side)
        #expect(Island.trail(button: 134, update: true) == 186)
    }

    @Test func aNoteIsOneLine() {
        #expect(EngineNote.line("To github.com:realmeric/OriCode.git\n ! [rejected]        main -> main (fetch first)\n\nerror: failed") ==
            "To github.com:realmeric/OriCode.git ! [rejected] main -> main (fetch first) error: failed")
        #expect(EngineNote.line("Widen the window to see both") == "Widen the window to see both")
    }

    @Test func aPinnedDrawerStandsAsideForANarrowReview() throws {
        let container = try TestStore.memory()
        let model = AppModel(container: container)
        // The model writes its pin through to the app's own setting.
        let before = UserDefaults.standard.bool(forKey: "drawerPinned")
        defer { UserDefaults.standard.set(before, forKey: "drawerPinned") }
        model.drawerPinned = true
        model.drawerShown = true
        model.standAside(true)
        #expect(model.drawerPinned && !model.drawerShown)
        // Pinned or not while it's aside, it stays away.
        #expect(!model.drawerDocked && !model.threadsOut)
        // Called back, by the pointer or by ⌘B, it lies over the window and takes no room.
        model.toggleDrawerPin()
        #expect(model.drawerPinned && model.drawerShown && !model.drawerDocked && model.threadsOut)
        model.toggleDrawerPin()
        #expect(!model.drawerPinned && !model.drawerShown)
        model.toggleDrawerPin()
        #expect(model.drawerPinned && model.drawerShown && !model.drawerDocked)
        model.standAside(false)
        #expect(model.drawerPinned && model.drawerShown && model.drawerDocked)
        model.drawerPinned = false
        model.drawerShown = false
        model.standAside(true)
        model.standAside(false)
        #expect(!model.drawerShown)
        withExtendedLifetime(container) {}
    }
}

/// RootView in a window that draws nothing, over a store in memory: two threads with a long
/// title on a long branch, a working tree with wide counts, a three-line draft in each composer
/// and a four-line note under them.
@MainActor
final class OverlapStage {
    static let widths: [CGFloat] = [720, 1180, 1710]

    /// All 154 states, where make test walks 58.
    nonisolated static var whole: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Developer/OriCode/scratch/frames/overlap")
    }

    /// The states with the least room: a thread alone in the narrowest window, and two in the
    /// default one, the narrowest that shows two beside a pinned drawer.
    static func quick(width: CGFloat, threads: Threads) -> Bool {
        threads == .pair ? width == 1180 : width == 720
    }

    enum Threads: String, CaseIterable {
        case titled = "a titled thread", pair = "two threads", new = "a new thread"
    }

    enum Over: String, CaseIterable {
        case nothing = "nothing open", command = "the command center", heads = "the heads", files = "the file finder"
        case side = "the side question", pull = "the pull request", witness = "the review", legacy = "the Legacy review"
        case file = "a file", block = "a terminal"
    }

    /// A word on the glass: a text, a button or a field, where it shows.
    struct Word {
        let name: String
        let role: String
        let frame: CGRect
        /// The surface it's in, or nil for the window's own: the toolbar's row, a column's title,
        /// the composers and the note.
        let over: Int?
        /// In a transcript, which a surface covers on purpose.
        let transcript: Bool
        /// Clipped by a scroll view, so not all of it has to show.
        let scrolls: Bool
        let place: [Int]
    }

    struct Surface {
        let name: String
        let frame: CGRect
    }

    private let container: ModelContainer
    private let model: AppModel
    private let window: NSWindow
    private let defaults: UserDefaults
    private let suite = "OverlapTests-\(UUID().uuidString)"
    private let titled: Chat
    private let other: Chat
    private var draft: Chat?
    private var block: ShellBlock?
    /// Molten's own setting, which the model writes through to and the stage puts back.
    private let pinnedBefore = UserDefaults.standard.bool(forKey: "drawerPinned")
    /// The most words any state had.
    private(set) var most = 0
    /// Each fault in the order it was met, with the first state that had it and how many did.
    private var found: [(fault: String, first: String, count: Int)] = []
    /// A surface's buttons, menus and labels wherever they were seen, by surface and name: the
    /// widest and the shortest each was, which is each with the room it wants.
    private var roomy: [String: CGSize] = [:]
    private var seen: [(key: String, name: String, size: CGSize, state: String)] = []
    private var looked = 0
    private let began = Date.now
    private var dump = ""

    private static let branch = "meric/rea-215-the-transcripts-diff-reads"
    private static let note = "To github.com:realmeric/OriCode.git\n ! [rejected]        main -> main (fetch first)\nerror: failed to push some refs to 'github.com:realmeric/OriCode.git'\nhint: Updates were rejected because the remote contains work that you do not have locally."

    init(titled windowTitled: Bool = false) throws {
        container = try TestStore.memory()
        let project = Project(name: "alpha", path: FileManager.default.temporaryDirectory.path)
        container.mainContext.insert(project)
        titled = Chat(project: project, title: "Keep the composer's draft with its thread when another opens")
        other = Chat(project: project, title: "Make the review read git once for both of the two columns")
        for (index, chat) in [titled, other].enumerated() {
            chat.started = true
            chat.sessionId = "s\(index)"
            chat.position = Double(index)
            container.mainContext.insert(chat)
        }
        try container.mainContext.save()
        model = AppModel(container: container)
        model.selectedProjectID = project.id
        model.selectedChatID = titled.id
        model.drawerPinned = false
        model.drawerShown = false
        for chat in [titled, other] {
            let conversation = model.conversation(for: chat)
            conversation.userSent("Hello from \(chat.title)", previews: [], id: UUID())
            conversation.receive(EngineEvent(name: "text", threadId: chat.id.uuidString, body: ["event": "text", "delta": "Read, and here is what I found in it."]))
            conversation.receive(EngineEvent(name: "turn.done", threadId: chat.id.uuidString, body: ["event": "turn.done", "stopReason": "end_turn"]))
        }
        model.pulls[project.path] = PullRequest(
            number: 1234, title: other.title, url: "https://github.com/realmeric/OriCode/pull/1234", state: "OPEN", head: Self.branch, base: "main",
            checks: [PullCheck(name: "CI / test", state: "fail", link: nil, seconds: 64), PullCheck(name: "CI / build", state: "pass", link: nil, seconds: 6)])
        // The review's design is read from the defaults, and the app's own aren't the test's to set.
        defaults = UserDefaults(suiteName: suite)!
        // VoiceOver's own switch, which is what makes SwiftUI build the tree at all.
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: Self.enhanced)
        let host = NSHostingController(rootView: AnyView(
            RootView()
                .environment(model)
                .environment(Updates())
                .modelContainer(container)
                .defaultAppStorage(defaults)
                .frame(minWidth: 720, minHeight: 480)
                .preferredColorScheme(.dark)))
        host.sceneBridgingOptions = [.toolbars]
        window = Unplaced(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        // The app's window hides its title (OriCodeApp). A plain one is titled Untitled by AppKit
        // and the toolbar's row draws it, which aWindowsOwnTitleIsRead keeps.
        if !windowTitled { window.title = "" }
        // Off every screen, where no pointer is: one resting on the window lights what only shows
        // under a pointer, Legacy's Mark Reviewed for one, whether or not the window takes the
        // mouse, and the walk would then read whatever Meriç's hand had left lit.
        window.ignoresMouseEvents = true
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.setFrameOrigin(Self.away)
        window.alphaValue = 0
        window.orderFrontRegardless()
        dress(titled)
        dress(other)
        fillReview()
    }

    func close() {
        block?.stop()
        window.close()
        NSApp.accessibilitySetValue(NSNumber(value: false), forAttribute: Self.enhanced)
        defaults.removePersistentDomain(forName: suite)
        UserDefaults.standard.set(pinnedBefore, forKey: "drawerPinned")
        withExtendedLifetime(container) {}
    }

    private static let away = NSPoint(x: -6000, y: -6000)

    /// AppKit brings a titled window back onto a screen wherever it's sent: this one came to
    /// rest in the screen's bottom left corner, under any pointer left there.
    private final class Unplaced: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    var onScreen: Bool { NSScreen.screens.contains { $0.frame.intersects(window.frame) } }

    private static let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    /// A long branch, and three lines typed.
    private func dress(_ chat: Chat) {
        model.branches[chat.id] = BranchInfo(branch: Self.branch, ahead: 2, upstream: true)
        model.composer(for: chat).draft.text = "The first line of three\nthe second\nand the third"
    }

    private func fillReview() {
        let files = (0..<3).map { index in
            FileDiff(
                path: "App/Review/TheTranscriptsDiffReadsTheSameWay\(index).swift", oldPath: nil, status: "M", binary: false, executable: false,
                hunks: [DiffHunk(oldStart: 10, oldLines: 3, newStart: 10, newLines: 4, context: "struct File\(index)",
                                 lines: [" let a = 1", "-let b = 2", "+let b = 3", "+let c = 4", " let e = 6"])],
                added: index == 0 ? 12_345 : 2, deleted: index == 0 ? 1_234 : 1, cut: false, stamp: nil, lossy: false, changedAt: nil)
        }
        let diff = WorkingDiff(root: model.project?.path ?? "", head: "abc", files: files)
        // A check whose ending was a pipe's, so its row has the most to say.
        let check = ToolCall(
            toolUseId: "check", name: "Bash",
            input: ["command": "xcodebuild -project OriCode.xcodeproj -scheme OriCode -destination platform=macOS,arch=arm64 test | tail -40"],
            result: "ok", startedAt: .now)
        let provenance = Provenance(items: [.user(id: UUID(), text: "Do it"), .tool(id: UUID(), call: check)]) { $0 }
        let book = ReviewBook(diff: diff, provenance: provenance)
        model.review.folder = model.workingFolder
        model.review.thread = titled.id
        model.review.diff = diff
        model.review.base = book
        model.review.book = book
        model.review.page = WitnessPage(diff: diff, units: book.units, provenance: provenance)
    }

    /// Lays the window out one way and names it, or nil where that way can't be: two threads in
    /// a window too narrow for them, and a terminal over a thread that hasn't begun.
    func show(width: CGFloat, pinned: Bool, threads: Threads, over: Over) async throws -> String? {
        let room = width - (pinned ? Drawer.width + Drawer.inset * 2 : 0)
        if threads == .pair, room < Column.least * 2 { return nil }
        if threads == .new, over == .block { return nil }
        model.openInIsland(.capsule)
        model.openFile = nil
        model.closeBlock()
        // A drawer that stood aside for the last state's review comes back as the window sees
        // the review gone, and not before.
        for _ in 0..<50 where model.drawerAside { try await Task.sleep(for: .milliseconds(20)) }
        window.setContentSize(NSSize(width: width, height: 760))
        model.drawerPinned = pinned
        model.drawerShown = pinned
        let before = (model.chat?.id, model.besideShown?.id)
        switch threads {
        case .titled:
            model.closeOtherSide()
            model.select(titled)
        case .pair:
            model.select(titled)
            model.openBeside(other)
        case .new:
            model.closeOtherSide()
            if let draft, model.chat(withID: draft.id) != nil {
                model.select(draft)
            } else {
                draft = model.newChat()
                draft.map(dress)
            }
        }
        // The composer glides to the window's middle or its foot, or to its half, after a wait
        // in which nothing moves.
        if before != (model.chat?.id, model.besideShown?.id) { try await Task.sleep(for: .milliseconds(900)) }
        model.say(Self.note)
        switch over {
        case .nothing: break
        case .command: model.openInIsland(.command)
        case .heads: model.openInIsland(.heads)
        case .files: model.openInIsland(.files)
        case .side: model.openInIsland(.side)
        case .pull: model.openInIsland(.pull)
        case .witness, .legacy:
            let design: ReviewDesign = over == .witness ? .witness : .legacy
            defaults.set(design.rawValue, forKey: ReviewDesign.key)
            model.review.design = design
            model.review.placed = false
            model.review.placeFiles()
            // The keyboard in a file, so Witness's header names it.
            model.review.select(model.review.book.units.first)
            model.openInIsland(.review)
        case .file:
            let lines = (1...80).map { "    let value\($0) = \($0)" }
            model.openFile = OpenFile(path: "App/Review/A/Long/Way/Down/Into/The/Project/WitnessReview.swift", cwd: titled.cwd,
                                      code: AttributedString(lines.joined(separator: "\n")), lines: lines.count)
        case .block:
            if block == nil { block = model.runCommand("sleep 120", in: titled, forModel: false) }
            if let block { model.open(block) }
        }
        try await settle()
        return "\(Int(width))pt, \(pinned ? "the drawer pinned, " : "")\(threads.rawValue), \(over.rawValue)"
    }

    func callDrawer() async throws {
        model.showDrawer()
        try await settle()
    }

    /// Waits for what was asked to be laid out and for whatever glides there to arrive: the
    /// frames read the same twice running. A surface is made a part to a frame, so the first
    /// read is never taken at once.
    private func settle() async throws {
        var last: [CGRect] = []
        for round in 0..<40 {
            try await Task.sleep(for: .milliseconds(round == 0 ? 60 : 40))
            let (words, surfaces) = read()
            let frames = surfaces.map(\.frame) + words.map(\.frame)
            if round > 0, frames == last { return }
            last = frames
        }
    }

    // MARK: Reading

    /// Reads the window as it stands and keeps what's wrong with it under the state's name.
    func look(_ state: String) {
        let (words, surfaces) = read()
        most = max(most, words.count)
        looked += 1
        if ProcessInfo.processInfo.environment["OVERLAP_DUMP"] != nil {
            dump += "== \(state)\n" + surfaces.map { "  SURFACE \($0.name) \($0.frame.integral)\n" }.joined()
                + words.filter { !$0.transcript }.map { "  \($0.role) \($0.name) \($0.frame.integral) over \($0.over.map(String.init) ?? "-")\($0.scrolls ? " scrolls" : "")\n" }.joined()
        }
        for fault in faults(words, surfaces) {
            if let at = found.firstIndex(where: { $0.fault == fault }) {
                found[at].count += 1
            } else {
                found.append((fault, state, 1))
            }
        }
        // What stands outside a surface's scroll view is its top and bottom rows, where a button
        // keeps its words and a label keeps its width and its line. A text cut short still
        // answers with all its words, so its width is what says it was cut.
        for word in words where !word.scrolls {
            guard let over = word.over, surfaces[over].name != "Threads" else { continue }
            guard Self.kept(word) else { continue }
            let key = surfaces[over].name + "\u{0}" + word.role + "\u{0}" + word.name
            let room = roomy[key] ?? word.frame.size
            roomy[key] = CGSize(width: max(room.width, word.frame.width), height: min(room.height, word.frame.height))
            seen.append((key, word.name, word.frame.size, state))
        }
    }

    /// Whether a word in a surface's top or bottom row keeps its size whatever the row's width.
    /// A button and a menu do. So does a label, a word or a few; a sentence may take a second
    /// line, and a title, a branch or a path is what gives way. A field takes what's left.
    private static func kept(_ word: Word) -> Bool {
        switch word.role {
        case "AXButton", "AXMenuButton", "AXPopUpButton": !givesWay.contains(word.name)
        case "AXStaticText": word.name.count < 30
        default: false
        }
    }

    /// Witness's file menu, whose name gives way in its middle.
    private static let givesWay: Set<String> = ["TheTranscriptsDiffReadsTheSameWay0.swift, 1 of 3"]

    /// Every fault of every state looked at, each once, naming the first state that had it.
    func verdict() -> [String] {
        for entry in seen {
            guard let room = roomy[entry.key] else { continue }
            let fault: String? = if entry.size.height > room.height + 4 {
                "“\(entry.name)” is \(Int(entry.size.height))pt tall in a row where it is \(Int(room.height))pt with room"
            } else if entry.size.width < room.width - 2 {
                "“\(entry.name)” is cut to \(Int(entry.size.width))pt of its \(Int(room.width))pt"
            } else {
                nil
            }
            guard let fault else { continue }
            let general = fault.replacing(#/ to \d+pt of/#, with: " short of").replacing(#/ is \d+pt tall/#, with: " is taller")
            if let at = found.firstIndex(where: { $0.fault.replacing(#/ to \d+pt of/#, with: " short of").replacing(#/ is \d+pt tall/#, with: " is taller") == general }) {
                found[at].count += 1
            } else {
                found.append((fault, entry.state, 1))
            }
        }
        seen = []
        if let path = ProcessInfo.processInfo.environment["OVERLAP_DUMP"], looked > 1 {
            try? ("\(looked) states in \(Date.now.timeIntervalSince(began)) s\n" + found.map { "\($0.fault): \($0.first) +\($0.count - 1)" }.joined(separator: "\n") + "\n" + dump).write(toFile: path, atomically: true, encoding: .utf8)
        }
        return found.map { "\($0.fault): \($0.first)\($0.count > 1 ? ", and \($0.count - 1) more of \(looked)" : "")" }
    }

    /// What's wrong with one reading, each fault in words that name both things.
    private func faults(_ words: [Word], _ surfaces: [Surface]) -> [String] {
        var faults: [String] = []
        let glass = CGRect(origin: .zero, size: window.frame.size)
        let seen = words.filter { !$0.transcript }
        // The composers and the note under them, once the thread has begun; before that the
        // composer waits in the middle of the window and a surface opens over it.
        let begun = model.currentConversation?.started ?? model.chat?.started ?? false
        let foot = begun && model.composerTop > 0 ? model.composerTop : .infinity
        for (index, word) in seen.enumerated() {
            let row = word.frame.midY < TitleBar.height
            // Words on words: among the window's own, among one surface's, and in the toolbar's
            // row whoever they belong to.
            for next in seen[(index + 1)...] where !related(word, next) && meet(word.frame, next.frame) {
                guard next.over == word.over || (row && next.frame.midY < TitleBar.height) else { continue }
                if Self.laidOver.contains(word.name) || Self.laidOver.contains(next.name) { continue }
                faults.append("“\(word.name)” and “\(next.name)” are drawn over each other")
            }
            for (number, surface) in surfaces.enumerated() {
                if word.over == number {
                    if !word.scrolls, !inside(word.frame, surface.frame) {
                        faults.append("“\(word.name)” runs out of \(surface.name)")
                    }
                } else if word.over == nil, meet(word.frame, surface.frame), !inside(word.frame, surface.frame) {
                    // Wholly under a surface is covered, which is what a surface is for. Cut by
                    // its edge is a fault in the toolbar's row and at the window's foot. Between
                    // them is the conversation, which what grows out of the capsule and the
                    // drawer lie over, the other column's title line with it; a terminal and a
                    // file start under that row and have no business in the line.
                    if !row, !begun { continue }
                    let conversation = !row && word.frame.minY < foot - 1
                    if conversation, surface.frame.minY < TitleBar.height { continue }
                    faults.append("“\(word.name)” is cut by the edge of \(surface.name)")
                }
            }
            if word.over == nil, !inside(word.frame, glass) {
                faults.append("“\(word.name)” runs off the window")
            }
        }
        return faults
    }

    /// A button with nothing drawn in it, laid over words on purpose: Witness's number column
    /// is the button that marks a change.
    private static let laidOver: Set<String> = ["Mark reviewed", "Mark not reviewed"]

    /// More than a point of each, so two frames that only touch don't count.
    private func meet(_ a: CGRect, _ b: CGRect) -> Bool {
        let both = a.intersection(b)
        return !both.isNull && both.width > 1 && both.height > 1
    }

    private func inside(_ a: CGRect, _ b: CGRect) -> Bool {
        b.insetBy(dx: -1, dy: -1).contains(a)
    }

    /// One inside the other in the tree: a button and its own label.
    private func related(_ a: Word, _ b: Word) -> Bool {
        let shared = min(a.place.count, b.place.count)
        return a.place.prefix(shared) == b.place.prefix(shared)
    }

    /// AppKit gives a toolbar's item the row's whole height and its own margins, 44 by 52pt for
    /// the sidebar button, which draws 28 by 22 in the middle of that.
    private static func drawn(_ item: CGRect) -> CGRect {
        CGRect(x: item.midX - 14, y: item.midY - 11, width: 28, height: 22)
    }

    private static let wordRoles: Set<String> = ["AXStaticText", "AXButton", "AXMenuButton", "AXPopUpButton", "AXTextField", "AXTextArea", "AXLink", "AXCheckBox"]

    /// Every word under the window and every surface, in the window's points from its top left.
    /// SwiftUI's nodes answer the accessibility protocol's selectors without adopting it, and
    /// AppKit's title cell answers only the older one, so each is asked by name.
    func read() -> (words: [Word], surfaces: [Surface]) {
        var words: [Word] = []
        var surfaces: [Surface] = []
        let origin = window.frame
        func ask(_ object: NSObject, _ key: String, _ old: NSAccessibility.Attribute) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : object.accessibilityAttributeValue(old)
        }
        func walk(_ element: Any, place: [Int], over: Int?, clip: CGRect?, scrolled: Bool, toolbar: Bool = false) {
            guard let object = element as? NSObject else { return }
            if (ask(object, "isAccessibilityHidden", .hidden) as? Bool) == true { return }
            let role = ask(object, "accessibilityRole", .role) as? String ?? ""
            var frame = CGRect.null
            if object.responds(to: NSSelectorFromString("accessibilityFrame")) {
                frame = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .null
            } else if let at = (object.accessibilityAttributeValue(.position) as? NSValue)?.pointValue,
                      let size = (object.accessibilityAttributeValue(.size) as? NSValue)?.sizeValue {
                frame = CGRect(origin: at, size: size)
            }
            frame = CGRect(x: frame.minX - origin.minX, y: origin.maxY - frame.maxY, width: frame.width, height: frame.height)
            let texts = [ask(object, "accessibilityValue", .value), ask(object, "accessibilityLabel", .description), ask(object, "accessibilityTitle", .title)]
            // A menu's label comes as an attributed string.
            let text = texts.compactMap { $0 as? String ?? ($0 as? NSAttributedString)?.string }.first { !$0.isEmpty }
            var over = over, clip = clip, scrolled = scrolled
            let toolbar = toolbar || role == "AXToolbar"
            if role == "AXGroup", ask(object, "accessibilityIdentifier", .identifier) as? String == Island.over {
                surfaces.append(Surface(name: text ?? "a surface", frame: frame))
                over = surfaces.count - 1
                scrolled = false
            } else if role == "AXScrollArea" {
                clip = clip.map { $0.intersection(frame) } ?? frame
                scrolled = true
            } else if Self.wordRoles.contains(role), text != nil || role != "AXStaticText" {
                let shown = clip.map { $0.intersection(frame) } ?? frame
                if !shown.isNull, shown.width > 0, shown.height > 0 {
                    let line = (text ?? role).split(whereSeparator: \.isNewline).first.map(String.init) ?? role
                    words.append(Word(name: String(line.prefix(48)), role: role, frame: toolbar ? Self.drawn(shown) : shown, over: over,
                                      transcript: over == nil && scrolled && role != "AXTextArea", scrolls: scrolled, place: place))
                }
            }
            for (index, child) in ((ask(object, "accessibilityChildren", .children) as? [Any]) ?? []).enumerated() {
                walk(child, place: place + [index], over: over, clip: clip, scrolled: scrolled, toolbar: toolbar)
            }
        }
        walk(window, place: [], over: nil, clip: nil, scrolled: false)
        return (words, surfaces)
    }
}
