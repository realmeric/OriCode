import MarkdownUI
import SwiftUI

extension Theme {
    /// Markdown in the brief's ink: no coloured links, code on the card surface.
    @MainActor static let glass = Theme()
        .text {
            ForegroundColor(Ink.primary)
            FontSize(14)
        }
        .link {
            ForegroundColor(Ink.primary)
            UnderlineStyle(.single)
        }
        .strong {
            FontWeight(.semibold)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
            BackgroundColor(Surface.card)
        }
        .heading1 { configuration in
            configuration.label
                .linkPointers(configuration.content)
                .blockMargin(top: 16, bottom: 8)
                .markdownTextStyle { FontWeight(.semibold); FontSize(18) }
        }
        .heading2 { configuration in
            configuration.label
                .linkPointers(configuration.content)
                .blockMargin(top: 14, bottom: 6)
                .markdownTextStyle { FontWeight(.semibold); FontSize(16) }
        }
        .heading3 { configuration in
            configuration.label
                .linkPointers(configuration.content)
                .blockMargin(top: 12, bottom: 4)
                .markdownTextStyle { FontWeight(.semibold); FontSize(14) }
        }
        .paragraph { configuration in
            configuration.label
                .lineSpacing(3)
                .linkPointers(configuration.content)
                .blockMargin(top: 0, bottom: 10)
        }
        .listItem { configuration in
            configuration.label
                .blockMargin(top: 3)
        }
        .blockquote { configuration in
            configuration.label
                .markdownTextStyle { ForegroundColor(Ink.secondary) }
                .padding(.leading, 12)
        }
        .codeBlock { CodeBlock(configuration: $0) }
        .tableCell { configuration in
            configuration.label
                .linkPointers(configuration.content)
        }
        .table { configuration in
            configuration.label
                .markdownTableBorderStyle(.init(color: .clear))
                .markdownTableBackgroundStyle(.alternatingRows(Surface.card, .clear))
                .blockMargin(top: 4, bottom: 12)
        }
        .thematicBreak {
            Rectangle()
                .fill(Surface.card)
                .frame(height: 1)
                .blockMargin(top: 10, bottom: 10)
        }
}

/// A block's margins, the largest of each among it and the blocks inside it, as MarkdownUI works
/// out its own, which are internal to it: Reply spaces its blocks with these.
struct ReplyMargin: PreferenceKey {
    struct Value: Equatable {
        var top: CGFloat?
        var bottom: CGFloat?

        mutating func merge(_ other: Value) {
            top = [top, other.top].compactMap { $0 }.max()
            bottom = [bottom, other.bottom].compactMap { $0 }.max()
        }
    }

    static let defaultValue = Value()

    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue())
    }
}

extension View {
    /// MarkdownUI's margin, told to Reply as well.
    func blockMargin(top: CGFloat? = nil, bottom: CGFloat? = nil) -> some View {
        markdownMargin(top: top, bottom: bottom)
            .transformPreference(ReplyMargin.self) { $0.merge(.init(top: top, bottom: bottom)) }
    }
}

/// A reply's code on its card, with Copy at its top right. In a block taller than what's on
/// screen the button rides the top edge down the block, so it's in reach wherever the block is
/// read, and it's moved as a visual effect: scrolling lays nothing out again.
private struct CodeBlock: View {
    let configuration: CodeBlockConfiguration
    @Environment(\.codeCopyLine) private var line
    @State private var hovering = false

    var body: some View {
        ScrollView(.horizontal) {
            configuration.label
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(12.5)
                    ForegroundColor(Ink.primary)
                }
                // A line scrolled to its end stops clear of Copy.
                .padding(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: CodeCopy.side + CodeCopy.inset))
        }
        .scrollIndicators(.never)
        .background(Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            GeometryReader { block in
                CodeCopyButton(code: configuration.content, lit: hovering)
                    .padding(CodeCopy.inset)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .visualEffect { [line] content, button in
                        content.offset(y: CodeCopy.travel(top: button.frame(in: .scrollView(axis: .vertical)).minY, block: block.size.height, line: line))
                    }
            }
        }
        .onHover { hovering = $0 }
        .blockMargin(top: 4, bottom: 12)
    }
}

enum CodeCopy {
    static let side: CGFloat = 26
    static let inset: CGFloat = 8

    /// How far down its block the button sits: none while the block's top is below the line, then
    /// as far as keeps it on the line, and never past the block's foot.
    static func travel(top: CGFloat, block: CGFloat, line: CGFloat) -> CGFloat {
        min(max(0, line - top), max(0, block - side - 2 * inset))
    }
}

private struct CodeCopyButton: View {
    let code: String
    /// The pointer is over the block.
    let lit: Bool
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            // The fence's last newline isn't the code's.
            pasteboard.setString(code.hasSuffix("\n") ? String(code.dropLast()) : code, forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "square.on.square")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering || copied ? Ink.primary : lit ? Ink.secondary : Ink.faint)
                .frame(width: CodeCopy.side, height: CodeCopy.side)
                .background(Color.white.opacity(hovering ? 0.16 : lit ? 0.10 : 0), in: .rect(cornerRadius: 8, style: .continuous))
                .contentShape(.rect)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help("Copy")
        .accessibilityLabel("Copy code")
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        .animation(Motion.fade, value: lit)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}

extension EnvironmentValues {
    /// Where a code block's Copy stops, down from the top of the scroll view it's read in: under
    /// the title capsule in the transcript.
    @Entry var codeCopyLine: CGFloat = 8
}
