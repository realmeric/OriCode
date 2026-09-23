import AppKit

/// The trackpad's tap under a moving finger, for the few moments a choice lands. It's felt only
/// on a Force Touch trackpad with a finger on it, and a click is already felt, so it's for drags:
/// never clicks, keys, or anything the user didn't do.
@MainActor
enum Haptics {
    private static var last = Date.distantPast

    /// A detent: the effort thumb crossing a level, something held over the composer, a slider
    /// caught at its default. At most one every 45ms, so a fast drag doesn't buzz.
    static func detent() {
        guard Date.now.timeIntervalSince(last) > 0.045 else { return }
        last = .now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// The heavier one, for the two efforts that spend the plan faster: arriving at Max, or
    /// through the gate at Ultracode, on the way up.
    static func threshold() {
        last = .now
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
