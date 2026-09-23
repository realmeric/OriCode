import AppKit
import SwiftUI

/// The window's material: Liquid Glass, so with nothing set OriCode looks like the rest of the
/// Mac and follows System Settings › Appearance › Liquid Glass. It stays live while the window
/// isn't key, and window captures (AltTab, Mission Control, screenshots) show it dark.
/// Settings' Transparency fades it, so more of the desktop shows through unblurred.
struct BehindWindowGlass: NSViewRepresentable {
    @AppStorage(Glass.transparencyKey) private var transparency = Glass.defaultTransparency

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = 0
        view.alphaValue = Glass.materialOpacity(transparency)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.alphaValue = Glass.materialOpacity(transparency)
    }
}
