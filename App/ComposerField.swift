import AppKit
import SwiftUI

/// What's typed in the composer, in an object of its own: the composer's body never reads it, so a
/// key redraws only the few views that do. The field writes it as keys land; whatever else sets it,
/// a send, ↑, Tab or a message handed back, is written into the field.
@MainActor
@Observable
final class Draft {
    /// Observed by hand: Observation's own setter compares the old text with the new, and for a
    /// long draft that comparison was most of what a key cost. Every set is a change.
    var text: String {
        get {
            access(keyPath: \.text)
            return stored
        }
        set {
            withMutation(keyPath: \.text) { stored = newValue }
            edits &+= 1
            // What the composer's views read instead of the text, each changing only now and then,
            // so a key redraws none of them.
            let blank = newValue.allSatisfy(\.isWhitespace)
            if blank != self.blank { self.blank = blank }
            if newValue.isEmpty != empty { empty = newValue.isEmpty }
            let bang = newValue.hasPrefix("!")
            if bang != self.bang { self.bang = bang }
            let slash = newValue.hasPrefix("/") && !newValue.contains(where: \.isWhitespace) ? String(newValue.dropFirst()) : nil
            if slash != self.slash { self.slash = slash }
            let at = Draft.mention(in: newValue)
            if at != self.at { self.at = at }
            if !typing { field?.show(newValue) }
        }
    }
    @ObservationIgnored private var stored = ""
    /// Counts the changes to the text, for what has to see each one.
    private(set) var edits = 0
    /// Nothing but spaces and newlines, which the send button reads.
    private(set) var blank = true
    /// Nothing at all, which is when the placeholder shows.
    private(set) var empty = true
    /// Starts with a `!`, which turns the composer into the shell prompt.
    private(set) var bang = false
    /// The word after a leading "/", while it's still being typed.
    private(set) var slash: String?
    /// What follows an `@` that starts the last word, while it's still being typed: a file's name.
    private(set) var at: String?

    /// Read from the end, so a long draft costs a key no more than its last word.
    nonisolated static func mention(in text: String) -> String? {
        let start = text.lastIndex(where: \.isWhitespace).map(text.index(after:)) ?? text.startIndex
        guard start < text.endIndex, text[start] == "@" else { return nil }
        let word = text[text.index(after: start)...]
        // A quoted mention is a path with spaces in it, which Tab completes.
        return word.hasPrefix("\"") ? nil : String(word)
    }
    /// The field's height: its text's, up to the lines the composer may grow to.
    var height = ComposerTextView.lineHeight(ComposerTextView.body)
    @ObservationIgnored weak var field: ComposerTextView? {
        didSet {
            guard let field else { return }
            field.show(text)
            if wantsKeyboard { field.takeKeyboard() }
            wantsKeyboard = false
        }
    }
    /// Set while the field hands over what was typed, which it already shows.
    @ObservationIgnored fileprivate var typing = false
    /// Asked for the keyboard before the field was made.
    @ObservationIgnored private var wantsKeyboard = false

    /// Gives the field the keyboard, or takes it away, leaving it with the window, where a waiting
    /// card's default button hears Return.
    func keyboard(_ takes: Bool) {
        guard let field else {
            wantsKeyboard = takes
            return
        }
        if takes { field.takeKeyboard() } else { field.letGoOfKeyboard() }
    }

    /// A new line where the caret is, as the field's own Return would put it.
    func newLine() {
        if let field { field.insertNewline(nil) } else { text += "\n" }
    }
}

/// What the composer does with the keys its field hands it.
struct ComposerKeys {
    /// Return with these modifiers: send, queue or a new line is the composer's to say.
    var enter: (EventModifiers) -> Void = { _ in }
    /// ↑ and ↓, true when the composer took them; otherwise the caret moves.
    var up: () -> Bool = { false }
    var down: () -> Bool = { false }
    /// Tab, forward or back. It never takes the keyboard out of the field.
    var tab: (_ backward: Bool) -> Void = { _ in }
    /// ⌫, true when the composer took it.
    var delete: () -> Bool = { false }
    /// Images and files dropped on the text, which go among the attachments as they do anywhere on
    /// the composer; nil when the agent takes none, and the field takes them as text.
    var drop: ((NSPasteboard) -> Bool)?
    /// Something the drop would take is over the field, or no longer is.
    var dropping: (Bool) -> Void = { _ in }
}

/// The composer's field: AppKit's text view in its scroll view, which keeps its layout from one key
/// to the next, where SwiftUI's multi-line TextField measured all of its text again on every key.
/// Its height comes from that layout and changes only when a line comes or goes.
struct ComposerField: NSViewRepresentable {
    let draft: Draft
    let placeholder: String
    let font: NSFont
    /// How much of its ink the text has, which the prompt's morph fades in.
    let shown: Double
    let maxLines: Int
    let keys: ComposerKeys

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        let field = ComposerTextView.make()
        field.autoresizingMask = [.width]
        field.keys = keys
        field.draft = draft
        scroll.documentView = field
        draft.field = field
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let field = scroll.documentView as? ComposerTextView else { return }
        field.keys = keys
        if field.draft !== draft {
            // Another thread's draft. The one that was here lets go of the field, or a message
            // handed back to its thread would be written over what this one shows.
            if field.draft?.field === field { field.draft?.field = nil }
            field.draft = draft
            field.turn(to: draft.text)
        }
        if draft.field !== field { draft.field = field }
        field.dress(font: font, ink: 0.92 * shown)
        field.maxHeight = ComposerTextView.lineHeight(font) * CGFloat(maxLines)
        if field.accessibilityLabel() != placeholder {
            field.setAccessibilityLabel(placeholder)
            field.setAccessibilityPlaceholderValue(placeholder)
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) {
        (scroll.documentView as? ComposerTextView)?.keys = nil
    }
}

final class ComposerTextView: NSTextView {
    static let body = NSFont.systemFont(ofSize: 14)
    static let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    private static let metrics = NSLayoutManager()

    /// A line of the field's text, as its layout sets it.
    static func lineHeight(_ font: NSFont) -> CGFloat {
        metrics.defaultLineHeight(for: font)
    }

    /// Where its first line's baseline sits under the top, for the placeholder and the prompt's
    /// fading copy to stand on.
    static func baseline(_ font: NSFont) -> CGFloat {
        metrics.defaultBaselineOffset(for: font)
    }

    var keys: ComposerKeys?
    weak var draft: Draft?
    /// The most the field grows to before its text scrolls.
    var maxHeight: CGFloat = .infinity {
        didSet { if maxHeight != oldValue { measure() } }
    }
    /// Asked for the keyboard before it was in a window.
    private var wantsKeyboard = false
    /// Writing the draft's text in, which the draft already holds.
    private var showing = false
    private var dressed: (font: NSFont?, ink: CGFloat) = (nil, 0)

    /// A plain text view on TextKit 1. TextKit 2's adds a view for the paragraph each key lays out
    /// again, and every one of them had SwiftUI lay out the whole window again, transcript and all.
    static func make() -> ComposerTextView {
        let field = ComposerTextView(usingTextLayoutManager: false)
        field.setUp()
        return field
    }

    private func setUp() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        minSize = .zero
        // The system's caret is a dim grey on the dark glass, which reads as a field without focus.
        insertionPointColor = NSColor(white: 1, alpha: 0.92)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        dress(font: Self.body, ink: 0.92)
    }

    /// The type and how much white the text has, which change only as the prompt turns.
    func dress(font: NSFont, ink: CGFloat) {
        guard font != dressed.font || ink != dressed.ink else { return }
        let refont = font != dressed.font
        dressed = (font, ink)
        let color = NSColor(white: 1, alpha: ink)
        self.font = font
        textColor = color
        typingAttributes = [.font: font, .foregroundColor: color]
        if refont { measure() }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        // Return is the composer's, unless an input method is still composing, which it confirms.
        if let keys, !hasMarkedText(), event.keyCode == 36 || event.keyCode == 76 {
            keys.enter(EventModifiers(event.modifierFlags))
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if let keys {
            switch selector {
            case #selector(moveUp(_:)): if keys.up() { return }
            case #selector(moveDown(_:)): if keys.down() { return }
            case #selector(insertTab(_:)), #selector(insertTabIgnoringFieldEditor(_:)):
                keys.tab(false)
                return
            case #selector(insertBacktab(_:)):
                keys.tab(true)
                return
            case #selector(deleteBackward(_:)): if keys.delete() { return }
            // Esc that nothing over the thread took: a text view would offer word completions.
            case #selector(cancelOperation(_:)): return
            default: break
            }
        }
        super.doCommand(by: selector)
    }

    // MARK: Text

    override func didChangeText() {
        super.didChangeText()
        measure()
        guard !showing, let draft else { return }
        draft.typing = true
        draft.text = string
        draft.typing = false
    }

    /// Text set from outside, as one change ⌘Z takes back, with the caret at its end.
    func show(_ text: String) {
        guard text != string else { return }
        if hasMarkedText() { inputContext?.discardMarkedText() }
        let all = NSRange(location: 0, length: (string as NSString).length)
        showing = true
        defer { showing = false }
        breakUndoCoalescing()
        if shouldChangeText(in: all, replacementString: text) {
            replaceCharacters(in: all, with: text)
            didChangeText()
        } else {
            string = text
            measure()
        }
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    /// Another draft's text in the field, which is no edit: nothing for ⌘Z to take back, and
    /// nothing left on its stack from the draft that was here, whose text it would bring over.
    func turn(to text: String) {
        if hasMarkedText() { inputContext?.discardMarkedText() }
        showing = true
        defer { showing = false }
        breakUndoCoalescing()
        undoManager?.disableUndoRegistration()
        string = text
        undoManager?.enableUndoRegistration()
        if let textStorage { undoManager?.removeAllActions(withTarget: textStorage) }
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        measure()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let rewraps = newSize.width != frame.width
        super.setFrameSize(newSize)
        if rewraps { measure() }
    }

    /// The height of the text's lines, from the layout the text view keeps between keys, laid out
    /// only as far as the field can grow.
    func measure() {
        guard let draft, let manager = layoutManager, let container = textContainer else { return }
        manager.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: container.size.width, height: maxHeight), in: container)
        let used = manager.usedRect(for: container).height
        let line = Self.lineHeight(font ?? Self.body)
        let height = min(max(used.rounded(.up), line), max(maxHeight, line))
        // A field that fits its text has nothing to bounce.
        enclosingScrollView?.verticalScrollElasticity = used > height ? .automatic : .none
        if draft.height != height { draft.height = height }
    }

    // MARK: Keyboard

    func takeKeyboard() {
        guard let window else {
            wantsKeyboard = true
            return
        }
        if window.firstResponder !== self { window.makeFirstResponder(self) }
    }

    func letGoOfKeyboard() {
        wantsKeyboard = false
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsKeyboard, let window {
            wantsKeyboard = false
            window.makeFirstResponder(self)
        }
    }

    // MARK: Cursor

    /// The I-beam is the text view's over its own frame; where the pointer goes next is left the
    /// arrow, since SwiftUI's views around it set no cursor of their own to take the I-beam back.
    override func cursorUpdate(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            super.cursorUpdate(with: event)
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
    }

    /// A field that goes, under the pointer, takes its I-beam with it.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, newWindow == nil, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            NSCursor.arrow.set()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: Drop

    private func attaches(_ drag: NSDraggingInfo) -> Bool {
        guard keys?.drop != nil else { return false }
        let board = drag.draggingPasteboard
        return board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || board.canReadObject(forClasses: [NSImage.self])
    }

    override func draggingEntered(_ drag: NSDraggingInfo) -> NSDragOperation {
        guard attaches(drag) else { return super.draggingEntered(drag) }
        keys?.dropping(true)
        return .copy
    }

    override func draggingUpdated(_ drag: NSDraggingInfo) -> NSDragOperation {
        attaches(drag) ? .copy : super.draggingUpdated(drag)
    }

    override func draggingExited(_ drag: NSDraggingInfo?) {
        keys?.dropping(false)
        super.draggingExited(drag)
    }

    override func performDragOperation(_ drag: NSDraggingInfo) -> Bool {
        guard attaches(drag), let drop = keys?.drop else { return super.performDragOperation(drag) }
        keys?.dropping(false)
        return drop(drag.draggingPasteboard)
    }
}
