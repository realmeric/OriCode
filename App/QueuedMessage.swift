import Foundation

/// A message written while its thread worked. It waits in the thread's queue and goes out as the
/// next message once the turn before it ends by itself; one that won't go out after all, queued
/// or sent into the turn, comes back to the field as one of these too.
struct QueuedMessage: Identifiable, Hashable {
    var id = UUID()
    let text: String
    var images: [ImageAttachment] = []
    /// When it was written, which puts it among others handed back.
    var written = Date.now

    /// What the composer's line says: the first line, or the images when there's no text.
    var line: String {
        let first = ToolSummary.firstLine(text)
        guard first.isEmpty else { return first }
        return images.count == 1 ? "An image" : "\(images.count) images"
    }

    /// Whether a turn ended by itself, so the queue may send its next message. One that was
    /// stopped, cut off by the engine going, or failed, which an error subtype or an error event
    /// before turn.done says, sends nothing more.
    static func endedByItself(_ stopReason: String?, failed: Bool) -> Bool {
        guard !failed, let stopReason else { return !failed }
        return stopReason != "interrupted" && stopReason != "engine_stopped" && !stopReason.hasPrefix("error")
    }

    /// Texts put together in the field, parted by a blank line, leaving out the empty ones.
    static func joined(_ texts: [String]) -> String {
        texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
