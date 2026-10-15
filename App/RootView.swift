import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updates.self) private var updates
    @AppStorage(Glass.key) private var glass = Glass.defaultTint

    var body: some View {
        GeometryReader { window in
            ZStack {
                Color.black.opacity(glass)
                    .ignoresSafeArea()
                let conversation = model.currentConversation
                // A thread whose events are still being read lays out as it will once they're in,
                // so the composer doesn't move for the moment it takes.
                let started = conversation?.started ?? model.chat?.started ?? false
                // A pinned drawer is a list you keep open, so the conversation moves over for it.
                let pinned = model.drawerDocked ? Drawer.width + Drawer.inset * 2 : 0
                // Two threads take equal halves when each gets a column's least width. Under that
                // the pair folds to the open thread, and the window is the one it was with one.
                let room = window.size.width - pinned >= Column.least * 2
                let beside = room ? model.besideShown : nil
                let half = (window.size.width - pinned) / 2
                // Beside a pinned drawer in a narrow window the review would be too narrow to
                // read, so the drawer stands aside for as long as the review is up.
                let cramped = model.reviewShown && window.size.width - Island.lead(pinned: true) - Island.side < ReviewDesign.least
                let right = model.composerHalf == .right
                // Left to right, the threads on the glass, each with a composer under it; with
                // none begun, the window's one composer.
                let threads: [Chat?] = if let beside { right ? [beside, model.chat] : [model.chat, beside] } else { [model.chat] }
                // The open thread alone, folded or a draft with the other waiting behind it, keeps
                // its half's composer, or the first message from the right half's draft would
                // hand the composer it was typed in to the thread coming back on the left.
                let halves: [AppModel.Half] = beside == nil && right ? [.right] : [.left, .right]
                // A drawer that isn't in its place passes over the conversation for a moment, and the left
                // composer's left end draws back out from under it while it's out. Its right end,
                // with the picker and Send, doesn't move, and nor does a composer in the right half.
                let clear = model.drawerShown && !model.drawerDocked
                    ? Self.clearing(width: beside == nil ? window.size.width : half) : 0
                VStack(spacing: 0) {
                    if let chat = model.chat, started {
                        // Keyed by thread, so a second one arriving, or the two trading the
                        // keyboard, makes neither transcript again: each keeps its scroll.
                        HStack(spacing: 0) {
                            ForEach(beside.map { right ? [$0, chat] : [chat, $0] } ?? [chat], id: \.id) { thread in
                                let open = thread.id == chat.id
                                ZStack {
                                    if let conversation = model.conversations[thread.id] {
                                        TranscriptView(conversation: conversation, cwd: thread.cwd, active: open)
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                // A click in a column puts the keyboard in its thread. Its title
                                // capsule is laid over this, so the cross there closes its own side.
                                .simultaneousGesture(TapGesture().onEnded {
                                    if !open { model.select(thread) }
                                })
                                // Gone at once from the column the keyboard comes to, where the
                                // crossing's drop takes its place, and in at once over the one it
                                // left, its words showing when the drop there has spread: a fade
                                // here would draw its tint and the drop's over each other.
                                .overlay(alignment: .top) {
                                    if !open {
                                        BesideTitle(chat: thread, conversation: model.conversations[thread.id])
                                    }
                                }
                                .transition(.asymmetric(insertion: Self.swap, removal: Self.leave))
                            }
                        }
                        .transition(.asymmetric(insertion: Self.rise, removal: Self.leave))
                    } else {
                        Spacer(minLength: 0)
                        EmptyStateView(
                            line: model.project == nil ? "Just type, or add a project with \(model.shortcuts.label(.addProject))." : "Where do we pick up?",
                            rays: conversation?.heads.rayAgents ?? [:],
                            waiting: conversation?.waitingAsk != nil)
                            .padding(.bottom, 28)
                            .transition(.asymmetric(insertion: Self.settle, removal: Self.lift))
                    }
                    // The composers in one place in the tree, whichever layout is showing, so the
                    // first message moves the one there is rather than swapping it for another.
                    // With no project it's there too: what's sent then starts a thread without a
                    // folder. Keyed by half and not by thread, so another thread opened shows in
                    // the same composer, and a second coming beside doesn't make the first again.
                    // Each stands on the same line, so one growing with its text leaves the other.
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(Array(zip(halves, threads)), id: \.0) { side, thread in
                            let conversation = thread.flatMap { model.conversations[$0.id] }
                            Composer(chat: thread, conversation: conversation, state: model.composer(for: thread),
                                     running: conversation?.running ?? false, windowHeight: window.size.height,
                                     paired: beside != nil)
                                // Moves as one piece: otherwise a label that changes with the thread,
                                // like the model's name, is drawn where the composer is going while
                                // the rest of it is still on the way.
                                .geometryGroup()
                                .padding(.leading, side == halves[0] ? clear : 0)
                                .column()
                                .transition(.asymmetric(insertion: Self.swap, removal: Self.leave))
                        }
                    }
                    // The one there was glides to its half as a second comes beside it.
                    .animation(Motion.glide, value: beside?.id)
                    // Above the transcript, so the slash menu can rise over it.
                    .zIndex(1)
                    if !started {
                        // Equal room under the composer and over the mark, and the mark's own
                        // height again, so it's the composer that sits in the middle.
                        Spacer(minLength: 0)
                        Color.clear.frame(height: EmptyStateView.height + 28)
                    }
                    // The capsule sits 28pt above the window's bottom edge; notes live in that gap.
                    // A ZStack, because EngineNote is an EmptyView when there's nothing to say,
                    // and a frame on an EmptyView takes no space at all.
                    ZStack {
                        Color.clear
                        EngineNote()
                    }
                    .frame(height: Self.notes)
                    // Under the half with the keyboard at once: nothing crosses with it.
                    .padding(right ? .leading : .trailing, beside == nil ? 0 : half)
                    .animation(Motion.glide, value: beside == nil)
                }
                // Whatever empties the window (a new thread, ⌘W, another project) sends the
                // composer back up to the middle the way the first message sends it down, once
                // the old transcript has gone, so it never passes over a line of it.
                .animation(started ? Motion.glide : Motion.glide.delay(0.1), value: started)
                .padding(.leading, pinned)
                .onChange(of: room, initial: true) { model.roomForTwo = room }
                .onChange(of: cramped, initial: true) { model.standAside(cramped) }
                // A thread beside that was folded away or behind a draft said what it had to in
                // a notification. Drawn again, it's being read here.
                .onChange(of: beside?.id) { _, drawn in
                    if let drawn { model.notifier.clear(chatID: drawn) }
                }
                .simultaneousGesture(TapGesture().onEnded {
                    if !model.drawerDocked { model.hideDrawer() }
                    if model.commandCenterShown { model.closeCommandCenter() }
                    if model.headsShown { model.closeHeads() }
                    if model.fileFinderShown { model.toggleFileFinder() }
                    if model.sideShown { model.closeSide() }
                    if model.pullShown { model.closePull() }
                    if model.openFile != nil { model.closeFile() }
                    if model.reviewShown { model.closeReview() }
                    if model.openShell != nil { model.closeBlock() }
                })
            }
        }
        .ignoresSafeArea(edges: .top)
        // SwiftUI keeps the I-beam of selectable text that goes from under a resting pointer, a
        // transcript left for a new thread say, and sets it again on every move until that text
        // comes back. A style of the window's own under everything is what it falls back to.
        .pointerStyle(.default)
        // The picker rises out of the composer into the terminal's place, and can't draw over it.
        .onChange(of: model.modelPickerShown) { _, shown in
            if shown {
                model.closeBlock()
                if model.reviewShown { model.closeReview() }
            }
        }
        .confirmationDialog(
            "Delete “\(model.deletingChat?.title ?? "")”?",
            isPresented: Binding(get: { model.deletingChat != nil }, set: { if !$0 { model.deletingChat = nil } }),
            presenting: model.deletingChat
        ) { chat in
            if chat.worktreeBranch != nil, let loss = model.deletingLoss {
                if loss.isEmpty {
                    Button("Delete and Remove Worktree", role: .destructive) { model.delete(chat, removingWorktree: true) }
                        .keyboardShortcut(.defaultAction)
                    Button("Delete, Keep Worktree") { model.delete(chat, removingWorktree: false) }
                } else {
                    Button("Delete, Keep Worktree") { model.delete(chat, removingWorktree: false) }
                        .keyboardShortcut(.defaultAction)
                    Button("Delete and Remove Worktree", role: .destructive) { model.delete(chat, removingWorktree: true) }
                }
            } else {
                Button("Delete", role: .destructive) { model.delete(chat) }
                    .keyboardShortcut(.defaultAction)
            }
            Button("Cancel", role: .cancel) {}
        } message: { chat in
            let stopping = model.shellsStopping(in: [chat])
            if let branch = chat.worktreeBranch, let loss = model.deletingLoss {
                Text([loss.isEmpty ? "Everything on \(branch) is on another branch or remote, so its worktree can go too." : loss.sentence, stopping]
                    .compactMap { $0 }.joined(separator: " "))
            } else {
                Text(["Its transcript goes with it.", stopping].compactMap { $0 }.joined(separator: " "))
            }
        }
        .confirmationDialog(
            "Remove “\(model.removingProject?.name ?? "")” from OriCode?",
            isPresented: Binding(get: { model.removingProject != nil }, set: { if !$0 { model.removingProject = nil } }),
            presenting: model.removingProject
        ) { project in
            Button("Remove", role: .destructive) { model.remove(project) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { project in
            let threads = project.chats.filter(\.started).count
            let worktrees = project.chats.contains { $0.worktreeBranch != nil }
            let goes = switch threads {
            case 0: "It has no threads."
            case 1: "Its thread goes with it."
            default: "Its \(threads) threads go with it."
            }
            let stopping = model.shellsStopping(in: project.chats)
            // No folder's own folder goes when nothing is in it, and nothing else on the Mac does.
            let folder = project.isNoFolder ? "Whatever they wrote on your Mac stays" : "The folder stays\(worktrees ? ", and so do its worktrees" : "")"
            Text("\(goes) \(folder).\(stopping.map { " " + $0 } ?? "")")
        }
        .sheet(isPresented: Binding(get: { model.showingShortcuts }, set: { model.showingShortcuts = $0 })) {
            ShortcutsSheet()
        }
        .overlay(alignment: .top) {
            TitleBarGlass()
                .frame(height: TitleBar.height)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            // The toolbar has no trailing side of its own with the title hidden, so the review's
            // button is laid out on the lights' line the way the capsule is.
            ReviewButton()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.reviewButtonWidth = $0 }
                .frame(height: TitleBar.height)
                .padding(.trailing, Island.edge)
                .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            if let block = model.openShell {
                // A block drawn full, over the conversation's side of the window down to 12pt above
                // the composer however tall it has grown, rising out of the thread where its block
                // is; under the other panels, which can open over it.
                GeometryReader { area in
                    // With two threads up, the column without the keyboard has its title on the
                    // line under the toolbar's row, and the panel starts under that.
                    let top = 12 + (model.besideShown == nil ? 0 : BesideTitle.height)
                    let height = max(60, model.composerTop - area.frame(in: .global).minY - top - 12)
                    ZStack(alignment: .top) {
                        // Around the panel the transcript is blank scroll view, whose clicks never
                        // reach the conversation's tap that puts a block back, so this takes them.
                        // A button, since a tap gesture on clear space didn't take the clicks the
                        // panel's buttons did.
                        Button { model.closeBlock() } label: {
                            Color.clear.contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHidden(true)
                        .frame(height: height + top)
                        BlockPanel(block: block)
                            .over(named: "Terminal")
                            .id(block.id)
                            .frame(maxWidth: 900)
                            .frame(height: height)
                            .padding(.top, top)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 40)
                            .padding(.leading, model.drawerDocked ? Drawer.width + Drawer.inset * 2 : 0)
                    }
                }
                .opacity(model.stagingBlock == block.id ? 0 : 1)
                .scaleEffect(model.stagingBlock == block.id ? 0.96 : 1, anchor: .bottom)
                // In already, and unseen, when it rises; only its going is a transition.
                .transition(.asymmetric(insertion: .identity, removal: .scale(scale: 0.96, anchor: .bottom).combined(with: .opacity)))
            }
        }
        .overlay(alignment: .top) {
            if let file = model.openFile {
                // Down to 12pt above the composer however tall it has grown, as the review and a
                // block stop; over a thread not begun, whose composer waits in the middle, down
                // to where a one-line composer would be.
                GeometryReader { area in
                    let low = model.currentConversation?.started ?? model.chat?.started ?? false
                    // Under the other column's capsule with two threads up, as a block is.
                    let inset: CGFloat = model.besideShown == nil ? 20 : 12 + BesideTitle.height
                    let top = area.frame(in: .global).minY + inset
                    let bottom = low && model.composerTop > 0 ? model.composerTop - 12 : area.frame(in: .global).maxY - 90
                    FileViewer(file: file)
                        .over(named: file.path)
                        .frame(height: max(120, bottom - top))
                        .padding(.top, inset)
                        .padding(.horizontal, 40)
                        // A pinned drawer covers the left of the window; the file sits beside it.
                        .padding(.leading, model.drawerDocked ? Drawer.width + Drawer.inset * 2 : 0)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            // Under the island, so the window capsule's title rides over it.
            if let crossing = model.crossing {
                CrossingGoo(crossing: crossing)
                    .id(crossing.id)
                    .ignoresSafeArea()
            }
        }
        .overlay(alignment: .top) {
            // In the toolbar's row, level with the traffic lights AppKit centres in it, and over an
            // open block or file, which ⌘K and ⌘P open over.
            Island()
                // Clear of the lights and the sidebar button on the left, and of the review's
                // button on the right, however wide its counts have made it; beside a pinned
                // drawer, the column's margin from it.
                .padding(.leading, Island.lead(pinned: model.drawerDocked))
                .padding(.trailing, Island.trail(button: model.reviewButtonWidth, update: updates.phase != .idle))
                .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            // Full height and under the title bar, so the traffic lights sit inside its first row.
            Drawer()
                .over(named: "Threads")
                .padding(Drawer.inset)
                .offset(x: model.drawerShown ? 0 : -(Drawer.width + Drawer.inset * 3))
                // Never quite gone once made: at nothing SwiftUI takes the thread list's table out
                // of the window and makes it again on the next open, which was most of that frame.
                // And no allowsHitTesting, which wraps the table in a view of its own that it
                // moves into and out of on each change; out of the window, there's nothing to hit.
                .opacity(model.drawerShown ? 0.999 : model.drawerBuilt ? 0.02 : 0)
                .accessibilityHidden(!model.drawerShown)
                .ignoresSafeArea()
        }
        // A toolbar item, so AppKit sets it beside the traffic lights and on their line; the
        // toolbar itself draws nothing, and the glass and the drawer show through it.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SidebarButton()
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .overlay(alignment: .leading) {
            // As wide as the room the transcript column always leaves at the left.
            Color.clear
                .frame(width: 20)
                .contentShape(.rect)
                .onHover { model.hotZone($0) }
        }
    }

    /// The gap under the composer, where the notes are.
    private static let notes: CGFloat = 28

    /// The composer's width with a drawer out over the narrowest window, 720pt.
    static let drawnBack: CGFloat = 388

    /// How much of the column's left end a drawer covers when the column is centred in this
    /// width, the window's or a left half's, with the margin a pinned one leaves. A half's column
    /// is narrower than the narrowest window's, and there the composer draws back only as far as
    /// it does in that window: the drawer lies over the rest of it, where giving it all up would
    /// leave the field no width between the composer's own buttons.
    static func clearing(width: CGFloat) -> CGFloat {
        let column = min(Column.width, width - Column.margin * 2)
        let covered = Drawer.width + Drawer.inset * 2 + Column.margin - (width - column) / 2
        return max(0, min(covered, column - drawnBack))
    }

    /// The first message's transcript rises in behind the composer once it has mostly gone past,
    /// instead of under it.
    private static let rise = AnyTransition.opacity.combined(with: .offset(y: 24)).animation(Motion.glide.delay(0.22))
    /// A transcript taking another's place in its half, or coming beside one with its composer,
    /// fades in once whatever was there has gone.
    private static let swap = AnyTransition.opacity.animation(Motion.fade.delay(0.1))
    /// A transcript leaving fades before anything moves in: the composer waits for it.
    private static let leave = AnyTransition.opacity.animation(.easeOut(duration: 0.1))
    /// The mark lifts away as the first message sends the composer down, and settles back from
    /// the same place as an empty thread brings the composer up.
    private static let lift = AnyTransition.opacity.combined(with: .offset(y: -36)).combined(with: .scale(scale: 0.92))
    private static let settle = lift.animation(Motion.glide.delay(0.18))
}

/// Right of the traffic lights: hovering opens the drawer the way the left edge does,
/// clicking pins it, like ⌘B.
struct SidebarButton: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button {
            model.toggleDrawerPin()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14))
                .foregroundStyle(hovering || model.drawerPinned ? Ink.primary : Ink.secondary)
                .frame(width: 28, height: 22)
                .background(hovering ? Surface.hover : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            model.hotZone(inside)
        }
        .help((model.threadsOut ? "Hide threads" : "Show threads") + " (\(model.shortcuts.label(.toggleThreads)))")
        .accessibilityLabel(model.threadsOut ? "Hide threads" : "Show threads")
    }
}

/// The window's toolbar row: AppKit makes a unified toolbar 52pt tall and centres the traffic
/// lights in it, so the capsule and the drawer's first row are laid out to the same line.
enum TitleBar {
    static let height: CGFloat = 52
}

/// The transcript's centred column: 760pt at most, 20pt from the edges below that.
enum Column {
    static let width: CGFloat = 760
    static let margin: CGFloat = 20
    /// The least room a column is given when two threads share the window.
    static let least: CGFloat = 440
}

extension View {
    func column() -> some View {
        frame(maxWidth: Column.width)
            .padding(.horizontal, Column.margin)
            .frame(maxWidth: .infinity)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// The capsule over the column the keyboard isn't in, of the window capsule's family, so it reads
/// as that thread's title and not as a line of its transcript: the mark at its left end while the
/// thread works, drawn as the window's capsule draws it, and at its right end, away from the mark,
/// a cross while the pointer is on it, the way a tab closes. A click brings the keyboard over, and
/// the capsule with it, as a drop that runs up into the window's (CrossingGoo).
struct BesideTitle: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    let conversation: Conversation?
    @State private var hovering = false

    static let height = TitleCapsule.height
    private static let cross: CGFloat = 16

    var body: some View {
        let working = conversation?.working == true
        // Its words stand aside while the crossing's drops are out, and come back where one lands.
        let crossing = model.crossing != nil
        Button {
            model.select(chat)
        } label: {
            Text(chat.title)
                .foregroundStyle(Ink.secondary)
                .truncationMode(.tail)
                .opacity(crossing ? 0 : 1)
                .font(Type.secondary)
                .lineLimit(1)
                // Room for the cross whether it shows or not, so the capsule keeps its width
                // under the pointer, and as much at the left without the mark, so the title
                // stays in the column's middle.
                .padding(.leading, working ? 12 + TitleCapsule.mark + 6 : Self.cross + 8)
                .padding(.trailing, Self.cross + 8)
                .frame(height: Self.height)
                // While the keyboard crosses, its tint is the crossing's goo.
                .background(crossing ? .clear : hovering ? Surface.selected : Surface.drawer, in: .capsule)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.besideCapsuleFrame = $0 }
                .overlay(alignment: .leading) {
                    if working, let conversation {
                        ThreadMark(conversation: conversation)
                            .frame(width: TitleCapsule.mark, height: TitleCapsule.mark)
                            .padding(.leading, 10)
                            .opacity(crossing ? 0 : 1)
                            .transition(.opacity)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help("Bring the keyboard to this thread")
        .overlay(alignment: .trailing) {
            Button {
                model.closeOtherSide()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: Self.cross, height: Self.cross)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .opacity(hovering && !crossing ? 1 : 0)
            .help("Close this side (\(model.shortcuts.label(.closeOtherSide)))")
            .accessibilityLabel("Close \(chat.title)")
        }
        .animation(Motion.fade, value: hovering)
        .animation(Motion.fade, value: crossing)
        .animation(Motion.move, value: working)
        .onHover { hovering = $0 }
        .column()
        .padding(.top, TitleBar.height)
    }
}

/// One quiet line when the engine can't run, never an alert.
struct EngineNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let note = model.modeNote ?? model.note {
                // git's own words come as several lines, a rejected push as four, and the gap
                // under the composer holds one: they run on as one line that gives way at its
                // end, and the pointer shows them whole.
                Text(Self.line(note))
                    .truncationMode(.tail)
                    .help(note)
            } else if model.engineState == .ready || model.engineState == .starting, model.agentDown == nil,
                      let away = model.runningOutOfView {
                RunningLine(block: away.block, more: away.more)
            } else if model.engineState == .ready, model.agentDown == nil, let pull = model.pull {
                PullLine(pull: pull)
            } else {
                engineLine
            }
        }
        .font(Type.secondary)
        .foregroundStyle(Ink.secondary)
        .lineLimit(1)
        .frame(maxWidth: Column.width - 40)
        .padding(.horizontal, Column.margin)
        .animation(Motion.fade, value: model.engineState)
        .animation(Motion.fade, value: model.agentDown)
        .animation(Motion.fade, value: model.note)
        .animation(Motion.fade, value: model.modeNote)
    }

    /// A note's lines as one, each after the last, with one space where git lined its columns up.
    static func line(_ note: String) -> String {
        note.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @ViewBuilder
    private var engineLine: some View {
        Group {
            switch model.engineState {
            case .starting:
                EmptyView()
            case .ready:
                if let agent = model.agentDown, let hint = agent.hint {
                    // A CLI that isn't there won't be found by asking again, nor one turned off;
                    // a login can be.
                    if agent.state == .missing || agent.state == .off {
                        Text(LocalizedStringKey(hint))
                    } else {
                        HStack(spacing: 6) {
                            Text(LocalizedStringKey(hint))
                            retry { await model.checkProvider(agent.id) }
                        }
                    }
                }
            case .noNode(let message):
                Text(LocalizedStringKey(message))
            case .stopped:
                HStack(spacing: 6) {
                    Text("Engine stopped.")
                    retry { await model.startEngine() }
                }
            }
        }
    }

    private func retry(_ action: @escaping @MainActor () async -> Void) -> some View {
        Button("Retry") {
            Task { await action() }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ink.primary)
    }
}

/// A command still running whose block has scrolled out of view: which, with a way back to it
/// and a way to stop it.
struct RunningLine: View {
    @Environment(AppModel.self) private var model
    let block: ShellBlock
    let more: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(ToolSummary.firstLine(block.command)).font(Type.mono).lineLimit(1).truncationMode(.middle)
            Text(more > 0 ? "and \(more) more are running" : "is running")
            Text("·").foregroundStyle(Ink.faint)
            Button("Show") { model.reveal = block.id }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.primary)
            Button("Stop") { block.stop() }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.primary)
                .help("Stop it (⌃C)")
        }
        .frame(maxWidth: Column.width - 40)
    }
}

struct EmptyStateView: View {
    /// The mark, the gap and the line, for centring what's under it.
    static let height: CGFloat = 44 + 14 + 18

    let line: String
    /// The agent on each lit ray.
    var rays: [Int: String] = [:]
    var waiting = false

    var body: some View {
        VStack(spacing: 14) {
            RaysMark(slots: Set(rays.keys), turning: !rays.isEmpty, waiting: waiting, colors: MarkPalette.colors(rays))
                .frame(width: 44, height: 44)
            Text(line)
                .font(Type.body)
                .foregroundStyle(Ink.secondary)
        }
    }
}

