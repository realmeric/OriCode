import AppKit
import QuickLook
import SwiftUI

struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let cwd: String
    @State private var position = ScrollPosition()
    /// Where the transcript stands against its end.
    @State private var end = TranscriptEnd.Standing()
    @State private var showAll = false
    /// The item a reveal brought into view, lit for a moment.
    @State private var lit: UUID?
    /// What the scroll view last said of itself, kept where reading it draws nothing.
    @State private var content = Measured()
    @AppStorage(TranscriptSettings.showThinking) private var showThinking = true

    private final class Measured {
        /// How tall the laid-out thread is.
        var height: CGFloat = 0
        /// How much of it shows at once.
        var visible: CGFloat = 0
        /// Where the scroll view's numbers put it against the end.
        var reached = TranscriptEnd.Place.end
        /// The row named `end` is laid out, which the lazy stack does only around what's showing.
        var endLaidOut = true
        /// The way to the end that's under way, which the next one, or a reveal, takes over.
        var jump: Task<Void, Never>?
    }

    /// The room under the last row, a row of its own with a name: the one place in a lazy stack
    /// that is the thread's end whatever the rows above it turn out to measure.
    private static let end = "end"

    /// The latest items, until an earlier one is asked for. The stack is lazy, laying out what's
    /// on screen and a little around it, and anchored at the bottom it lays out the newest first.
    private static let recent = 200
    /// How far down the top edge's fade runs: nothing above it is read at full strength.
    private static let fade = TitleBar.height + 20

    private var shown: ArraySlice<Item> {
        showAll ? conversation.items[...] : conversation.items.suffix(Self.recent)
    }

    var body: some View {
        // Messages waiting for Claude to take them up come last, as the bubbles they'll be,
        // with the ids they'll keep: taken up, one becomes the transcript's item in place.
        let entries = TranscriptEntry.fold(shown, thinking: showThinking) + conversation.waiting.map {
            TranscriptEntry.item(.user(id: $0.id, text: $0.text, images: $0.previews))
        }
        // The text streaming in, when it's into a row that's laid out: thinking that
        // Settings › Conversation leaves out streams into nothing.
        let streaming = conversation.live.id.flatMap { id in entries.reversed().contains { $0.holds(id) } ? conversation.live : nil }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if shown.count < conversation.items.count {
                    Button("Show \(conversation.items.count - shown.count) earlier") { showAll = true }
                        .buttonStyle(.plain)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.faint)
                        .padding(.bottom, 20)
                }
                // Not while a block is open: Return typed there mustn't answer the card.
                let listening = model.openShell != nil ? nil : conversation.waitingAsk?.requestId
                let lastLimit = conversation.lastLimit
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    // One view a row, whatever the item draws: an item that can draw nothing, a footer
                    // with nothing to say, would have the lazy stack make every row to count them.
                    VStack(alignment: .leading, spacing: 0) { view(of: entry, listening: listening, lastLimit: lastLimit) }
                        .background {
                            if lit == entry.id {
                                Surface.selected
                                    .clipShape(.rect(cornerRadius: 14, style: .continuous))
                                    .padding(-8)
                                    .transition(.opacity)
                            }
                        }
                        .id(entry.id)
                        .padding(.top, index == 0 ? 0 : Self.spacing(before: entry.first, after: entries[index - 1].last))
                        .transition(Self.arrival(of: entry.first))
                }
                if let retrying = conversation.retrying {
                    Text("Can't reach \(model.agent(for: conversation.chat).agent). \(retrying)")
                        .font(Type.secondary)
                        .foregroundStyle(Ink.secondary)
                        .padding(.top, 14)
                        .transition(.opacity)
                }
                Color.clear
                    .frame(height: 24)
                    .id(Self.end)
                    .onAppear { place(endLaidOut: true) }
                    .onDisappear { place(endLaidOut: false) }
            }
            .column()
            .padding(.top, 52)
        }
        .scrollIndicators(.never)
        .environment(\.openURL, model.transcriptLinks)
        .environment(\.codeCopyLine, Self.fade - CodeCopy.inset)
        // A workflow's card lights the rays its agents hold on the thread's mark.
        .environment(conversation.heads)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        // Following the bottom while it grows, a reply streaming or an item arriving, is the
        // scroll view's own; scrolled up, what's read stays where it is.
        .defaultScrollAnchor(end.pinned ? .bottom : .top, for: .sizeChanges)
        .onScrollGeometryChange(for: TranscriptEnd.Place.self) { geometry in
            TranscriptEnd.place(offset: geometry.contentOffset.y, visible: geometry.containerSize.height, content: geometry.contentSize.height)
        } action: { _, reached in
            place(reached: reached)
        }
        .onScrollGeometryChange(for: CGFloat.self, of: \.contentSize.height) { content.height = $1 }
        .onScrollGeometryChange(for: CGFloat.self, of: \.containerSize.height) { content.visible = $1 }
        // Only what's laid out is growth to tell of: thinking left out, or a call folded into
        // the run above it, adds no row.
        .onChange(of: TranscriptEnd.Tail(count: conversation.items.count + conversation.waiting.count, last: entries.last?.id)) { old, tail in
            end.grew(laidOut: tail.grew(from: old))
        }
        // A message sent by hand is read where it lands when the end was a screen away or less;
        // sent from further up, what's being read stays put and the pill says there's more.
        .onChange(of: conversation.handSent) {
            if end.sent() { toEnd(animated: false) }
        }
        .onChange(of: model.threadEnd) { toEnd(animated: true) }
        // On appear too: ⌘K sets the reveal as it switches to the thread that builds this view.
        .onAppear(perform: takeReveal)
        .onChange(of: model.reveal) { takeReveal() }
        .mask {
            // Fades under the top edge and above the composer instead of ending at a line.
            VStack(spacing: 0) {
                // Clear through the capsule and fading in under it, so nothing reads behind the
                // traffic lights and the capsule in the toolbar's row.
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.45), .init(color: .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fade)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24)
            }
        }
        // Over the transcript's foot and outside its fade, so the composer under it never moves.
        .overlay(alignment: .bottom) {
            let offered = TranscriptEnd.offered(pinned: end.pinned, covered: model.openShell != nil || model.openFile != nil)
            ZStack {
                if offered {
                    // A reply streams into a row that's already there, which no count tells of.
                    EndPill(news: end.news, stream: streaming) {
                        end.grew(laidOut: true)
                    } jump: {
                        toEnd(animated: true)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.bottom, 10)
            .animation(Motion.fade, value: offered)
            .animation(Motion.fade, value: end.news)
        }
    }

    /// Takes a word on where the transcript is, from the scroll view's numbers or from the row
    /// named `end` coming and going. The numbers alone aren't believed: the lazy stack guesses the
    /// height of rows it hasn't made, and a scroll can stop in a stretch of them it hasn't laid
    /// out, with nothing under it by the numbers and nothing showing either.
    private func place(reached: TranscriptEnd.Place? = nil, endLaidOut: Bool? = nil) {
        if let reached { content.reached = reached }
        if let endLaidOut { content.endLaidOut = endLaidOut }
        let place = TranscriptEnd.place(content.reached, endLaidOut: content.endLaidOut)
        if place != end.place { end.moved(to: place) }
    }

    /// Brings the thread's true end to the foot of the view. The lazy stack only guesses at the
    /// height of rows it hasn't made, so a place by its number lands short of the end; the row
    /// named `end` is found once what's around it is laid out, so from further than a screen away
    /// the scroll goes first to where the end is thought to be, as a reveal does.
    private func toEnd(animated: Bool) {
        // Ahead of the scroll view's own word, and through what it says on the way: a row that
        // grows meanwhile keeps the end, and the pill stays away until the way is done.
        let laidOut = end.jump()
        content.jump?.cancel()
        content.jump = Task {
            // A beat for the layout of what was just sent.
            try? await Task.sleep(for: .milliseconds(50))
            if !laidOut {
                position.scrollTo(edge: .bottom)
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled else { return }
            withAnimation(animated ? Motion.move : nil) { position.scrollTo(id: Self.end, anchor: .bottom) }
            // Rows measured on the way can leave it short, so it looks again, twice at most, once
            // the move has settled. A hand that takes the scroll meanwhile keeps it.
            for _ in 0..<2 {
                try? await Task.sleep(for: .milliseconds(animated ? 350 : 80))
                if Task.isCancelled || position.isPositionedByUser || end.place == .end { break }
                if content.reached == .end {
                    // At the foot by its numbers with the end's row not made: a stretch nothing is
                    // laid out in, which the scroll leaves by a screen to have the rows made.
                    position.scrollTo(y: max(0, content.height - 2 * content.visible))
                } else {
                    position.scrollTo(edge: .bottom)
                }
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled || position.isPositionedByUser { break }
                position.scrollTo(id: Self.end, anchor: .bottom)
            }
            if !position.isPositionedByUser { try? await Task.sleep(for: .milliseconds(80)) }
            guard !Task.isCancelled else { return }
            // Scrolled away by hand in the meantime, the pill comes back.
            end.landed()
        }
    }

    /// Brings the item a reveal asks for into view, laying out the whole thread when it's further
    /// back than the latest items, and lights it for a moment. Another thread's item is left for
    /// that thread's transcript.
    private func takeReveal() {
        guard let id = model.reveal, conversation.items.contains(where: { $0.id == id }) else { return }
        model.reveal = nil
        if !shown.contains(where: { $0.id == id }) { showAll = true }
        content.jump?.cancel()
        end.revealing()
        Task {
            // A beat for the layout a new thread or the earlier items bring.
            try? await Task.sleep(for: .milliseconds(80))
            // The lazy stack finds an item only once what's around it has been laid out, so the
            // scroll goes first to where the item should be by its place in the thread.
            let entries = TranscriptEntry.fold(shown, thinking: showThinking)
            if let index = entries.firstIndex(where: { $0.id == id }) {
                position.scrollTo(y: content.height * CGFloat(index) / CGFloat(entries.count))
                try? await Task.sleep(for: .milliseconds(50))
            }
            withAnimation(Motion.move) { position.scrollTo(id: id, anchor: .center) }
            withAnimation(Motion.fade) { lit = id }
            // The scroll view speaks only when its place changes, and an item in the last
            // screenful, or a thread shorter than the window, leaves it at the end it was at: once
            // the move has settled its word is taken as it stands.
            try? await Task.sleep(for: Self.settling)
            end.settled()
            try? await Task.sleep(for: .seconds(1.2) - Self.settling)
            if lit == id { withAnimation(Motion.fade) { lit = nil } }
        }
    }

    /// How long a reveal's move is given to settle, out of the time its item stays lit.
    private static let settling = Duration.milliseconds(400)

    @ViewBuilder
    private func view(of entry: TranscriptEntry, listening: String?, lastLimit: UUID?) -> some View {
        let streaming = conversation.live.id
        switch entry {
        case .item(let item):
            ItemView(
                item: item, cwd: cwd, thread: conversation.chat.id, listening: listening,
                live: conversation.running && item.id == conversation.items.last?.id,
                limitCard: item.id == lastLimit,
                resumes: conversation.resumeAt != nil && item.id == lastLimit,
                waiting: conversation.waiting.contains { $0.id == item.id },
                stream: item.id == streaming ? conversation.live : nil)
        case .run(let items):
            ToolRunRow(items: items, cwd: cwd, live: conversation.running && items.last?.id == conversation.items.last?.id,
                       stream: items.contains { $0.id == streaming } ? conversation.live : nil)
        }
    }

    /// A message you send comes up out of the composer on the send's glide, and a card asking
    /// for you rises into place; everything else simply appears as it streams. A waiting message
    /// handed back to the composer fades out.
    private static func arrival(of item: Item) -> AnyTransition {
        switch item {
        case .user: .asymmetric(insertion: .opacity.combined(with: .offset(y: 18)), removal: .opacity)
        case .ask: .opacity.combined(with: .offset(y: 10)).animation(Motion.move)
        default: .identity
        }
    }

    fileprivate static func spacing(before item: Item, after previous: Item) -> CGFloat {
        switch (previous, item) {
        case (.tool(_, let a), .tool(_, let b)) where a.isEdit || b.isEdit: 8
        case (.tool, .tool): 4
        case (_, .footer): 8
        case (.footer, _): 28
        default: 14
        }
    }
}

/// Where the transcript is against its end, and what follows from that.
enum TranscriptEnd {
    /// How close to the end counts as being at it.
    static let reach: CGFloat = 48

    /// Where what's showing is against the end, which is all the transcript asks of a scroll.
    enum Place {
        /// The end is in view: growth keeps it there, and there's nowhere for the pill to go.
        case end
        /// Within two heights of what's showing: a message sent by hand brings the end into view.
        case near
        /// Further up, where something is being read: it stays where it is.
        case away
    }

    /// How much of the thread lies under what's showing.
    static func distance(offset: CGFloat, visible: CGFloat, content: CGFloat) -> CGFloat {
        max(0, content - offset - visible)
    }

    static func place(offset: CGFloat, visible: CGFloat, content: CGFloat) -> Place {
        let distance = distance(offset: offset, visible: visible, content: content)
        // Twice the view: above rows not yet measured the numbers put the reader two to four times
        // further up than they are, and a message sent from half a screen up was left behind.
        return distance <= reach ? .end : distance <= 2 * visible ? .near : .away
    }

    /// Where the transcript is, given where the scroll view's numbers put it and whether the row
    /// that is the end is laid out. Without that row the end isn't what's showing, however little
    /// the numbers leave under it; it's taken to be near, where a sent message still follows.
    static func place(_ reached: Place, endLaidOut: Bool) -> Place {
        reached == .end && !endLaidOut ? .near : reached
    }

    /// Whether a message sent by hand brings the end into view; from further up than two heights of
    /// the view the pill tells of it instead.
    static func follows(from place: Place) -> Bool {
        place != .away
    }

    /// Whether the pill is there: only while there's an end to go to, and nothing open over it.
    static func offered(pinned: Bool, covered: Bool) -> Bool {
        !pinned && !covered
    }

    /// What the thread ends in: how many items and waiting messages it has, and the last row
    /// they lay out as.
    struct Tail: Equatable {
        var count: Int
        var last: UUID?

        /// Whether the thread grew by something that's laid out. An item that's folded away, or
        /// into the row before it, leaves the last row the one it was, and so does a waiting
        /// message taken up; earlier items shown, or thinking turned on, add no item.
        func grew(from old: Tail) -> Bool {
            count > old.count && last != old.last
        }
    }

    /// Where the transcript stands against its end, between one word from the scroll view and
    /// the next: whether growth keeps the end in view, and whether the pill has news to tell.
    struct Standing: Equatable {
        /// Where the scroll view last said it was; `pinned` is set ahead of it.
        private(set) var place = Place.end
        /// Growth keeps the end in view, and the pill is away.
        private(set) var pinned = true
        /// Something arrived, or a reply grew, while the end was out of view: the pill says so.
        private(set) var news = false
        /// On the way to the end, which the scroll view's word on the way doesn't call off.
        private(set) var heading = false

        /// The scroll view said where it is. On the way to the end it passes near, where the end
        /// was thought to be, and that's no leaving.
        mutating func moved(to place: Place) {
            self.place = place
            if place == .end {
                pinned = true
                news = false
            } else if !heading {
                pinned = false
            }
        }

        /// A reveal sets out for an item: growth mustn't move what it brings into view, and any
        /// way to the end is called off.
        mutating func revealing() {
            heading = false
            pinned = false
        }

        /// A reveal's move has settled. The scroll view says nothing when the place it ends at is
        /// the one it started from, so its last word is taken: at the end there's no pill.
        mutating func settled() {
            guard !heading else { return }
            pinned = place == .end
            if pinned { news = false }
        }

        /// Whether a message sent by hand from here brings the end into view.
        func sent() -> Bool {
            TranscriptEnd.follows(from: place)
        }

        /// The way to the end starts, ahead of the scroll view's word. Says whether what's around
        /// the end is laid out, which from further than a screen away it isn't.
        mutating func jump() -> Bool {
            let laidOut = place != .away
            heading = true
            pinned = true
            news = false
            return laidOut
        }

        /// The way to the end is done, or a hand took the scroll from it: the scroll view's word
        /// stands again.
        mutating func landed() {
            heading = false
            pinned = place == .end
        }

        /// The thread grew. It's news only when it's laid out and the end is out of view.
        mutating func grew(laidOut: Bool) {
            if laidOut && !pinned { news = true }
        }
    }
}

/// The way back to the thread's end, there only while the end is out of view; it says New when
/// something has arrived down there.
struct EndPill: View {
    let news: Bool
    /// The text streaming into a row of the thread, if any is.
    let stream: LiveText?
    let grew: () -> Void
    let jump: () -> Void
    @State private var hovering = false

    static let height: CGFloat = 28

    var body: some View {
        Button(action: jump) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                if news {
                    Text("New")
                        .font(Type.secondary)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(hovering ? Ink.primary : Ink.secondary)
            .padding(.horizontal, news ? 12 : 0)
            .frame(minWidth: Self.height)
            .frame(height: Self.height)
            // The title capsule's tint on the material the island's surfaces have, since this one
            // has the transcript's words under it.
            .background(hovering ? Surface.selected : Surface.drawer, in: .capsule)
            .background(.ultraThinMaterial, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        .animation(Motion.fade, value: news)
        // Until the pill says New, and no longer: said once, the stream isn't read again.
        .background {
            if let stream, !news { StreamGrowth(stream: stream, grew: grew) }
        }
        .help("Jump to the end")
        .accessibilityLabel(news ? "Jump to the end, there's something new" : "Jump to the end")
    }
}

/// Tells of a streaming text growing, and draws nothing. A view of its own, so that each delta
/// runs this body and not the pill's.
private struct StreamGrowth: View {
    let stream: LiveText
    let grew: () -> Void

    var body: some View {
        Color.clear.onChange(of: stream.text.utf8.count) { old, count in
            if count > old { grew() }
        }
    }
}

/// What the transcript lays out: an item on its own, or a run of tool calls folded into one row.
enum TranscriptEntry: Identifiable {
    case item(Item)
    case run([Item])

    var id: UUID {
        switch self {
        case .item(let item): item.id
        case .run(let items): items[0].id
        }
    }

    var first: Item {
        switch self {
        case .item(let item): item
        case .run(let items): items[0]
        }
    }

    var last: Item {
        switch self {
        case .item(let item): item
        case .run(let items): items[items.count - 1]
        }
    }

    /// Whether the item is in this row, on its own or in the run.
    func holds(_ id: UUID) -> Bool {
        switch self {
        case .item(let item): item.id == id
        case .run(let items): items.contains { $0.id == id }
        }
    }

    /// Folds the tool calls between two pieces of Claude's text, with any thinking among them,
    /// into a run, as the Claude Code app does. Anything else ends a run, an ask, a workflow's
    /// card or a plan's included, and a run with one call in it stays as its items. A TodoWrite
    /// that carries a plan on shows only on the plan's card, so it leaves the run as it was.
    static func fold(_ items: some Collection<Item>, thinking: Bool = true) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        var run: [Item] = []
        func close() {
            let calls = run.count { if case .tool = $0 { true } else { false } }
            if calls > 1 {
                entries.append(.run(run))
            } else {
                entries += run.map(TranscriptEntry.item)
            }
            run = []
        }
        for item in items {
            switch item {
            case .tool(_, let call) where call.kind == .workflow && !call.isError || call.plan != nil:
                close()
                entries.append(.item(item))
            case .tool(_, let call) where call.kind == .plan:
                continue
            // Settings › Conversation leaves thinking out.
            case .thinking where !thinking:
                continue
            case .tool, .thinking:
                run.append(item)
            default:
                close()
                entries.append(.item(item))
            }
        }
        close()
        return entries
    }
}

struct ItemView: View {
    let item: Item
    let cwd: String
    /// The thread a message of yours is in, which is where its pictures are kept.
    var thread: UUID?
    let listening: String?
    let live: Bool
    /// The thread's latest limit, which gets the card.
    var limitCard = false
    /// That limit is the one the thread waits out.
    var resumes = false
    /// A message sent into the turn that Claude hasn't taken up yet.
    var waiting = false
    /// The text streaming into this item, which it reads in place of its own.
    var stream: LiveText?
    /// The picture Quick Look shows, and the message's others to step through.
    @State private var shown: URL?
    @State private var files: [URL] = []

    /// Your messages' pictures, decoded once by the message rather than on every render.
    private static let decoded = NSCache<NSUUID, NSArray>()

    private func pictures(_ images: [Data]) -> [NSImage] {
        let key = item.id as NSUUID
        if let cached = Self.decoded.object(forKey: key) as? [NSImage] { return cached }
        let pictures = images.compactMap(NSImage.init(data:))
        Self.decoded.setObject(pictures as NSArray, forKey: key)
        return pictures
    }

    /// A picture in full, from the file its send kept. The disk is read off the main thread, and
    /// only for a click.
    private func open(_ index: Int, of images: [Data]) {
        let message = item.id
        let kept = thread
        Task {
            let urls = await SentPictures.standard.opened(thread: kept, message: message, previews: images)
            guard urls.indices.contains(index), let url = urls[index] else { return }
            files = urls.compactMap { $0 }
            shown = url
        }
    }

    var body: some View {
        switch item {
        case .user(_, let text, let images, _):
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(pictures(images).enumerated()), id: \.offset) { index, image in
                            Button { open(index, of: images) } label: {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 96, height: 72)
                                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open image")
                            .help("Open")
                        }
                    }
                    .quickLookPreview($shown, in: files)
                }
                Text(text)
                    .font(Type.body)
                    .foregroundStyle(waiting ? Ink.secondary : Ink.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Surface.userMessage, in: .rect(cornerRadius: 18, style: .continuous))
                if waiting {
                    Text("Waiting for the next step")
                        .font(Type.secondary)
                        .foregroundStyle(Ink.faint)
                        .padding(.trailing, 6)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 560, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .text(let id, let text):
            Reply(id: id, text: stream?.text ?? text, live: live)
        case .thinking(_, let text):
            ThinkingLine(text: stream?.text ?? text, live: live)
        case .tool(_, let call):
            if call.isEdit && !call.isError {
                DiffCard(call: call, cwd: cwd)
            } else if call.kind == .workflow && !call.isError {
                WorkflowCard(call: call)
            } else if let plan = call.plan {
                PlanCard(plan: plan)
            } else {
                ToolLine(call: call, cwd: cwd)
            }
        case .ask(_, let ask):
            AskCard(ask: ask, cwd: cwd, listens: ask.requestId == listening)
        case .footer(_, let footer):
            FooterLine(footer: footer)
        case .note(_, let text):
            Text(text)
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .textSelection(.enabled)
        case .limited(_, let resetsAt, let window):
            if limitCard {
                LimitCard(resetsAt: resetsAt, window: window, resumes: resumes)
            } else {
                LimitLine(resetsAt: resetsAt, window: window)
            }
        case .nearLimit(_, let window, let used, let resetsAt, let said):
            NearLimitLine(window: window, used: used, resetsAt: resetsAt, said: said)
        case .shell(let id, let run):
            ShellBlockView(id: id, run: run)
        case .opened(_, let thread, let title, let finished):
            OpenedLine(thread: thread, title: title, finished: finished)
        case .suggested(_, let title, let prompt):
            SuggestedThread(title: title, prompt: prompt)
        }
    }
}

struct ToolLine: View {
    let call: ToolCall
    let cwd: String
    @State private var open = false

    var body: some View {
        let line = ToolSummary.line(for: call, cwd: cwd)
        let path = ToolSummary.path(for: call)
        let shown = path.map { ToolSummary.relative($0, to: cwd) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(Motion.fade) { open.toggle() }
                } label: {
                    Text(shown.map { line.hasSuffix($0) ? String(line.dropLast($0.count)) : line } ?? line)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(call.result == nil)
                if let path, let shown {
                    FileLink(path: path, label: shown)
                }
                if call.isError {
                    Text("failed").foregroundStyle(Ink.faint)
                } else if call.result == nil {
                    ProgressView().controlSize(.mini).tint(Ink.secondary)
                }
            }
            .font(Type.secondary)
            .foregroundStyle(Ink.secondary)
            if open, let result = call.result {
                ScrollView {
                    Text(result.isEmpty ? "(no output)" : String(result.prefix(20_000)))
                        .font(Type.mono)
                        .foregroundStyle(Ink.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
                .background(Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
                .transition(.opacity)
            }
        }
    }
}

/// A run of tool calls as one row that says what they did, with the lines its edits added and
/// removed; a click opens the calls under it as their own lines.
struct ToolRunRow: View {
    let items: [Item]
    let cwd: String
    /// The turn is still in this run.
    let live: Bool
    /// The text streaming into one of its items, thinking between the calls.
    var stream: LiveText?
    @State private var open = false

    var body: some View {
        let calls = items.compactMap { item -> ToolCall? in
            if case .tool(_, let call) = item { call } else { nil }
        }
        let failed = calls.count { $0.isError }
        let diffs = calls.compactMap { $0.isEdit && !$0.isError && $0.result != nil ? Diff.of($0, cwd: cwd) : nil }
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.fade) { open.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(ToolSummary.run(calls))
                        .lineLimit(1)
                    if !diffs.isEmpty {
                        Text("·")
                        Counts(added: diffs.reduce(0) { $0 + $1.added }, deleted: diffs.reduce(0) { $0 + $1.deleted }, quiet: true)
                    }
                    if failed > 0 {
                        Text("· \(failed) failed").foregroundStyle(Ink.faint)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    if live {
                        ProgressView().controlSize(.mini).tint(Ink.secondary)
                    }
                }
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ItemView(item: item, cwd: cwd, listening: nil, live: live && index == items.count - 1,
                                 stream: item.id == stream?.id ? stream : nil)
                            .padding(.top, index == 0 ? 0 : TranscriptView.spacing(before: item, after: items[index - 1]))
                    }
                }
                .padding(.leading, 10)
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
    }
}

/// A path that opens the file read-only; underlined while the mouse is on it.
struct FileLink: View {
    @Environment(AppModel.self) private var model
    let path: String
    let label: String
    @State private var hovering = false

    var body: some View {
        Button {
            model.openFile(path)
        } label: {
            Text(label)
                .underline(hovering)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(label)")
    }
}

/// Thinking, folded to one line; the summary Claude streamed is underneath.
struct ThinkingLine: View {
    let text: String
    let live: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.fade) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(live ? "Thinking…" : "Thought")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(Type.secondary)
                .foregroundStyle(Ink.faint)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                Text(text)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 10)
                    .transition(.opacity)
            }
        }
    }
}

/// What a turn did. Its files always; how long it took and what it cost only when
/// Settings › Transcript asks, and nothing at all when there's nothing to say.
struct FooterLine: View {
    let footer: TurnFooter
    @AppStorage(TranscriptSettings.showTime) private var showTime = false
    @AppStorage(TranscriptSettings.showCost) private var showCost = false

    var body: some View {
        let words = footer.words(time: showTime, cost: showCost)
        if !words.isEmpty || footer.files > 0 {
            HStack(spacing: 5) {
                if !words.isEmpty { Text(words) }
                if footer.files > 0 {
                    Text((words.isEmpty ? "" : "· ") + "\(footer.files) \(footer.files == 1 ? "file" : "files") ·")
                    Counts(added: footer.added, deleted: footer.deleted)
                        .opacity(0.8)
                }
            }
            .font(Type.secondary)
            .foregroundStyle(Ink.faint)
        }
    }
}

enum TranscriptSettings {
    static let showTime = "showTurnTime"
    static let showCost = "showTurnCost"
    static let showThinking = "showThinking"
    /// Replies asked to be short, which the engine tells the agent.
    static let concise = "conciseReplies"
}

extension TurnFooter {
    func words(time showTime: Bool, cost showCost: Bool) -> String {
        let seconds = Int((durationMs / 1000).rounded())
        let time = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        // A stopped turn says so either way: it's what happened, not a statistic. One stopped after
        // a quit had cut it off has no time of its own.
        if stopReason == "interrupted" { return showTime && durationMs > 0 ? "Stopped after \(time)" : "Stopped" }
        var parts: [String] = []
        if showTime { parts.append("Worked for \(time)") }
        if showCost { parts.append(String(format: "$%.2f", costUSD)) }
        return parts.joined(separator: " · ")
    }
}
