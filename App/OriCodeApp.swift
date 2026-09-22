import SwiftData
import SwiftUI

@main
struct OriCodeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private let container = Store.container()
    @State private var model: AppModel

    init() {
        // A write to an engine that just died must fail as an error, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        _model = State(initialValue: AppModel(container: container))
    }

    var body: some Scene {
        Window("OriCode", id: "main") {
            RootView()
                .environment(model)
                .modelContainer(container)
                .task {
                    delegate.openFolder = { [model] url in model.addProject(at: url) }
                    delegate.deliverEarlyFolders()
                    await model.boot()
                }
                .frame(minWidth: 720, minHeight: 480)
                .containerBackground(for: .window) { BehindWindowGlass() }
                .preferredColorScheme(.dark)
        }
        .commands { OriCodeCommands(model: model) }
        .windowStyle(.hiddenTitleBar)
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
