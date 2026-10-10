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
        if let kept = keptDrafts[thread.id.uuidString] {
            made.draft.text = kept
            draftsWritten[thread.id] = made.draft.edits
        }
        composers[thread.id] = made
        return made
    }

    static let draftsKey = "threadDrafts"

    private var keptDrafts: [String: String] {
        draftsKept.dictionary(forKey: Self.draftsKey) as? [String: String] ?? [:]
    }

    /// Writes a started thread's draft where the next launch finds it, or takes it out once it's
    /// sent or emptied. Called when the keyboard leaves the thread, the app is left or quits, and
    /// never on a key; a draft not edited since it was last written costs one comparison of counts.
    /// A command at the prompt isn't a message, and isn't kept as one; nor is it marked written,
    /// since Esc makes it a message again without an edit.
    func keepDraft(of thread: UUID) {
        guard let state = composers[thread], state.draft.edits != draftsWritten[thread, default: 0],
              let chat = chat(withID: thread), chat.started, !chat.archived
        else { return }
        draftsWritten[thread] = state.shellPrompt ? nil : state.draft.edits
        var kept = keptDrafts
        if state.draft.blank || state.shellPrompt {
            guard kept.removeValue(forKey: thread.uuidString) != nil else { return }
        } else {
            kept[thread.uuidString] = state.draft.text
        }
        draftsKept.set(kept, forKey: Self.draftsKey)
    }

    func keepDrafts() {
        for thread in composers.keys { keepDraft(of: thread) }
    }

    /// A thread archived or deleted takes what its composer held, and what was kept of it.
    func forgetComposer(of thread: UUID) {
        composers[thread] = nil
        draftsWritten[thread] = nil
        var kept = keptDrafts
        guard kept.removeValue(forKey: thread.uuidString) != nil else { return }
        draftsKept.set(kept, forKey: Self.draftsKey)
    }

    /// At launch: a kept draft whose thread is gone or archived has no field to come back to.
    func pruneDrafts() {
        let kept = keptDrafts
        guard !kept.isEmpty else { return }
        let listed = Set(projects.flatMap(\.chats).filter { $0.started && !$0.archived }.map(\.id.uuidString))
        let rest = kept.filter { listed.contains($0.key) }
        if rest.count != kept.count { draftsKept.set(rest, forKey: Self.draftsKey) }
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

    /// The higher of the composers on the glass, which the review and a full block stop above.
    /// One that hasn't been laid out yet has no edge to stop above.
    var composerTop: CGFloat {
        let tops = [chat, besideShown].compactMap { $0 }.map { composer(for: $0).top }.filter { $0 > 0 }
        return tops.min() ?? composer(for: chat).top
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
