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
                let started = conversation.map { !$0.items.isEmpty } ?? false
                // An unpinned drawer passes over the conversation for a moment, and the composer's
                // left end draws back out from under it while it's out. The right end, with the
                // picker and Send, doesn't move.
                let clear = model.drawerShown && !model.drawerPinned ? Self.clearing(width: window.size.width) : 0
                VStack(spacing: 0) {
                    if let conversation, let chat = model.chat, started {
                        TranscriptView(conversation: conversation, cwd: chat.cwd)
                            .id(chat.id)
                            .transition(.asymmetric(insertion: hadTranscript ? Self.swap : Self.rise, removal: Self.leave))
                    } else {
                        Spacer(minLength: 0)
                        EmptyStateView(
                            line: model.project == nil ? "Add a project to start." : "Where do we pick up?",
                            heads: conversation?.heads ?? 0,
                            waiting: conversation?.waitingAsk != nil)
                            .padding(.bottom, 28)
                            .transition(.asymmetric(insertion: Self.settle, removal: Self.lift))
                    }
                    // One composer in one place in the tree, whichever layout is showing, so the
                    // first message moves it rather than swapping it for another.
                    if model.project != nil {
                        Composer(running: conversation?.running ?? false, maxHeight: window.size.height * 0.4)
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
                    if model.fileFinderShown { model.toggleFileFinder() }
                    if model.openFile != nil { model.closeFile() }
                    if model.reviewShown { model.closeReview() }
                    if model.openBlock != nil { model.closeBlock() }
                })
            }
        }
        .ignoresSafeArea(edges: .top)
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
            if let branch = chat.worktreeBranch, let loss = model.deletingLoss {
                let stopping = model.shellsStopping(in: [chat])
                Text([loss.isEmpty ? "Everything on \(branch) is on another branch or remote, so its worktree can go too." : loss.sentence, stopping]
                    .compactMap { $0 }.joined(separator: " "))
            } else {
                Text("Its transcript goes with it.")
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
                    BlockPanel(block: block)
                        .frame(maxWidth: 900)
                        .frame(height: max(60, model.composerTop - area.frame(in: .global).minY - 24))
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 40)
                .padding(.leading, model.drawerPinned && model.drawerShown ? Drawer.width + Drawer.inset * 2 : 0)
                .transition(.scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            // In the toolbar's row, level with the traffic lights AppKit centres in it, and over an
            // open block, which ⌘K and ⌘P open over.
            Island()
                // Clear of the lights and the sidebar button on the left, and of the review's
                // button and its counts on the right; beside a pinned drawer, the column's margin
                // from it.
                .padding(.horizontal, Island.side)
                .padding(.leading, model.drawerPinned && model.drawerShown ? Drawer.width + Drawer.inset * 2 + Column.margin - Island.side : 0)
                .ignoresSafeArea()
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
        .overlay(alignment: .topLeading) {
            // Full height and under the title bar, so the traffic lights sit inside its first row.
            Drawer()
                .padding(Drawer.inset)
                .offset(x: model.drawerShown ? 0 : -(Drawer.width + Drawer.inset * 3))
                .opacity(model.drawerShown ? 1 : 0)
                .allowsHitTesting(model.drawerShown)
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
        .help(model.drawerPinned ? "Hide threads (⌘B)" : "Show threads (⌘B)")
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
            } else if model.engineState == .ready || model.engineState == .starting, let away = model.runningOutOfView {
                RunningLine(block: away.block, more: away.more)
            } else {
                engineLine
            }
        }
        .font(Type.secondary)
        .foregroundStyle(Ink.secondary)
        .animation(Motion.fade, value: model.engineState)
        .animation(Motion.fade, value: model.note)
        .animation(Motion.fade, value: model.modeNote)
    }

    @ViewBuilder
    private var engineLine: some View {
        Group {
            switch model.engineState {
            case .starting, .ready:
                EmptyView()
            case .noNode(let message):
                Text(LocalizedStringKey(message))
            case .noClaude:
                Text("Install Claude Code, then run `claude` in Terminal and log in.")
            case .notLoggedIn:
                HStack(spacing: 6) {
                    Text("Run `claude` in Terminal and log in.")
                    retry
                }
            case .stopped:
                HStack(spacing: 6) {
                    Text("Engine stopped.")
                    retry
                }
            }
        }
    }

    private var retry: some View {
        Button("Retry") {
            Task { await model.startEngine() }
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
    var heads = 0
    var waiting = false

    var body: some View {
        VStack(spacing: 14) {
            RaysMark(lit: heads, turning: heads > 0, waiting: waiting)
                .frame(width: 44, height: 44)
            Text(line)
                .font(Type.body)
                .foregroundStyle(Ink.secondary)
        }
    }
}

