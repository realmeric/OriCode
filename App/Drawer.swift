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
    @FocusState private var renameFocused: Bool
    @Environment(\.openSettings) private var openSettings

    private enum Foot {
        case newThread, settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.frame(height: Self.titleRow)
            projectMenu
                .padding(.horizontal, 12)
                .padding(.top, 2)
            List {
                ForEach(Array(model.chats.enumerated()), id: \.element.id) { index, chat in
                    row(chat, index: index)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 34)
            HStack(spacing: 4) {
                Button {
                    model.newChat()
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

    private var projectMenu: some View {
        Menu {
            ForEach(model.projects) { project in
                Toggle(project.name, isOn: Binding(get: { project.id == model.project?.id }, set: { _ in model.select(project) }))
            }
            if !model.projects.isEmpty { Divider() }
            Button("Add project…") { model.addProject() }
        } label: {
            Text(model.project?.name ?? "No project")
                .font(Type.body.weight(.medium))
                .foregroundStyle(Ink.primary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func row(_ chat: Chat, index: Int) -> some View {
        let selected = chat.id == model.chat?.id
        let peeked = chat.id == model.peekedChatID
        return Button {
            model.select(chat)
        } label: {
            HStack(spacing: 10) {
                let heads = model.heads(of: chat)
                RaysMark(lit: heads, turning: heads > 0, waiting: model.state(of: chat) == .waiting,
                         restingOpacity: 0.28, dotOpacity: selected || heads > 0 ? 0.92 : 0.55)
                    .frame(width: 14, height: 14)
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
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.startRename(chat) })
        .help(chat.costUSD > 0 ? String(format: "$%.2f so far", chat.costUSD) : "")
        .onHover { inside in hovered = inside ? chat.id : (hovered == chat.id ? nil : hovered) }
        .contextMenu {
            Button("Rename") { model.startRename(chat) }
            Button("Delete…") { model.askToDelete(chat) }
        }
    }
}
