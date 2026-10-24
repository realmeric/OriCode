import AppKit
import OSLog
import QuickLook
import SwiftUI

struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let cwd: String
    /// The open thread's transcript, the one the composer is under: with another beside it, only
    /// this one answers Return, goes to its end when asked, and has what's open drawn over it.
    var active = true
    /// Where the stage over the column ends while it's up: the transcript starts 28pt under it.
    var stageFoot: CGFloat?
    /// An agent's, on the surface of a stage stepped into it: nothing over its top but its fade.
    var stepped = false
    @State private var position = ScrollPosition()
    /// Where the transcript stands against its end.
    @State private var end = TranscriptEnd.Standing()
    @State private var showAll = false
    /// The row that was under Show earlier, held where it stood while the earlier items come in.
    @State private var kept: TranscriptEnd.Kept?
    /// The item a reveal brought into view, lit for a moment.
    @State private var lit: UUID?
    /// What the scroll view last said of itself, kept where reading it draws nothing.
    @State private var content = Measured()
    /// The pill, up once the end has been out of view a moment: a reply growing by a few lines
    /// in one frame puts the end out of view for that frame while the scroll catches up.
    @State private var pill = false
    @AppStorage(TranscriptSettings.showThinking) private var showThinking = true
    @AppStorage(TranscriptSettings.showWater) private var showWater = false

    private final class Measured {
        /// How tall the laid-out thread is.
        var height: CGFloat = 0
        /// How much of it shows at once.
        var visible: CGFloat = 0
        /// Where the scroll view's numbers put it against the end.
        var reached = TranscriptEnd.Place.end
        /// The row named `end` is laid out, which the lazy stack does only around what's showing.
        var endLaidOut = true
        /// The row named `end` has appeared at least once: until it has, `endLaidOut` and the
        /// place the view starts at are what it assumed of itself, which nothing has borne out.
        var endSeen = false
        /// The way to the end that's under way, which the next one, or a reveal, takes over.
        var jump: Task<Void, Never>?
        /// No hand and no momentum is moving the scroll.
        var resting = true
        /// The transcript has left the window, which takes the row named `end` with the rest.
        var gone = false
        /// When a row was last added under the others.
        var added: ContinuousClock.Instant?
        /// How far the thread is scrolled.
        var offset: CGFloat = 0
    }

    /// The room under the last row, a row of its own with a name: the one place in a lazy stack
    /// that is the thread's end whatever the rows above it turn out to measure.
    private static let end = "end"
    /// The scroll view's content, where a row stands whatever the scroll.
    private static let thread = "thread"

    private static let logger = Logger(subsystem: "com.realmeric.oricode", category: "transcript")

    /// The latest items, until an earlier one is asked for. The stack is lazy, laying out what's
    /// on screen and a little around it, and anchored at the bottom it lays out the newest first.
    private static let recent = 200
    /// Where the top edge is clear down to: a little past the capsule's foot, so nothing is read
    /// behind it, and past the title line of a column beside the open one.
    private static func clear(active: Bool) -> CGFloat {
        (active ? Island.top + TitleCapsule.height : TitleBar.height + BesideTitle.height) + 6
    }
    /// How far the fade under that runs before the transcript is at full strength.
    private static let fadeLength: CGFloat = 28
    /// Where a column's first row starts: half way into its fade.
    static func top(active: Bool) -> CGFloat { clear(active: active) + fadeLength / 2 }
    /// Under a stage, the clear top reaches down so the first row starts 28pt under its lowest card.
    private var clear: CGFloat { clear(under: stageFoot) }

    private func clear(under foot: CGFloat?) -> CGFloat {
        if stepped { return 0 }
        return foot.map { $0 + 28 - Self.fadeLength / 2 } ?? Self.clear(active: active)
    }

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
                    Button("\(conversation.items.count - shown.count) earlier", action: showEarlier)
                        .buttonStyle(.plain)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.faint)
                        .padding(.bottom, 20)
                }
                // Not while a block is open: Return typed there mustn't answer the card.
                let listening = !active || model.openShell != nil ? nil : conversation.waitingAsk?.requestId
                let lastLimit = conversation.lastLimit
                // The thread's water so far, under its latest turn, when Settings asks. The footer
                // reads the meter itself, so a new figure draws that line and not the transcript.
                let watered = showWater ? conversation.lastFooter : nil
                // An agent's task, the script's words and not anyone's message, opens its thread.
                let task = conversation.chat.agentID == nil ? nil : conversation.items.first { if case .user = $0 { true } else { false } }?.id
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    // One view a row, whatever the item draws: an item that can draw nothing, a footer
                    // with nothing to say, would have the lazy stack make every row to count them.
                    VStack(alignment: .leading, spacing: 0) {
                        view(of: entry, listening: listening, lastLimit: lastLimit, water: entry.id == watered ? conversation.water : nil, task: task)
                    }
                        .background {
                            // An item in a run is lit where it stands, in the run opened for it.
                            if lit == entry.id, case .item = entry {
                                Surface.selected
                                    .clipShape(.rect(cornerRadius: 14, style: .continuous))
                                    .padding(-8)
                                    .transition(.opacity)
                            }
                            if let kept, kept.id == entry.id {
                                Color.clear.onGeometryChange(for: TranscriptEnd.Kept.Frame.self) {
                                    .init(screen: $0.frame(in: .scrollView).minY, thread: $0.frame(in: .named(Self.thread)).minY)
                                } action: { frame in
                                    if self.kept?.under == nil {
                                        showEarlier(at: frame)
                                    } else if let y = self.kept?.scroll(for: frame, visible: content.visible) {
                                        position.scrollTo(y: y)
                                    }
                                }
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
                    .onAppear {
                        content.endSeen = true
                        place(endLaidOut: true)
                    }
                    .onDisappear {
                        let lost = end.lost(at: content.reached, resting: content.resting)
                        place(endLaidOut: false)
                        // Lost as a row came in under the others, or as the window changed size.
                        if lost { regain(settling: content.added.map { .now - $0 > .milliseconds(500) } ?? true) }
                    }
            }
            .column()
            // Under the toolbar's row, and under the title a column beside the open thread has.
            .padding(.top, clear + Self.fadeLength / 2)
            .coordinateSpace(.named(Self.thread))
        }
        .scrollIndicators(.never)
        .environment(\.openURL, model.links(in: conversation.chat.id))
        .environment(\.codeCopyLine, clear + Self.fadeLength - CodeCopy.inset)
        // A workflow's card lights the rays its agents hold on the thread's mark.
        .environment(conversation.heads)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        // Following the bottom while it grows, a reply streaming or an item arriving, is the
        // scroll view's own; scrolled up, what's read stays where it is.
        .defaultScrollAnchor(end.pinned ? .bottom : .top, for: .sizeChanges)
        .onScrollGeometryChange(for: TranscriptEnd.Room.self) { geometry in
            TranscriptEnd.Room(place: TranscriptEnd.place(offset: geometry.contentOffset.y, visible: geometry.containerSize.height, content: geometry.contentSize.height),
                               visible: geometry.containerSize.height)
        } action: { old, new in
            content.visible = new.visible
            // The composer growing with what's typed, or shrinking once it's sent, changes the
            // room the transcript has: one following its end keeps it in view, and doesn't take
            // the moment the end went under the composer for leaving it. The scroll view can say
            // the room changed with the end still in view and only then that the end went under,
            // which beside another thread left a send's column where it was.
            if old.visible != new.visible, old.place == .end, end.pinned, !end.heading {
                position.scrollTo(edge: .bottom)
                return
            }
            place(reached: new.place)
        }
        .onScrollGeometryChange(for: CGFloat.self, of: \.contentSize.height) { content.height = $1 }
        .onScrollGeometryChange(for: CGFloat.self, of: \.contentOffset.y) { content.offset = $1 }
        // The stage coming or going moves the transcript's first row: one following its end stays
        // there, and one read further up keeps what's read where it was on screen.
        .onChange(of: stageFoot) { old, new in
            if end.pinned, !end.heading {
                DispatchQueue.main.async { position.scrollTo(edge: .bottom) }
            } else {
                position.scrollTo(y: max(0, content.offset + clear(under: new) - clear(under: old)))
            }
        }
        .onScrollPhaseChange {
            content.resting = $1 == .idle
            // A hand on the scroll has it from there.
            if $1 == .tracking || $1 == .interacting { kept = nil }
        }
        // Only what's laid out is growth to tell of: thinking left out, or a call folded into
        // the run above it, adds no row.
        .onChange(of: TranscriptEnd.Tail(count: conversation.items.count + conversation.waiting.count, last: entries.last?.id)) { old, tail in
            let grew = tail.grew(from: old)
            if grew { content.added = .now }
            end.grew(laidOut: grew)
        }
        // A message sent by hand is read where it lands when the end was a screen away or less;
        // sent from further up, what's being read stays put and the pill says there's more.
        .onChange(of: conversation.handSent) {
            if end.sent() { toEnd(animated: false) }
        }
        .onChange(of: model.threadEnd) {
            if active { toEnd(animated: true) }
        }
        // The keyboard coming or going moves the column's top, and so its height: one following
        // its end keeps it, so a send that comes next lands under what's there.
        .onChange(of: active) {
            guard end.pinned, !end.heading else { return }
            DispatchQueue.main.async { position.scrollTo(edge: .bottom) }
        }
        // On appear too: ⌘K sets the reveal as it switches to the thread that builds this view.
        .onAppear {
            content.gone = false
            takeReveal()
        }
        .onDisappear { content.gone = true }
        .onChange(of: model.reveal) { takeReveal() }
        // A run coming on the glass grows its stage while the transcript is followed to its end.
        .background { StageCue(heads: conversation.heads, thread: conversation.chat.id, following: end.pinned) }
        // Its water is counted as the thread comes into view and as Settings turns water on;
        // after that its tools' results and a turn's end count it (AppModel.receive).
        .task(id: showWater) { model.readWater(for: conversation.chat) }
        // Once a view, the active one or not. A transcript built while the app is hidden, as it
        // comes forward, or behind another app can show its foot with the rows it made laid out
        // screens above and none ever appearing, and it would go on taking itself to be at the end.
        .task {
            // Nothing is laid out to look at while no window shows, so the 300 ms, the swap's fade
            // and a little, are counted from when one does, whenever in the view's life that is.
            repeat {
                if !NSApp.occlusionState.contains(.visible) {
                    for await _ in NotificationCenter.default.notifications(named: NSApplication.didChangeOcclusionStateNotification).map({ _ in }) {
                        if NSApp.occlusionState.contains(.visible) { break }
                    }
                }
                try? await Task.sleep(for: .milliseconds(300))
            } while !Task.isCancelled && !NSApp.occlusionState.contains(.visible)
            // A way to the end that's under way lands first: it doesn't bring the rows either.
            await content.jump?.value
            guard !Task.isCancelled, end.adrift(endSeen: content.endSeen) else { return }
            Self.logger.notice("A transcript of \(conversation.items.count) items came up without its end, \(Int(content.height)) tall in \(Int(content.visible)); laying it out from the top")
            fromTheTop()
        }
        .mask {
            // Fades under the top edge and above the composer instead of ending at a line.
            VStack(spacing: 0) {
                // Clear through the capsule and fading in under it, so nothing reads behind the
                // traffic lights and the capsule in the toolbar's row. Beside the open thread, a
                // column has its own title under that row: clear through it too, and the fade
                // starts that much lower.
                Color.clear.frame(height: clear)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fadeLength)
                Color.black
                // Taller while the way to the end is up, so no line reads behind it: the pill
                // sits in the fade's clear foot.
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: pill ? 34 : 24)
                Color.clear.frame(height: pill ? EndPill.height + 4 : 0)
            }
            .animation(Motion.fade, value: pill)
        }
        // Over the transcript's foot and outside its fade, so the composer under it never moves.
        .overlay(alignment: .bottom) {
            let offered = TranscriptEnd.offered(pinned: end.pinned, covered: active && (model.openShell != nil || model.openFile != nil))
            ZStack {
                if offered && pill {
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
            .animation(Motion.fade, value: offered && pill)
            .animation(Motion.fade, value: end.news)
            .task(id: offered) {
                guard offered else { return pill = false }
                try? await Task.sleep(for: .milliseconds(200))
                if !Task.isCancelled { pill = true }
            }
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
            // Still at the foot by its numbers with nothing laid out there, which two looks a
            // screen up didn't leave: the end is found from further up, as one lost is. Seen
            // sending in a column the keyboard had just come to, with the other one streaming.
            if !content.endLaidOut, content.reached == .end, !position.isPositionedByUser, !content.gone {
                return regain(settling: false)
            }
            // Scrolled away by hand in the meantime, the pill comes back.
            end.landed()
        }
    }

    /// Brings the end to a transcript that stands at its foot with no row there. From there the
    /// lazy stack makes nothing: not for a scroll to the end, by its edge or by the row named
    /// `end`, and not in a new scroll view. From the top it makes its rows, and the way back
    /// finds the end.
    private func fromTheTop() {
        _ = end.jump()
        content.jump?.cancel()
        content.jump = Task {
            position.scrollTo(edge: .top)
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            position.scrollTo(edge: .bottom)
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            position.scrollTo(id: Self.end, anchor: .bottom)
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            end.landed()
        }
    }

    /// Brings back the end the lazy stack took from a transcript following it. A row added under
    /// a long one, a turn's footer under its reply, is put at the height of the rows the stack has
    /// made until it's made itself, a thousand points for a twenty-point line, and a resize puts
    /// the rows under a reply it lays out again the same way. The scroll view follows that guess
    /// down, and in the stretch it lands in nothing is made, not for a scroll to the row named
    /// `end` either. From two screens up, or further when the guess is taller, the rows are made
    /// and measured, and the way back finds the end at its true height.
    private func regain(settling: Bool) {
        _ = end.jump()
        content.jump?.cancel()
        content.jump = Task {
            if settling {
                // A resize lays a long reply out over a few frames, its height going up and down
                // meanwhile, and a look taken then lands where nothing is made yet: it waits for
                // the height to hold, a second at most.
                var height = content.height
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if Task.isCancelled || content.endLaidOut || content.height == height { break }
                    height = content.height
                }
            }
            var looks = 0
            var from = CGFloat.infinity
            // Two screens higher each time, as far as the top: a guess taller than two screens
            // leaves the first look short of the rows, and a resize's more so.
            while !Task.isCancelled, !content.gone, !content.endLaidOut, content.resting, !position.isPositionedByUser, from > 0 {
                looks += 1
                from = max(0, content.height - CGFloat(2 * looks) * content.visible)
                position.scrollTo(y: from)
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                position.scrollTo(id: Self.end, anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard !Task.isCancelled, !content.gone else { return }
            if looks > 0 {
                Self.logger.notice("A transcript of \(conversation.items.count) items lost its end under it\(settling ? " in a resize" : "", privacy: .public); \(content.endLaidOut ? "found" : "not found", privacy: .public) in \(looks) looks, \(Int(content.height)) tall in \(Int(content.visible))")
            }
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
            // A call folded into a run is found by its run's row.
            let row = entries.firstIndex { $0.holds(id) }
            if let row {
                position.scrollTo(y: content.height * CGFloat(row) / CGFloat(entries.count))
                try? await Task.sleep(for: .milliseconds(50))
            }
            withAnimation(Motion.move) { position.scrollTo(id: row.map { entries[$0].id } ?? id, anchor: .center) }
            withAnimation(Motion.fade) { lit = id }
            if let row, case .run = entries[row] {
                // The run opens on the call, which may stand a screen below the run's own line.
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(Motion.move) { position.scrollTo(id: ToolRunRow.name(of: id), anchor: .center) }
            }
            // The scroll view speaks only when its place changes, and an item in the last
            // screenful, or a thread shorter than the window, leaves it at the end it was at: once
            // the move has settled its word is taken as it stands.
            try? await Task.sleep(for: Self.settling)
            end.settled()
            try? await Task.sleep(for: .seconds(1.2) - Self.settling)
            if lit == id { withAnimation(Motion.fade) { lit = nil } }
        }
    }

    /// Keeps the row under Show earlier where it stands on screen while the whole thread is
    /// laid out above it. Scrolled up, the scroll view holds its distance from the top as the
    /// thread grows, which would put the thread's first item there instead. So the row is
    /// measured first, then the scroll goes to it, and as it's laid out, and the rows over it
    /// are measured and move it, it's put back where it stood: for a second, or until a hand
    /// takes the scroll.
    private func showEarlier() {
        let first = TranscriptEntry.fold(shown, thinking: showThinking).first?.id
        // A run the cut went through is a longer run once it's whole, and starts further up.
        guard let first, TranscriptEntry.fold(conversation.items, thinking: showThinking).contains(where: { $0.id == first }) else {
            return showAll = true
        }
        kept = TranscriptEnd.Kept(id: first)
        Task {
            // A row that isn't laid out is measured nowhere, and the earlier items come in anyway.
            try? await Task.sleep(for: .milliseconds(100))
            if kept?.id == first, kept?.under == nil {
                kept = nil
                showAll = true
            }
        }
    }

    /// The row under Show earlier was measured where it stands; the earlier items come in.
    private func showEarlier(at frame: TranscriptEnd.Kept.Frame) {
        guard let row = kept?.id else { return }
        kept?.measured(at: frame)
        showAll = true
        position.scrollTo(id: row, anchor: .top)
        Task {
            try? await Task.sleep(for: .seconds(1))
            if kept?.id == row { kept = nil }
        }
    }

    /// How long a reveal's move is given to settle, out of the time its item stays lit.
    private static let settling = Duration.milliseconds(400)

    @ViewBuilder
    private func view(of entry: TranscriptEntry, listening: String?, lastLimit: UUID?, water: WaterMeter?, task: UUID?) -> some View {
        let streaming = conversation.live.id
        switch entry {
        case .item(.user(let id, let text, _, _)) where id == task:
            TaskWell(text: model.taskWell(text, of: conversation.chat))
        case .item(let item):
            ItemView(
                item: item, cwd: cwd, thread: conversation.chat.id, listening: listening,
                live: conversation.running && item.id == conversation.items.last?.id,
                limitCard: item.id == lastLimit,
                resumes: conversation.resumeAt != nil && item.id == lastLimit,
                waiting: conversation.waiting.contains { $0.id == item.id },
                stream: item.id == streaming ? conversation.live : nil, water: water)
        case .run(let items):
            ToolRunRow(items: items, cwd: cwd, thread: conversation.chat.id, live: conversation.running && items.last?.id == conversation.items.last?.id,
                       stream: items.contains { $0.id == streaming } ? conversation.live : nil,
                       lit: lit.flatMap { id in items.contains { $0.id == id } ? id : nil })
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

    /// Where what's showing is against the end, and how tall the view is.
    struct Room: Equatable {
        var place: Place
        var visible: CGFloat
    }

    /// Where what's showing is against the end, which is all the transcript asks of a scroll.
    enum Place {
        /// The end is in view: growth keeps it there, and there's nowhere for the pill to go.
        case end
        /// Within two heights of what's showing: a message sent by hand brings the end into view.
        case near
        /// Further up, where something is being read: it stays where it is.
        case away
    }

    /// A row held where it stood on screen while rows come in above it.
    struct Kept: Equatable {
        let id: UUID
        /// How far under the view's top edge it starts, once it's been measured.
        private(set) var under: CGFloat?
        /// Where the scroll stood then.
        private var from: CGFloat = 0

        /// Where a row starts, under the view's top edge and from the top of the thread.
        struct Frame: Equatable {
            var screen: CGFloat
            var thread: CGFloat

            /// Where the scroll stands.
            var scroll: CGFloat { thread - screen }
        }

        mutating func measured(at frame: Frame) {
            under = frame.screen
            from = frame.scroll
        }

        /// Where the scroll goes to put the row back, or nil while it's where it stood. Until the
        /// scroll to it has moved, the row is where the lazy stack guesses it is, or where it was
        /// laid out before; out of a view `visible` tall, it's a guess too.
        func scroll(for frame: Frame, visible: CGFloat) -> CGFloat? {
            guard let under, abs(frame.scroll - from) >= 0.5, abs(frame.screen) < visible, abs(frame.screen - under) >= 0.5 else { return nil }
            return max(0, frame.thread - under)
        }
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

        /// Whether a transcript that takes itself to be at its end has never laid that end out:
        /// what it starts as, until the row named `end` appears. A reveal unpins and a way to the
        /// end is under way, so neither is adrift.
        func adrift(endSeen: Bool) -> Bool {
            !endSeen && pinned && place == .end && !heading
        }

        /// Whether the row that is the end went out of view from a transcript following it, with the
        /// scroll view's numbers still at the end and no hand on the scroll: the lazy stack took
        /// the end away, and nobody scrolled from it.
        func lost(at reached: Place, resting: Bool) -> Bool {
            pinned && !heading && reached == .end && resting
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
            // A thread it opened ending its turn: that thread's mark on ⌘⇧I says so. A limit
            // getting close, which stops nothing: the usage glass's colour says so.
            case .opened, .nearLimit:
                continue
            // A turn OriCode started: its prompt is its own, and the reply follows what came before.
            case .woke:
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
    /// The thread the item is in: where a message's pictures are kept, and whose ask, limit or
    /// suggestion it is. Nil stands for the open one.
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
    /// The thread's water so far, on the footer under its latest turn.
    var water: WaterMeter?
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
                MessageText(text: text, waiting: waiting)
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
                WorkflowRow(call: call, thread: thread)
            } else if let plan = call.plan {
                PlanCard(plan: plan)
            } else if call.oricodeTool != nil {
                ThreadToolLine(call: call, parent: thread)
            } else {
                ToolLine(call: call, cwd: cwd)
            }
        case .ask(_, let ask):
            AskCard(ask: ask, cwd: cwd, thread: thread, listens: ask.requestId == listening)
        case .footer(_, let footer):
            FooterLine(footer: footer, water: water)
        case .note(_, let text):
            Text(text)
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .textSelection(.enabled)
        case .limited(_, let resetsAt, let window):
            if limitCard {
                LimitCard(resetsAt: resetsAt, window: window, thread: thread, resumes: resumes)
            } else {
                LimitLine(resetsAt: resetsAt, window: window, thread: thread)
            }
        case .nearLimit(_, let window, let used, let resetsAt, let said):
            NearLimitLine(window: window, used: used, resetsAt: resetsAt, said: said)
        case .shell(let id, let run):
            ShellBlockView(id: id, run: run)
        case .opened(_, let opened, let title, let finished, let resetsAt, let window):
            OpenedLine(thread: opened, title: title, finished: finished, resetsAt: resetsAt, window: window, parent: thread)
        case .suggested(_, let title, let prompt):
            SuggestedThread(title: title, prompt: prompt, thread: thread)
        case .act(_, let other, let text, let hover):
            ThreadActLine(thread: other, text: text, hover: hover, parent: thread)
        case .changed(_, let text, let reason):
            Text(text)
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .help(reason)
        case .woke:
            EmptyView()
        }
    }
}

/// Your message's words in their bubble. One longer than `Item.headLength`, a paste as a rule, is
/// drawn from its head alone, folded to its first lines until it's opened, with its size and Copy
/// for all of it underneath: a megabyte laid out as one Text held the window for a second at every
/// layout, and its thread could hardly be opened.
struct MessageText: View {
    @Environment(AppModel.self) private var model
    let text: String
    let waiting: Bool
    @State private var open = false

    /// The lines a long message shows until it's opened.
    private static let folded = 12

    /// What a folded message hands its Text: up to the line after the ones it shows, so the last
    /// still ends in an ellipsis, and no more than those lines hold at the bubble's widest. It was
    /// handed the whole head, 20,000 characters laid out for twelve lines of them.
    static func fold(_ head: Substring) -> String {
        var end = head.startIndex
        var breaks = 0
        var count = 0
        while end < head.endIndex, count < folded * 200 {
            if head[end].isNewline {
                breaks += 1
                if breaks > folded { break }
            }
            head.formIndex(after: &end)
            count += 1
        }
        return String(head[..<end])
    }

    var body: some View {
        let head = text.prefix(Item.headLength)
        let long = head.endIndex < text.endIndex
        VStack(alignment: .trailing, spacing: 6) {
            Text(long ? (open ? String(head) : Self.fold(head)) : text)
                .font(Type.body)
                .foregroundStyle(waiting ? Ink.secondary : Ink.primary)
                .lineLimit(long && !open ? Self.folded : nil)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Surface.userMessage, in: .rect(cornerRadius: 18, style: .continuous))
            if long {
                HStack(spacing: 12) {
                    let size = text.utf8.count.formatted(.byteCount(style: .file))
                    Text(open ? "The first \(Item.headLength.formatted()) characters of \(size)" : size)
                    Button(open ? "Show less" : "Show more") {
                        withAnimation(Motion.fade) { open.toggle() }
                    }
                    Button("Copy") { model.copy(text, saying: "Copied the message.") }
                }
                .font(Type.secondary)
                .foregroundStyle(Ink.faint)
                .buttonStyle(.plain)
                .padding(.trailing, 6)
            }
        }
    }
}

struct ToolLine: View {
    let call: ToolCall
    let cwd: String
    @State private var open = false

    /// What opens under a line fades in where it lands; the rows around it move at once, since
    /// moved in a glide they were drawn over it while the scroll held the transcript's foot.
    static let opening = AnyTransition.opacity.animation(Motion.fade)

    var body: some View {
        let line = ToolSummary.line(for: call, cwd: cwd)
        let path = ToolSummary.path(for: call)
        let shown = path.map { ToolSummary.relative($0, to: cwd) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button {
                    open.toggle()
                } label: {
                    Text(shown.map { line.hasSuffix($0) ? String(line.dropLast($0.count)) : line } ?? line)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(call.result == nil)
                if let path, let shown {
                    FileLink(path: path, label: shown, cwd: cwd)
                }
                // A call still out shows nothing more: the thread's mark says it works.
                if call.isError {
                    Text(call.stopped ? "stopped" : "failed").foregroundStyle(Ink.faint)
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
                .transition(ToolLine.opening)
            }
        }
    }
}

/// A run of tool calls as one row that says what they did, with the lines its edits added and
/// removed; a click opens the calls under it as their own lines.
struct ToolRunRow: View {
    let items: [Item]
    let cwd: String
    /// The thread it's in, whose calls about other threads open them beside it.
    var thread: UUID?
    /// The turn is still in this run.
    let live: Bool
    /// The text streaming into one of its items, thinking between the calls.
    var stream: LiveText?
    /// One of its calls that a reveal asked for: the run opens on it and the call is lit.
    var lit: UUID?
    @State private var open = false

    /// What a call inside an open run is scrolled to by, its item's id being the run's own row's
    /// when it is the run's first.
    static func name(of item: UUID) -> String { "call:" + item.uuidString }

    /// The run's items with a wait or a read on a thread that the call after it repeats left out,
    /// so a lead waiting six times on the same thread shows one line, the latest.
    static func collapsed(_ items: [Item]) -> [Item] {
        func repeated(_ call: ToolCall) -> String? {
            guard let tool = call.oricodeTool, tool == "wait_thread" || tool == "read_thread", !call.isError else { return nil }
            return tool + (call.otherThread.id?.uuidString ?? "")
        }
        var kept: [Item] = []
        var next: String?
        for item in items.reversed() {
            guard case .tool(_, let call) = item else {
                kept.append(item)
                next = nil
                continue
            }
            let key = repeated(call)
            if key == nil || key != next { kept.append(item) }
            next = key
        }
        return kept.reversed()
    }

    var body: some View {
        let calls = items.compactMap { item -> ToolCall? in
            if case .tool(_, let call) = item { call } else { nil }
        }
        let failed = calls.count { $0.isError && !$0.stopped }
        let diffs = calls.compactMap { $0.isEdit && !$0.isError && $0.result != nil ? Diff.of($0, cwd: cwd) : nil }
        VStack(alignment: .leading, spacing: 0) {
            Button {
                open.toggle()
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
                        .animation(Motion.fade, value: open)
                }
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                let shown = Self.collapsed(items)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        ItemView(item: item, cwd: cwd, thread: thread, listening: nil, live: live && item.id == items.last?.id,
                                 stream: item.id == stream?.id ? stream : nil)
                            .id(Self.name(of: item.id))
                            .background {
                                if item.id == lit {
                                    Surface.selected
                                        .clipShape(.rect(cornerRadius: 10, style: .continuous))
                                        .padding(-6)
                                        .transition(.opacity)
                                }
                            }
                            .padding(.top, index == 0 ? 0 : TranscriptView.spacing(before: item, after: shown[index - 1]))
                    }
                }
                .padding(.leading, 10)
                .padding(.top, 8)
                .transition(ToolLine.opening)
            }
        }
        // A row the lazy stack makes while its call is lit has no change to hear of, and one
        // that comes back on screen hears only of the light going out.
        .onChange(of: lit, initial: true) { was, lit in
            if was != nil || lit != nil { open = true }
        }
    }
}

/// One of OriCode's own calls, in words. One about another thread opens it beside this one, as
/// a click on that thread's row on ⌘⇧I would.
struct ThreadToolLine: View {
    @Environment(AppModel.self) private var model
    let call: ToolCall
    /// The thread the call is in; nil stands for the open one.
    var parent: UUID?
    @State private var hovering = false

    var body: some View {
        let other = call.otherThread.id
        HStack(spacing: 4) {
            Button {
                if let other { model.openOpened(other, from: parent) }
            } label: {
                Text(ToolSummary.line(for: call, cwd: "", titles: { model.chat(withID: $0)?.title }))
                    .underline(hovering && other != nil)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(other == nil)
            .onHover { hovering = $0 }
            .pointerStyle(other == nil ? nil : .link)
            if call.isError {
                Text(call.stopped ? "stopped" : "failed").foregroundStyle(Ink.faint)
            }
        }
        .font(Type.secondary)
        .foregroundStyle(Ink.secondary)
        .help(call.isError ? call.result ?? "" : "")
    }
}

/// A path that opens the file read-only; underlined while the mouse is on it.
struct FileLink: View {
    @Environment(AppModel.self) private var model
    let path: String
    let label: String
    /// Its thread's folder, which the file opens from.
    let cwd: String
    @State private var hovering = false

    var body: some View {
        Button {
            model.openFile(path, in: cwd)
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

/// Thinking, folded to one line once it's done; the summary Claude streamed is underneath. While
/// it streams the thread's working mark says so, and the line waits.
struct ThinkingLine: View {
    let text: String
    let live: Bool
    @State private var open = false

    var body: some View {
        if live {
            Color.clear.frame(height: 0)
        } else {
            line
        }
    }

    private var line: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("Thought")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .animation(Motion.fade, value: open)
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
                    .transition(ToolLine.opening)
            }
        }
    }
}

/// What a turn did. Its files always; how long it took and what it cost only when
/// Settings › Conversation asks, and nothing at all when there's nothing to say. The thread's
/// latest turn has the thread's water after it, when Settings asks for that: on the turn's line
/// where the column has room for both, and under it where it hasn't.
struct FooterLine: View {
    let footer: TurnFooter
    var water: WaterMeter?
    @AppStorage(TranscriptSettings.showTime) private var showTime = false
    @AppStorage(TranscriptSettings.showCost) private var showCost = false

    var body: some View {
        let turn = turn(footer.words(time: showTime, cost: showCost))
        Group {
            if let water = water?.reading.map({ Text($0.footer).foregroundStyle(Ink.secondary) }) {
                if let turn {
                    ViewThatFits(in: .horizontal) {
                        // One run of text, so the dot before the water is parted as the turn's own are.
                        Text("\(turn) · \(water)")
                        VStack(alignment: .leading, spacing: 4) {
                            turn
                            water
                        }
                    }
                } else {
                    water
                }
            } else if let turn {
                turn
            }
        }
        .font(Type.secondary)
        .foregroundStyle(Ink.faint)
    }

    /// The turn's words and its files as one run of text, a dot with a space each side between
    /// each, or nil when it has nothing to say.
    private func turn(_ words: String) -> Text? {
        var parts: [Text] = words.isEmpty ? [] : [Text(words)]
        if footer.files > 0 {
            parts.append(Text("\(footer.files) \(footer.files == 1 ? "file" : "files")"))
            // Counts' green and red, as text so they sit in the run.
            let added = Text("+\(footer.added)").foregroundStyle(Ink.added.opacity(0.8))
            let deleted = Text("−\(footer.deleted)").foregroundStyle(Ink.deleted.opacity(0.8))
            parts.append(Text("\(added) \(deleted)").font(Type.secondary.monospacedDigit()))
        }
        guard var line = parts.first else { return nil }
        for part in parts.dropFirst() { line = Text("\(line) · \(part)") }
        return line
    }
}

enum TranscriptSettings {
    static let showTime = "showTurnTime"
    static let showCost = "showTurnCost"
    /// The thread's estimated water, under its latest turn and in the usage card. Off until asked for.
    static let showWater = "showWater"
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

/// An agent's task where its thread opens, in the well a hop shows it in on the stage, left and
/// not as a bubble: it's the script's words, never something the user typed.
struct TaskWell: View {
    let text: AttributedString

    var body: some View {
        Text(text)
            .font(Type.secondary)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, StageLayout.wellPadding.height)
            .padding(.horizontal, StageLayout.wellPadding.width)
            .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
    }
}
