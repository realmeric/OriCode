import AppKit
import SwiftUI

/// Empty glass in the toolbar's row, doing what a title bar does. The toolbar draws nothing and
/// the content runs under it, so the clicks land here rather than on AppKit's title bar: a press
/// drags the window, and a double-click does what System Settings asks of a title bar.
struct TitleBarGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { GlassView() }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class GlassView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else {
                window.performDrag(with: event)
                return
            }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        }
    }
}
