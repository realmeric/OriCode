import AppKit
import SwiftUI

/// A task in its well on the stage: the script's words faint and what it took from the agents
/// before it in ink, laid out by TextKit as one attributed string. Text keeps a paragraph's last
/// word from standing alone by wrapping the word before it early, which made a faint lead-in
/// break short of the line's end, and it has no space between paragraphs; here each line wraps at
/// its end, the task's lines stand apart as 04 has them, and what's drawn is what was measured.
struct WellText: NSViewRepresentable {
    let text: AttributedString
    let lines: Int

    /// 04's line, 18pt, and the space between the task's lines.
    static let lineHeight: CGFloat = 18
    static let paragraphSpacing: CGFloat = 5

    func makeNSView(context: Context) -> WellTextView {
        WellTextView()
    }

    func updateNSView(_ view: WellTextView, context: Context) {
        let shown = Self.attributed(text)
        if view.text != shown || view.lines != lines {
            view.text = shown
            view.lines = lines
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WellTextView, context: Context) -> CGSize? {
        // Asked for its ideal size, it's as wide as a card.
        let width = proposal.width.map { $0.isFinite ? $0 : StageLayout.card } ?? StageLayout.card
        guard width > 0 else { return .zero }
        return CGSize(width: width, height: Self.height(text, width: width, lines: lines))
    }

    /// The well's words as AppKit draws them: one font and one paragraph style, the colours the
    /// task's runs carry, and a run of empty lines taken as one.
    nonisolated static func attributed(_ text: AttributedString) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.paragraphSpacing = paragraphSpacing
        let font = NSFont.systemFont(ofSize: 12.5)
        // The line's extra height goes as much above the words as below them.
        let lift = (lineHeight - ceil(font.ascender - font.descender)) / 2
        let shown = NSMutableAttributedString()
        for run in text.runs {
            let color = run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self].map(NSColor.init) ?? NSColor.white.withAlphaComponent(0.34)
            shown.append(NSAttributedString(string: String(text[run.range].characters),
                                            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph, .baselineOffset: lift]))
        }
        shown.mutableString.replaceOccurrences(of: "\n[ \t]*(?:\n[ \t]*)+", with: "\n", options: .regularExpression,
                                               range: NSRange(location: 0, length: shown.length))
        return shown
    }

    nonisolated static func height(_ text: AttributedString, width: CGFloat, lines: Int) -> CGFloat {
        let (storage, manager, container) = layout(attributed(text), width: width, lines: lines)
        return withExtendedLifetime(storage) { ceil(manager.usedRect(for: container).height) }
    }

    /// The storage comes back with its layout, which holds it only weakly.
    nonisolated static func layout(_ text: NSAttributedString, width: CGFloat, lines: Int) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(attributedString: text)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = lines
        container.lineBreakMode = .byTruncatingTail
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return (storage, manager, container)
    }
}

/// Draws a well's words in its bounds, and takes no click: a click on the card steps into it.
final class WellTextView: NSView {
    var text = NSAttributedString() {
        didSet { needsDisplay = true }
    }
    var lines = 8

    override var isFlipped: Bool { true }

    override func setFrameSize(_ size: NSSize) {
        let changed = size.width != frame.width
        super.setFrameSize(size)
        if changed { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let (storage, manager, container) = WellText.layout(text, width: bounds.width, lines: lines)
        withExtendedLifetime(storage) { manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: .zero) }
    }
}
