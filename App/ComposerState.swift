import AppKit
import Observation

/// What a composer holds for one thread, so it stays with the thread when another is opened:
/// the text, the pictures, the shell prompt. One more is kept for the window with no thread open.
@MainActor
@Observable
final class ComposerState {
    let draft = Draft()
    var attachments: [ImageAttachment] = []
    /// Whether the composer is a shell prompt for the thread's folder, after a `!` at its start.
    var shellPrompt = false
    /// Tab's list of matches is up in the composer, and Esc puts it away first.
    var menu = false
    /// Bumped to put the cursor in the composer when nothing else would move it there: ⌘N on the
    /// draft that's already open.
    var focus = 0
    /// Where the composer's top edge is in the window, which the terminal stops above.
    var top: CGFloat = 0
    /// Where the model button is in the window, so a click on it is left to the button.
    @ObservationIgnored var modelButtonFrame = CGRect.zero
    /// The prompt the latest click on a suggested thread handed the composer, which the next
    /// click's takes the place of.
    @ObservationIgnored var suggestedPrompt: String?

    /// Nothing typed, no picture and no prompt: nothing to lose.
    var isEmpty: Bool { draft.empty && attachments.isEmpty && !shellPrompt }
}

extension AppModel {
    /// A thread's composer, made the first time it's asked for; with no thread, the window's.
    func composer(for thread: Chat?) -> ComposerState {
        guard let thread else { return looseComposer }
        if let made = composers[thread.id] { return made }
        let made = ComposerState()
        composers[thread.id] = made
        return made
    }

    /// The window has one composer, which shows the open thread's. Where it is on the glass and
    /// how often it was asked to take the keyboard are that one view's, so they go to the thread
    /// it shows next, and the list it had up stays behind.
    func composerShowsOpenThread() {
        let next = composer(for: chat)
        guard let last = shownComposer, last !== next else {
            shownComposer = next
            return
        }
        next.top = last.top
        next.modelButtonFrame = last.modelButtonFrame
        next.focus = last.focus
        last.menu = false
        shownComposer = next
    }

    // The open thread's composer under the names it had as one composer on the model, for the
    // menus, Esc, ⌘K and the paste monitor, which act on the thread the keyboard is in.

    var composerFocus: Int {
        get { composer(for: chat).focus }
        set { composer(for: chat).focus = newValue }
    }

    var shellPrompt: Bool {
        get { composer(for: chat).shellPrompt }
        set { composer(for: chat).shellPrompt = newValue }
    }

    var composerMenu: Bool {
        get { composer(for: chat).menu }
        set { composer(for: chat).menu = newValue }
    }

    var composerTop: CGFloat {
        composer(for: chat).top
    }

    var modelButtonFrame: CGRect {
        get { composer(for: chat).modelButtonFrame }
        set { composer(for: chat).modelButtonFrame = newValue }
    }

    var draftAttachments: [ImageAttachment] {
        get { composer(for: chat).attachments }
        set { composer(for: chat).attachments = newValue }
    }

    var suggestedPrompt: String? {
        get { composer(for: chat).suggestedPrompt }
        set { composer(for: chat).suggestedPrompt = newValue }
    }
}
