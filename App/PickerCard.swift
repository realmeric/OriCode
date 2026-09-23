import AppKit
import SwiftUI

/// The model button's picker, on the window's own glass the way the slash menu is, not in a
/// system popover with a material and an arrow of its own: raised glass like the composer it
/// rises out of, from the composer's right end. A click anywhere else, Esc or Return puts it away.
struct PickerCard: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    @State private var watch = ClickWatch()

    static let radius: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        MarkPicker(chat: chat)
            .background(Surface.composer, in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay {
                // The composer's raised-glass edge along the top, fading before the sides.
                shape
                    .strokeBorder(LinearGradient(colors: [Surface.composerEdge, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)),
                                  lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { watch.card = $0 }
            .onAppear { watch.start(model) }
            .onDisappear { watch.stop() }
    }
}

/// Puts the picker away when a click lands outside it. The click still goes where it was aimed,
/// and one on the model button is left to the button, which toggles the picker itself.
@MainActor
final class ClickWatch {
    var card = CGRect.zero
    private var monitor: Any?

    func start(_ model: AppModel) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak model] event in
            MainActor.assumeIsolated {
                guard let self, let model, let view = event.window?.contentView else { return }
                let local = view.convert(event.locationInWindow, from: nil)
                let point = view.isFlipped ? local : CGPoint(x: local.x, y: view.bounds.height - local.y)
                if event.window?.identifier?.rawValue.hasPrefix("main") == true,
                   !self.card.contains(point), !model.modelButtonFrame.contains(point) {
                    model.modelPickerShown = false
                }
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
