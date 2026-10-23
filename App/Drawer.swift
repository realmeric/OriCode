import AppKit
import SwiftUI

/// The thread list: a drawer over the glass, never a sidebar.
struct Drawer: View {
    static let width: CGFloat = 280
    /// From the window's top, left and bottom edges; the corners are the window's less this.
    static let inset: CGFloat = 6
    static let corner: CGFloat = 12
    /// The first row, level with the toolbar's, so the traffic lights sit in its middle.
    static let titleRow: CGFloat = TitleBar.height - inset * 2

    @Environment(AppModel.self) private var model
    @State private var footHover: Foot?
    @State private var addHovered = false
    /// ⌘ held, which shows the first nine rows' shortcuts, and the watch on it.
    @State private var command = false
    @State private var commandWatch: Any?
    @Environment(\.openSettings) private var openSettings

    private enum Foot {
        case newThread, settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TitleBarGlass().frame(height: Self.titleRow)
            HStack(spacing: 8) {
                projectMenu
                Spacer(minLength: 0)
                filterMenu
                addProjectButton
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.top, 2)
            List {
                let chats = model.chats
                let pinned = chats.filter(\.pinned).count
                let under = workUnder()
                // What each row is told, read once here, so a row whose own values hold isn't
                // made again when another thread is picked, peeked or hovered (K-318).
                let open = model.chat?.id, beside = model.besideChatID, peeked = model.peekedChatID
                // The header names the project new threads start in, so its rows don't repeat it.
                let named = model.selectedProjectID
                ForEach(Array(chats.enumerated()), id: \.element.id) { index, chat in
                    DrawerRow(chat: chat, index: index, conversation: model.conversations[chat.id].flatMap { $0.working ? $0 : nil },
                              working: under.working.contains(chat.id), asks: under.asking.contains(chat.id),
                              selected: chat.id == open, beside: chat.id == beside, peeked: chat.id == peeked,
                              digit: command && index < 9, badged: chat.project?.id != named)
                        // Space, not a line, parts the pinned threads from the rest.
                        .padding(.bottom, index == pinned - 1 && pinned < chats.count ? 10 : 0)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove { model.moveThreads(from: $0, to: $1) }
                .moveDisabled(model.drawerFilter != .all)
                if chats.isEmpty, model.drawerFilter != .all {
                    Button("No threads here. Show all") { model.drawerFilter = .all }
                        .buttonStyle(.plain)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.faint)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 34)
            .background(KeyLoop())
            // The ⌘digits matter only while ⌘ is down, as Safari's tabs show theirs. A modifier
            // changing is all this hears, so it costs nothing while nobody types.
            .onAppear {
                commandWatch = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    let down = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                    MainActor.assumeIsolated {
                        if down != command { command = down }
                    }
                    return event
                }
            }
            .onDisappear {
                if let commandWatch { NSEvent.removeMonitor(commandWatch) }
                commandWatch = nil
            }
            // ⌘Tab lets ⌘ go in another app, which this never hears.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                command = false
            }
            HStack(spacing: 4) {
                Button {
                    model.openNewThread()
                } label: {
                    Label("New thread", systemImage: "square.and.pencil")
                        .font(Type.secondary)
                        .foregroundStyle(footHover == .newThread ? Ink.primary : Ink.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(footHover == .newThread ? Surface.hover : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(model.project == nil)
                .onHover { footHover = $0 ? .newThread : (footHover == .newThread ? nil : footHover) }
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(footHover == .settings ? Ink.primary : Ink.secondary)
                        .frame(width: 34, height: 34)
                        .background(footHover == .settings ? Surface.hover : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { footHover = $0 ? .settings : (footHover == .settings ? nil : footHover) }
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: Self.corner, style: .continuous))
        .background(Surface.drawer, in: .rect(cornerRadius: Self.corner, style: .continuous))
        .onHover { model.drawerHover($0) }
    }

    private var addProjectButton: some View {
        Button {
            model.addProject()
        } label: {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 13))
                .foregroundStyle(addHovered ? Ink.primary : Ink.secondary)
                .frame(width: 28, height: 24)
                .background(addHovered ? Surface.hover : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { addHovered = $0 }
        .help("Add project (\(model.shortcuts.label(.addProject)))")
        .accessibilityLabel("Add project")
    }

    /// Which threads the list shows: all, one project's, the ones at work or the ones waiting on you.
    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: Bindable(model).drawerFilter) {
                Text("All threads").tag(DrawerFilter.all)
                Divider()
                ForEach(model.projects) { project in
                    Text(project.name).tag(DrawerFilter.project(project.id))
                }
                Divider()
                Text("Working").tag(DrawerFilter.working)
                Text("Waiting on you").tag(DrawerFilter.waiting)
                Divider()
                Text("Archived").tag(DrawerFilter.archived)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: model.drawerFilter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(model.drawerFilter == .all ? Ink.secondary : Ink.primary)
                .frame(width: 28, height: 24)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.drawerFilter == .all ? "Filter threads" : "Showing \(model.drawerFilter.title(in: model.projects))")
        .accessibilityLabel("Filter threads")
    }

    private var projectMenu: some View {
        Menu {
            // Every row has its symbol, a folder for a project and No folder's laptop, so the names stay in one column.
            Group {
                ForEach(model.projects.filter { !$0.isNoFolder }) { project in
                    Toggle(isOn: Binding(get: { project.id == model.project?.id }, set: { _ in model.select(project) })) {
                        Label(project.name, systemImage: "folder")
                    }
                }
                // There before anything was sent in it, when it isn't a project yet: a draft there, as ⌘K's.
                Toggle(isOn: Binding(get: { model.project?.isNoFolder == true }, set: { _ in model.openThreadWithoutFolder() })) {
                    Label(Project.noFolderName, systemImage: "laptopcomputer")
                }
                Divider()
                Button { model.addProject() } label: { Label("Add project…", systemImage: "folder.badge.plus") }
            }
            .labelStyle(.titleAndIcon)
        } label: {
            HStack(spacing: 8) {
                if let project = model.project {
                    ProjectBadge(project: project)
                }
                Text(model.project.map { $0.isNoFolder ? Project.noFolderName : $0.name } ?? Project.noFolderName)
                    .font(Type.body.weight(.medium))
                    .foregroundStyle(Ink.primary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// The top threads with a thread at work in or under them, and those with an ask waiting in
    /// or under them, which the threads under have no row to show.
    private func workUnder() -> (working: Set<UUID>, asking: Set<UUID>) {
        let tops = model.topThreads
        let working = model.projects.flatMap(\.chats).filter { model.conversations[$0.id]?.working == true || $0.agentWorking }
        return (Set(working.compactMap { tops[$0.id] }), Set(model.asksByThread.keys.compactMap { tops[$0] }))
    }
}

/// One thread's row. Told what it needs by the drawer, and holding its own hover and rename, so
/// a change to one thread makes its row again and not every row in the list.
private struct DrawerRow: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    let index: Int
    /// Its own conversation, while it works.
    let conversation: Conversation?
    /// Whether the thread or one under it works, and whether an ask waits in it or under it, which pulses its mark.
    let working: Bool
    let asks: Bool
    let selected: Bool
    let beside: Bool
    let peeked: Bool
    /// Its ⌘digit, shown while ⌘ is held.
    let digit: Bool
    /// Its project's badge, which a row of the header's project leaves out.
    let badged: Bool
    @State private var hovered = false
    @State private var draft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        let missing = !FileManager.default.fileExists(atPath: chat.cwd)
        // What the row doesn't draw: a gone folder, what an agent returned or how it ended, and
        // what the thread has spent.
        let help = [missing ? "Folder missing" : nil, chat.agentLine, chat.costUSD > 0 ? String(format: "$%.2f so far", chat.costUSD) : nil]
        // A row of the list's own rather than a button, which would keep the mouse and leave the
        // list no drag to reorder with.
        HStack(spacing: 10) {
            if let project = chat.project {
                // Its place kept, so every title starts at the same x.
                ProjectBadge(project: project)
                    .opacity(badged ? 1 : 0)
            }
            if model.renamingChatID == chat.id {
                TextField("Title", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Type.body)
                    .foregroundStyle(Ink.primary)
                    .focused($renameFocused)
                    .onSubmit { model.finishRename(chat, to: draft) }
                    .onChange(of: renameFocused) { _, focused in if !focused { model.finishRename(chat, to: draft) } }
                    .onAppear {
                        draft = chat.title
                        renameFocused = true
                    }
            } else {
                HStack(spacing: 5) {
                    Text(chat.title)
                        .font(Type.body)
                        .foregroundStyle(missing ? Ink.faint : selected ? Ink.primary : Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if chat.worktreeBranch != nil {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundStyle(Ink.faint)
                            .help(chat.worktreeBranch ?? "")
                    }
                }
            }
            Spacer(minLength: 4)
            // Only while the thread or one under it works or waits, so an idle row gives its
            // title the room.
            if let conversation {
                // Still while the drawer is away: hidden, it stays in the tree, and a turning
                // mark would redraw for nobody.
                ThreadMark(conversation: conversation, moving: model.drawerShown, waiting: asks)
                    .frame(width: 14, height: 14)
            } else if working || asks {
                // Work under it, which has no rays here: the dot lit.
                RaysMark(waiting: asks && model.drawerShown, restingOpacity: 0.28)
                    .frame(width: 14, height: 14)
                    .accessibilityLabel("Working")
            }
            if chat.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .rotationEffect(.degrees(45))
                    .foregroundStyle(Ink.faint)
                    .help("Pinned")
            }
            if digit {
                Text("⌘\(index + 1)")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.faint)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            selected || peeked ? Surface.selected : beside || hovered ? Surface.hover : .clear,
            in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .offset(x: peeked ? 6 : 0)
        .animation(Motion.move, value: peeked)
        .onTapGesture { model.pickByClick(chat, beside: NSEvent.modifierFlags.contains(.option)) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.startRename(chat) })
        .accessibilityElement(children: model.renamingChatID == chat.id ? .contain : .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.select(chat) }
        .help(help.compactMap(\.self).joined(separator: "\n"))
        .onHover { hovered = $0 }
        .contextMenu {
            if chat.archived {
                Button("Restore") { withAnimation(Motion.move) { model.restore(chat) } }
            } else {
                if beside {
                    Button("Close Other Side") { model.closeOtherSide() }
                } else {
                    Button("Open Beside") { model.openBeside(chat) }
                        .disabled(selected)
                }
                Button(chat.pinned ? "Unpin" : "Pin") { withAnimation(Motion.move) { model.togglePin(chat) } }
                Button("Rename") { model.startRename(chat) }
                Button("Archive") { withAnimation(Motion.move) { model.archive(chat) } }
            }
            Button("Delete…") { model.askToDelete(chat) }
        }
    }
}

/// Reads whether the drawer is out in a body of its own: read in the drawer's, it made every row
/// again each time the drawer came or went (K-318).
private struct KeyLoop: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        KeyLoopGate(open: model.drawerShown)
    }
}

/// Keeps the thread list out of the window's key loop while the drawer is away. The list stays in
/// the window once it's made, so opening the drawer moves it and doesn't make it again, and left
/// alone, Tab from the composer would land in it, unseen.
private struct KeyLoopGate: NSViewRepresentable {
    let open: Bool

    func makeNSView(context: Context) -> Gate {
        Gate()
    }

    func updateNSView(_ gate: Gate, context: Context) {
        gate.open = open
        gate.apply()
    }

    final class Gate: NSView {
        var open = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        /// The drawer's table is the only one in the window, the width of the drawer; the list is
        /// made a moment after this view, so it's looked for on the next turn too.
        func apply() {
            look()
            DispatchQueue.main.async { [weak self] in self?.look() }
        }

        private func look() {
            guard let content = window?.contentView else { return }
            var queue = [content]
            while let view = queue.popLast() {
                if let table = view as? NSTableView, abs(table.bounds.width - Drawer.width) < 40 {
                    table.refusesFirstResponder = !open
                    return
                }
                queue += view.subviews
            }
        }
    }
}

/// Which threads the drawer lists.
enum DrawerFilter: Hashable {
    case all, working, waiting, archived
    case project(UUID)

    func title(in projects: [Project]) -> String {
        switch self {
        case .all: "all threads"
        case .working: "threads at work"
        case .waiting: "threads waiting on you"
        case .archived: "archived threads"
        case .project(let id): projects.first { $0.id == id }?.name ?? "one project"
        }
    }
}
