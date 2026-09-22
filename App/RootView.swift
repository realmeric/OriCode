import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Glass.key) private var glass = Glass.defaultTint

    var body: some View {
        GeometryReader { window in
            ZStack {
                Color.black.opacity(glass)
                    .ignoresSafeArea()
                let conversation = model.currentConversation
                VStack(spacing: 0) {
                    if let conversation, let chat = model.chat, !conversation.items.isEmpty {
                        TranscriptView(conversation: conversation, cwd: chat.cwd)
                            .id(chat.id)
                    } else {
                        Spacer()
                        EmptyStateView(line: model.project == nil ? "Add a project to start." : "Where do we pick up?")
                        Spacer()
                    }
                    if model.project != nil {
                        Composer(running: conversation?.running ?? false, maxHeight: window.size.height * 0.4)
                            .column()
                    }
                    EngineNote()
                        .frame(height: 16)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    if !model.drawerPinned { model.hideDrawer() }
                })
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(model.chat?.title ?? model.project?.name ?? "OriCode")
        .confirmationDialog(
            "Delete “\(model.deletingChat?.title ?? "")”?",
            isPresented: Binding(get: { model.deletingChat != nil }, set: { if !$0 { model.deletingChat = nil } }),
            presenting: model.deletingChat
        ) { chat in
            Button("Delete", role: .destructive) { model.delete(chat) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its transcript goes with it.")
        }
        .sheet(isPresented: Binding(get: { model.showingShortcuts }, set: { model.showingShortcuts = $0 })) {
            ShortcutsSheet()
        }
        .overlay(alignment: .top) {
            // Traffic lights are centred 16pt from the top; so is this.
            TitleCapsule()
                .padding(.top, 4)
                .padding(.horizontal, 90)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            Drawer()
                .padding(.leading, 12)
                .padding(.top, 40)
                .padding(.bottom, 12)
                .offset(x: model.drawerShown ? 0 : -300)
                .opacity(model.drawerShown ? 1 : 0)
                .allowsHitTesting(model.drawerShown)
        }
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: 8)
                .contentShape(.rect)
                .onHover { model.hotZone($0) }
        }
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
