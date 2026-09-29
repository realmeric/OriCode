import AppKit

/// A view that goes from under a stationary pointer never sends its mouseExited, so the cursor it
/// set stays: the I-beam of selectable text outlives the transcript that had it. This puts the
/// arrow back and moves the pointer a synthetic step where it is, so whatever is under it now,
/// text in the next thread or nothing, sets its own cursor.
@MainActor
enum PointerCursor {
    /// How long after a thread opens or closes the old views have gone: the longest of the
    /// window's transitions, with the composer's glide behind it.
    static let settle = Duration.milliseconds(700)

    static func refresh(in window: NSWindow? = nil) {
        guard let window = window ?? NSApp.mainWindow ?? NSApp.keyWindow, window.isVisible,
              window.frame.contains(NSEvent.mouseLocation)
        else { return }
        NSCursor.arrow.set()
        window.invalidateCursorRects(for: window.contentView ?? NSView())
        guard let step = NSEvent.mouseEvent(
            with: .mouseMoved, location: window.mouseLocationOutsideOfEventStream, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        else { return }
        window.postEvent(step, atStart: false)
    }
}
