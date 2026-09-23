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
                addProjectButton
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.top, 2)
            List {
                let chats = model.chats
                let pinned = chats.filter(\.pinned).count
                ForEach(Array(chats.enumerated()), id: \.element.id) { index, chat in
                    row(chat, index: index)
                        // Space, not a line, parts the pinned threads from the rest.
                        .padding(.bottom, index == pinned - 1 && pinned < chats.count ? 10 : 0)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove { model.moveThreads(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 34)
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
        .help("Add project (⌘O)")
        .accessibilityLabel("Add project")
    }

    private var projectMenu: some View {
        Menu {
            ForEach(model.projects) { project in
                Toggle(project.name, isOn: Binding(get: { project.id == model.project?.id }, set: { _ in model.select(project) }))
            }
            if !model.projects.isEmpty { Divider() }
            Button("Add project…") { model.addProject() }
        } label: {
            HStack(spacing: 8) {
                if let project = model.project {
                    ProjectBadge(project: project)
                }
                Text(model.project?.name ?? "No project")
                    .font(Type.body.weight(.medium))
                    .foregroundStyle(Ink.primary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func row(_ chat: Chat, index: Int) -> some View {
        let selected = chat.id == model.chat?.id
        let peeked = chat.id == model.peekedChatID
        // A row of the list's own rather than a button, which would keep the mouse and leave the
        // list no drag to reorder with.
        return HStack(spacing: 10) {
            if let project = chat.project {
                ProjectBadge(project: project)
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
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if chat.worktreeBranch != nil {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10))
                                .foregroundStyle(Ink.faint)
                                .help(chat.worktreeBranch ?? "")
                        }
                    }
                    if missing {
                        Text("folder missing")
                            .font(.system(size: 11))
                            .foregroundStyle(Ink.faint)
                    }
                }
            }
            Spacer(minLength: 4)
            // Only while the thread works or waits, so an idle row gives its title the room.
            let heads = model.heads(of: chat)
            let waiting = model.state(of: chat) == .waiting
            if heads > 0 || waiting {
                // Still while the drawer is away: hidden, it stays in the tree, and a turning
                // mark would redraw thirty times a second for nobody.
                RaysMark(lit: heads, turning: heads > 0 && model.drawerShown, waiting: waiting && model.drawerShown, restingOpacity: 0.28)
                    .frame(width: 14, height: 14)
            }
            if chat.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .rotationEffect(.degrees(45))
                    .foregroundStyle(Ink.faint)
                    .help("Pinned")
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.faint)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            selected || peeked ? Surface.selected : hovered == chat.id ? Surface.hover : .clear,
            in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .offset(x: peeked ? 6 : 0)
        .animation(Motion.move, value: peeked)
        .onTapGesture { model.select(chat) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.startRename(chat) })
        .accessibilityElement(children: model.renamingChatID == chat.id ? .contain : .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.select(chat) }
        .help(chat.costUSD > 0 ? String(format: "$%.2f so far", chat.costUSD) : "")
        .onHover { inside in hovered = inside ? chat.id : (hovered == chat.id ? nil : hovered) }
        .contextMenu {
            Button(chat.pinned ? "Unpin" : "Pin") { withAnimation(Motion.move) { model.togglePin(chat) } }
            Button("Rename") { model.startRename(chat) }
            Button("Delete…") { model.askToDelete(chat) }
        }
    }
}
