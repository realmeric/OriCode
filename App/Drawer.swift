import SwiftUI

/// The thread list: a drawer over the glass, never a sidebar.
struct Drawer: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: UUID?
    @State private var deleting: Chat?
    @State private var renaming: UUID?
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
        .confirmationDialog(
            "Delete “\(deleting?.title ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { chat in
            Button("Delete", role: .destructive) { model.delete(chat) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its transcript goes with it.")
        }
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
                StateRing(state: model.state(of: chat))
                if renaming == chat.id {
                    TextField("Title", text: $draft)
                        .textFieldStyle(.plain)
                        .font(Type.body)
                        .foregroundStyle(Ink.primary)
                        .focused($renameFocused)
                        .onSubmit { finishRename(chat) }
                        .onChange(of: renameFocused) { _, focused in if !focused { finishRename(chat) } }
                } else {
                    let missing = !FileManager.default.fileExists(atPath: chat.cwd)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chat.title)
                            .font(Type.body)
                            .foregroundStyle(missing ? Ink.faint : selected ? Ink.primary : Ink.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
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
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(chat) })
        .help(chat.costUSD > 0 ? String(format: "$%.2f so far", chat.costUSD) : "")
        .onHover { inside in hovered = inside ? chat.id : (hovered == chat.id ? nil : hovered) }
        .contextMenu {
            Button("Rename") { startRename(chat) }
            Button("Delete…") { deleting = chat }
        }
    }

    private func startRename(_ chat: Chat) {
        draft = chat.title
        renaming = chat.id
        renameFocused = true
    }

    private func finishRename(_ chat: Chat) {
        guard renaming == chat.id else { return }
        renaming = nil
        if draft != chat.title { model.rename(chat, to: draft) }
    }
}

/// Idle is a faint ring, running spins, waiting on you is solid.
struct StateRing: View {
    let state: AppModel.ThreadState

    var body: some View {
        ZStack {
            switch state {
            case .idle:
                Circle().stroke(Ink.faint, lineWidth: 1.5)
            case .running:
                SpinningRing()
            case .waiting:
                Circle().fill(Ink.primary)
            }
        }
        .frame(width: 10, height: 10)
    }
}

private struct SpinningRing: View {
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Ink.primary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}
