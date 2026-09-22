import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Glass.key) private var glass = Glass.defaultTint

    var body: some View {
        ZStack {
            Color.black.opacity(glass)
                .ignoresSafeArea()
            EmptyStateView(line: "Add a project to start.")
        }
        .overlay(alignment: .bottom) {
            EngineNote()
                .padding(.bottom, 24)
        }
    }
}

/// One quiet line when the engine can't run, never an alert.
struct EngineNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
        .font(Type.secondary)
        .foregroundStyle(Ink.secondary)
        .animation(Motion.fade, value: model.engineState)
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
