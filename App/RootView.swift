import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Glass.key) private var glass = Glass.defaultTint

    var body: some View {
        GeometryReader { window in
            ZStack {
                Color.black.opacity(glass)
                    .ignoresSafeArea()
                let conversation = model.chat.map(model.conversation(for:))
                VStack(spacing: 0) {
                    if let conversation, let chat = model.chat, !conversation.items.isEmpty {
                        TranscriptView(conversation: conversation, cwd: chat.cwd)
                    } else {
                        Spacer()
                        VStack(spacing: 18) {
                            EmptyStateView(line: model.project == nil ? "Add a project to start." : "Where do we pick up?")
                            ThreadsMenu()
                        }
                        Spacer()
                    }
                    if model.project != nil {
                        Composer(running: conversation?.running ?? false, maxHeight: window.size.height * 0.4)
                            .column()
                    }
                    EngineNote()
                        .frame(height: 16)
                }
            }
        }
        .ignoresSafeArea(edges: .top)
    }
}

/// Stand-in for the drawer until K-10: the project and its threads in one native menu.
struct ThreadsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.projects) { project in
                Button(project.name) { model.select(project) }
                    .disabled(project.id == model.project?.id)
            }
            Button("Add project…") { model.addProject() }
            if model.project != nil {
                Divider()
                ForEach(model.chats) { chat in
                    Button(chat.title) { model.select(chat) }
                        .disabled(chat.id == model.chat?.id)
                }
                Button("New thread") { model.newChat() }
                if let chat = model.chat {
                    Button("Delete \(chat.title)", role: .destructive) { model.delete(chat) }
                }
            }
        } label: {
            Text([model.project?.name, model.chat?.title].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Projects")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .font(Type.secondary)
        .foregroundStyle(Ink.secondary)
    }
}

extension View {
    /// The transcript's centred column: 760pt at most, 20pt from the edges below that.
    func column() -> some View {
        frame(maxWidth: 760)
            .padding(.horizontal, 20)
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

struct EmptyStateView: View {
    let line: String

    var body: some View {
        VStack(spacing: 14) {
            Mark()
            Text(line)
                .font(Type.body)
                .foregroundStyle(Ink.secondary)
        }
    }
}

/// Stand-in for the mark Meriç supplies: a plain ring.
struct Mark: View {
    var body: some View {
        Circle()
            .stroke(Ink.secondary, lineWidth: 2.5)
            .frame(width: 40, height: 40)
            .frame(width: 44, height: 44)
    }
}
