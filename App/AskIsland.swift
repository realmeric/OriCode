import AppKit
import SwiftUI

/// An ask from a thread that isn't on the glass, swelling out of the capsule on its own: who asks,
/// which opens that thread, and the ask answered in place. Two fingers pushing up draw it back
/// into the capsule, which keeps a mark while it still waits.
struct AskIsland: View {
    @Environment(AppModel.self) private var model
    /// How far two fingers have pushed the island up, which Island squeezes it by.
    @Binding var pull: CGFloat
    @State private var frame: CGRect = .zero
    @State private var swipe = Swipe()

    static let width: CGFloat = 460
    /// Past this the island folds when the fingers lift; short of it, it springs back.
    static let fold: CGFloat = 44

    var body: some View {
        let asks = model.unfoldedIslandAsks
        VStack(alignment: .leading, spacing: 6) {
            if let first = asks.first {
                AskEntry(waiting: first, lit: false)
                    .id(first.id)
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        .padding(8)
        // Over one, how many more wait behind it, with no noun.
        .overlay(alignment: .topTrailing) {
            if asks.count > 1 {
                Text("\(asks.count)")
                    .font(Type.secondary.monospacedDigit())
                    .foregroundStyle(Ink.faint)
                    .padding(20)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .onAppear { swipe.start { frame } moved: { pull = $0 } ended: { done($0) } }
        .onDisappear {
            swipe.stop()
            pull = 0
        }
    }

    private func done(_ distance: CGFloat) {
        if distance > Self.fold {
            withAnimation(Motion.blob) {
                model.foldIslandAsks()
                pull = 0
            }
        } else {
            withAnimation(Motion.move) { pull = 0 }
        }
    }
}

/// Two fingers on the trackpad over the island, read only while it's up: how far they've pushed it
/// up, and where that ended. Momentum after the fingers lift is left alone, and a mouse's wheel,
/// which has no fingers to lift, folds it at once once it has turned far enough.
@MainActor
private final class Swipe {
    private var monitor: Any?
    private var distance: CGFloat = 0
    private var tracking = false

    func start(over frame: @escaping () -> CGRect, moved: @escaping (CGFloat) -> Void, ended: @escaping (CGFloat) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Every scroll in the app passes here while the island is up, the transcript's
            // included: one that isn't the island's leaves at the first look.
            guard let self else { return event }
            let phase = event.phase
            if !self.tracking, !phase.contains(.began), !phase.isEmpty { return event }
            if !event.momentumPhase.isEmpty { return self.tracking ? nil : event }
            let wheel = phase.isEmpty
            if phase.contains(.began) || (wheel && !self.tracking) {
                guard let window = event.window, let content = window.contentView else { return event }
                let point = CGPoint(x: event.locationInWindow.x, y: content.frame.height - event.locationInWindow.y)
                guard frame().contains(point) else { return event }
                self.tracking = true
                self.distance = 0
            }
            guard self.tracking else { return event }
            // Fingers moving up, whichever way the Mac scrolls.
            let up = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            self.distance += up * (event.hasPreciseScrollingDeltas ? 1 : 8)
            if phase.contains(.ended) || phase.contains(.cancelled) {
                self.tracking = false
                ended(self.distance)
            } else if wheel {
                if self.distance > AskIsland.fold {
                    self.tracking = false
                    ended(self.distance)
                } else if self.distance < 0 {
                    self.tracking = false
                }
            } else {
                moved(self.distance)
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        tracking = false
    }
}

extension AppModel {
    /// The asks waiting on the user from threads that aren't on the glass, oldest first: an ask in
    /// the open thread or the one beside it is already in front of the user, as its own card.
    var islandAsks: [WaitingAsk] {
        waitingAsks.filter { !onGlass($0.holder.id) && !onGlass($0.thread.id) }
    }

    /// The ones the island swells out with: every ask off the glass that wasn't pushed back up.
    var unfoldedIslandAsks: [WaitingAsk] {
        islandAsks.filter { !foldedAsks.contains($0.id) }
    }

    /// Two fingers pushed the island up: what it showed stays in the capsule's mark until it's
    /// answered or opened, and only a new ask brings the island out again.
    func foldIslandAsks() {
        let live = Set(waitingAsks.map(\.id))
        foldedAsks = foldedAsks.intersection(live).union(islandAsks.map(\.id))
    }

    /// The capsule's mark: out again with every ask it held.
    func unfoldIslandAsks() {
        withAnimation(Motion.blob) { foldedAsks = [] }
    }
}
