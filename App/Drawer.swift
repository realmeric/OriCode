import SwiftUI

/// The thread list: a drawer over the glass, never a sidebar.
struct Drawer: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: UUID?
    @State private var draft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            projectMenu
                .padding(.horizontal, 12)
                .padding(.top, 10)
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
            Button {
                model.newChat()
            } label: {
                Label("New thread", systemImage: "square.and.pencil")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(model.project == nil)
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .frame(width: 260)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .background(Surface.drawer, in: .rect(cornerRadius: 14, style: .continuous))
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
