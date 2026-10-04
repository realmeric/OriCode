import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Glass.key) private var glass = Glass.defaultTint
    /// Whether the last layout had a transcript in it: one arriving where there wasn't one comes
    /// up behind the travelling composer, and one taking another thread's place only fades in.
    @State private var hadTranscript = false

    var body: some View {
        GeometryReader { window in
            ZStack {
                Color.black.opacity(glass)
                    .ignoresSafeArea()
                let conversation = model.currentConversation
                // A thread whose events are still being read lays out as it will once they're in,
                // so the composer doesn't move for the moment it takes.
                let started = conversation?.started ?? model.chat?.started ?? false
                // An unpinned drawer passes over the conversation for a moment, and the composer's
                // left end draws back out from under it while it's out. The right end, with the
                // picker and Send, doesn't move.
                let clear = model.drawerShown && !model.drawerPinned ? Self.clearing(width: window.size.width) : 0
                VStack(spacing: 0) {
                    if let chat = model.chat, started {
                        ZStack {
                            if let conversation { TranscriptView(conversation: conversation, cwd: chat.cwd) }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(chat.id)
                        .transition(.asymmetric(insertion: hadTranscript ? Self.swap : Self.rise, removal: Self.leave))
                    } else {
                        Spacer(minLength: 0)
                        EmptyStateView(
                            line: model.project == nil ? "Add a project to start." : "Where do we pick up?",
                            rays: conversation?.heads.rayAgents ?? [:],
                            waiting: conversation?.waitingAsk != nil)
                            .padding(.bottom, 28)
                            .transition(.asymmetric(insertion: Self.settle, removal: Self.lift))
                    }
                    // One composer in one place in the tree, whichever layout is showing, so the
                    // first message moves it rather than swapping it for another.
                    if model.project != nil {
                        Composer(running: conversation?.running ?? false, windowHeight: window.size.height)
                            // Moves as one piece: otherwise a label that changes with the thread,
                            // like the model's name, is drawn where the composer is going while
                            // the rest of it is still on the way.
                            .geometryGroup()
                            .padding(.leading, clear)
                            .column()
                            // Above the transcript, so the slash menu can rise over it.
                            .zIndex(1)
                    }
                    if !started {
                        // Equal room under the composer and over the mark, and the mark's own
                        // height again, so it's the composer that sits in the middle.
                        Spacer(minLength: 0)
                        Color.clear.frame(height: model.project == nil ? 0 : EmptyStateView.height + 28)
                    }
                    // The capsule sits 28pt above the window's bottom edge; notes live in that gap.
                    // A ZStack, because EngineNote is an EmptyView when there's nothing to say,
                    // and a frame on an EmptyView takes no space at all.
                    ZStack {
                        Color.clear
                        EngineNote()
                    }
                    .frame(height: 28)
                }
                // Whatever empties the window (a new thread, ⌘W, another project) sends the
                // composer back up to the middle the way the first message sends it down, once
                // the old transcript has gone, so it never passes over a line of it.
                .animation(started ? Motion.glide : Motion.glide.delay(0.1), value: started)
                .onAppear { hadTranscript = started }
                .onChange(of: started) { _, now in hadTranscript = now }
                // A pinned drawer is a list you keep open, so the conversation moves over for it.
                .padding(.leading, model.drawerPinned && model.drawerShown ? Drawer.width + Drawer.inset * 2 : 0)
                .simultaneousGesture(TapGesture().onEnded {
                    if !model.drawerPinned { model.hideDrawer() }
                    if model.commandCenterShown { model.closeCommandCenter() }
                    if model.headsShown { model.closeHeads() }
                    if model.fileFinderShown { model.toggleFileFinder() }
                    if model.sideShown { model.closeSide() }
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
            Text("\(goes) The folder stays\(worktrees ? ", and so do its worktrees" : "").\(stopping.map { " " + $0 } ?? "")")
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
                .frame(height: TitleBar.height)
                .padding(.trailing, 14)
                .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            if let block = model.openShell {
                // A block drawn full, over the conversation's side of the window down to 12pt above
                // the composer however tall it has grown, rising out of the thread where its block
                // is; under the other panels, which can open over it.
                GeometryReader { area in
                    let height = max(60, model.composerTop - area.frame(in: .global).minY - 24)
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
                        .frame(height: height + 12)
                        BlockPanel(block: block)
                            .id(block.id)
                            .frame(maxWidth: 900)
                            .frame(height: height)
                            .padding(.top, 12)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 40)
                            .padding(.leading, model.drawerPinned && model.drawerShown ? Drawer.width + Drawer.inset * 2 : 0)
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
                FileViewer(file: file)
                    .padding(.top, 20)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 90)
                    // A pinned drawer covers the left of the window; the file sits beside it.
                    .padding(.leading, model.drawerPinned && model.drawerShown ? Drawer.width + Drawer.inset * 2 : 0)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            // In the toolbar's row, level with the traffic lights AppKit centres in it, and over an
            // open block or file, which ⌘K and ⌘P open over.
            Island()
                // Clear of the lights and the sidebar button on the left, and of the review's
                // button and its counts on the right; beside a pinned drawer, the column's margin
                // from it.
                .padding(.horizontal, Island.side)
                .padding(.leading, model.drawerPinned && model.drawerShown ? Drawer.width + Drawer.inset * 2 + Column.margin - Island.side : 0)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            // Full height and under the title bar, so the traffic lights sit inside its first row.
            Drawer()
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

    /// How much of the column's left end a drawer covers at this window width, with the margin a
    /// pinned one leaves.
    private static func clearing(width: CGFloat) -> CGFloat {
        let left = (width - min(Column.width, width - Column.margin * 2)) / 2
        return max(0, Drawer.width + Drawer.inset * 2 + Column.margin - left)
    }

    /// The first message's transcript rises in behind the composer once it has mostly gone past,
    /// instead of under it.
    private static let rise = AnyTransition.opacity.combined(with: .offset(y: 24)).animation(Motion.glide.delay(0.22))
    /// Another thread's transcript fades in once this one has gone, so two are never on the
    /// glass together.
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
        .help((model.drawerPinned ? "Hide threads" : "Show threads") + " (\(model.shortcuts.label(.toggleThreads)))")
        .accessibilityLabel(model.drawerPinned ? "Hide threads" : "Show threads")
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

/// One quiet line when the engine can't run, never an alert.
struct EngineNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let note = model.modeNote ?? model.note {
                Text(note)
            } else if model.engineState == .ready || model.engineState == .starting, model.agentDown == nil,
                      let away = model.runningOutOfView {
                RunningLine(block: away.block, more: away.more)
            } else {
                engineLine
            }
        }
        .font(Type.secondary)
        .foregroundStyle(Ink.secondary)
        .animation(Motion.fade, value: model.engineState)
        .animation(Motion.fade, value: model.agentDown)
        .animation(Motion.fade, value: model.note)
        .animation(Motion.fade, value: model.modeNote)
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

