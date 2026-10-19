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
    @State private var hovered: UUID?
    @State private var draft = ""
    @State private var footHover: Foot?
    @State private var addHovered = false
    @FocusState private var renameFocused: Bool
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
                let tree = model.drawerTree
                let end = pinnedEnd(tree)
                let asks = model.asksByThread
                ForEach(Array(tree.enumerated()), id: \.element.id) { index, node in
                    branch(node, index: index, end: end, asks: asks)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove { model.moveThreads(from: $0, to: $1) }
                .moveDisabled(model.drawerFilter != .all)
                if tree.isEmpty, model.drawerFilter != .all {
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
            .background(KeyLoopGate(open: model.drawerShown))
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

    /// A thread and, when it opened any, the threads under it in the list's own fold. Only the
    /// top rows drag: a thread under another stays where it was opened.
    private func branch(_ node: DrawerNode, index: Int?, end: UUID?, asks: [UUID: Int]) -> AnyView {
        guard let children = node.children else {
            return AnyView(row(node.chat, index: index, end: end, asking: asks[node.chat.id] ?? 0, asks: asks[node.chat.id] != nil))
        }
        let id = node.chat.id
        let unfolded = Binding(
            get: { model.unfolded.contains(id) },
            set: { open in
                if open { model.unfolded.insert(id) } else { model.unfolded.remove(id) }
            })
        return AnyView(DisclosureGroup(isExpanded: unfolded) {
            ForEach(children) { child in
                branch(child, index: nil, end: end, asks: asks)
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .moveDisabled(true)
            }
        } label: {
            row(node.chat, index: index, end: end, working: working(under: children), asking: asking(at: node, asks), asks: asks[node.chat.id] != nil)
        })
    }

    /// The row the pinned threads end on, which space, not a line, parts from the rest: the last
    /// pinned thread's, or the last row unfolded under it.
    private func pinnedEnd(_ tree: [DrawerNode]) -> UUID? {
        let pinned = tree.prefix { $0.chat.pinned }
        guard var node = pinned.last, pinned.count < tree.count else { return nil }
        while model.unfolded.contains(node.id), let last = node.children?.last { node = last }
        return node.id
    }

    /// How many threads under it, at any depth, work or wait.
    private func working(under children: [DrawerNode]) -> Int {
        children.reduce(0) { count, node in
            count + (model.conversations[node.chat.id]?.working == true || node.chat.agentWorking ? 1 : 0) + working(under: node.children ?? [])
        }
    }

    /// How many asks wait at a thread and under it, at any depth.
    private func asking(at node: DrawerNode, _ asks: [UUID: Int]) -> Int {
        (node.children ?? []).reduce(asks[node.chat.id] ?? 0) { $0 + asking(at: $1, asks) }
    }

    /// A top row has its place in the list and its ⌘digit; one under another has neither.
    /// `asking` counts the asks at the row and under it; `asks` is whether the thread itself asks,
    /// which pulses its mark.
    private func row(_ chat: Chat, index: Int?, end: UUID?, working under: Int = 0, asking: Int = 0, asks: Bool = false) -> some View {
        let child = index == nil
        let selected = chat.id == model.chat?.id
        let beside = chat.id == model.besideChatID
        let peeked = chat.id == model.peekedChatID
        // A row of the list's own rather than a button, which would keep the mouse and leave the
        // list no drag to reorder with.
        return HStack(spacing: 10) {
            if let project = chat.project {
                ProjectBadge(project: project)
                    .opacity(child ? 0.7 : 1)
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
                let missing = !FileManager.default.fileExists(atPath: chat.cwd)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(chat.title)
                            .font(Type.body)
                            .foregroundStyle(missing ? Ink.faint : selected ? Ink.primary : Ink.secondary)
                            // A shade quieter under the thread that opened it, selected or not.
                            .opacity(child ? 0.8 : 1)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if chat.worktreeBranch != nil {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10))
                                .foregroundStyle(Ink.faint)
                                .help(chat.worktreeBranch ?? "")
                        }
                    }
                    // Under the title, which keeps its width: a row with threads under it at
                    // work would otherwise leave it a word.
                    // A workflow's agent says what it returned, or how it ended.
                    // What waits on you first, since it holds the rest up.
                    let below = [missing ? "folder missing" : nil, asking > 0 ? (asking == 1 ? "1 ask waiting" : "\(asking) asks waiting") : nil,
                                 under > 0 ? "\(under) working" : nil, chat.agentLine].compactMap(\.self)
                    if !below.isEmpty {
                        Text(below.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(missing ? Ink.faint : Ink.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            // Only while the thread works or waits, so an idle row gives its title the room.
            if let conversation = model.conversations[chat.id], conversation.working {
                // Still while the drawer is away: hidden, it stays in the tree, and a turning
                // mark would redraw for nobody.
                ThreadMark(conversation: conversation, moving: model.drawerShown, waiting: asks)
                    .frame(width: 14, height: 14)
            } else if chat.agentWorking {
                // An agent of a workflow is a main loop of its own, with no rays.
                RaysMark(waiting: asks && model.drawerShown, restingOpacity: 0.28, dotColor: MarkPalette.color(for: chat.providerID))
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
            if let index, index < 9 {
                Text("⌘\(index + 1)")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.faint)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            selected || peeked ? (child ? Surface.quietSelected : Surface.selected)
                : beside || hovered == chat.id ? (child ? Surface.quietHover : Surface.hover) : .clear,
            in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .offset(x: peeked ? 6 : 0)
        .animation(Motion.move, value: peeked)
        .padding(.bottom, chat.id == end ? 10 : 0)
        .onTapGesture { model.pickByClick(chat, beside: NSEvent.modifierFlags.contains(.option)) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.startRename(chat) })
        .accessibilityElement(children: model.renamingChatID == chat.id ? .contain : .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.select(chat) }
        .help(chat.costUSD > 0 ? String(format: "$%.2f so far", chat.costUSD) : "")
        .onHover { inside in hovered = inside ? chat.id : (hovered == chat.id ? nil : hovered) }
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
                if !child {
                    Button(chat.pinned ? "Unpin" : "Pin") { withAnimation(Motion.move) { model.togglePin(chat) } }
                }
                Button("Rename") { model.startRename(chat) }
                Button("Archive") { withAnimation(Motion.move) { model.archive(chat) } }
            }
            Button("Delete…") { model.askToDelete(chat) }
        }
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
