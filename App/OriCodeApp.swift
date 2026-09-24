import SwiftData
import SwiftUI

@main
struct OriCodeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private let container = Store.container()
    @State private var model: AppModel
    @State private var updates = Updates()

    init() {
        // A write to an engine that just died must fail as an error, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        _model = State(initialValue: AppModel(container: container))
    }

    var body: some Scene {
        Window(Build.name, id: "main") {
            RootView()
                .environment(model)
                .environment(updates)
                .modelContainer(container)
                .task {
                    delegate.openFolder = { [model] url in
                        if !url.hasDirectoryPath, model.attach(fileAt: url) { return }
                        model.addProject(at: url)
                    }
                    delegate.deliverEarlyFolders()
                    delegate.runningInTerminal = { [model] in model.terminals.running }
                    delegate.endTerminals = { [model] in model.terminals.endAll() }
                    delegate.markCutOffTurns = { [model] in model.markCutOffTurns() }
                    updates.say = { [model] line in model.say(line) }
                    await model.boot()
                }
                .frame(minWidth: 720, minHeight: 480)
                .containerBackground(for: .window) { BehindWindowGlass() }
                .preferredColorScheme(.dark)
        }
        .commands { OriCodeCommands(model: model, updates: updates) }
        // A toolbar row, so the traffic lights sit where a toolbar window's do: in from the
        // corner, inside the drawer's first row, level with the sidebar button and the capsule.
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowBackgroundDragBehavior(.enabled)
        .defaultWindowPlacement { _, context in
            let visible = context.defaultDisplay.visibleRect.size
            let size = CGSize(width: min(1180, visible.width - 80), height: min(760, visible.height - 80))
            return WindowPlacement(.center, size: size)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
