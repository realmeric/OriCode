import AppKit
import SwiftUI

/// The window's material. SwiftUI's `.ultraThinMaterial` goes flat grey whenever the
/// window isn't key; this one stays blurred, which is what makes the glass read as glass.
/// `.underWindowBackground` rather than `.hudWindow`, because window captures (AltTab,
/// Mission Control, screenshots) leave out what's behind the window, and `.hudWindow` comes
/// out of them a light grey.
struct BehindWindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
