import AppKit
import SwiftUI

/// The model button's picker, on the window's own glass the way the slash menu is, not in a
/// system popover with a material and an arrow of its own: raised glass like the composer it
/// rises out of, from the composer's right end. A click anywhere else, Esc or Return puts it away.
struct PickerCard: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    /// The height the window has for the card on its side of the composer.
    var room: CGFloat = .infinity
    /// Hung below the composer, where it drops from its top rather than rising from its foot.
    var below = false
    @State private var watch = ClickWatch()
    /// False for the card's first turn, while it's built with nothing on screen moving.
    @State private var risen = false

    static let radius: CGFloat = 20
    /// How far down the edge's light reaches before it has faded: a third of the effort page.
    private static let edge = MarkPicker.effortHeight * 0.35

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        MarkPicker(chat: chat, room: room)
            // A page is laid out at its own height at once while the card glides to it, so what
            // hangs past the card's edge meanwhile is cut there.
            .clipShape(shape)
            .background(Surface.composer, in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(alignment: .top) {
                // The composer's raised-glass edge along the top, fading before the sides. Drawn
                // at the effort page's height whatever the page, so a page turn only moves it: drawn
                // on the card's whole height, it was drawn again on every frame of the card's glide.
                UnevenRoundedRectangle(topLeadingRadius: Self.radius, topTrailingRadius: Self.radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Surface.composerEdge, .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .frame(maxHeight: Self.edge)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
            .scaleEffect(risen ? 1 : 0.92, anchor: below ? .topTrailing : .bottomTrailing)
            .offset(y: risen ? 0 : below ? -8 : 8)
            .opacity(risen ? 1 : 0)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { watch.card = $0 }
            .onAppear {
                watch.start(model)
                // Built in this turn and risen from the next, so the glide's first frame isn't the
                // one that builds the card and hands it the keyboard.
                DispatchQueue.main.async {
                    withAnimation(Motion.glide) { risen = true }
                }
            }
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
