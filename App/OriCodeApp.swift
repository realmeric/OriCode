import SwiftUI

@main
struct OriCodeApp: App {
    var body: some Scene {
        Window("OriCode", id: "main") {
            RootView()
                .frame(minWidth: 720, minHeight: 480)
                .containerBackground(for: .window) { BehindWindowGlass() }
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultWindowPlacement { _, context in
            let visible = context.defaultDisplay.visibleRect.size
            let size = CGSize(width: min(1180, visible.width - 80), height: min(760, visible.height - 80))
            return WindowPlacement(.center, size: size)
        }
    }
}
