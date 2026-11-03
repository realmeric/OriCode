import Link
import SwiftUI

/// One row of a conversation. Observes its own line alone, so text streaming into the last row
/// draws that row and nothing above it.
struct TalkRow: View {
    @Environment(PhoneClient.self) private var store
    let row: ThreadTalk.Row

    var body: some View {
        let line = row.line
        switch line.kind {
        case .mine:
            MessageBubble(text: line.text, pictures: line.count)
        case .task:
            TaskRow(text: line.text)
        case .agent:
            MarkdownText(text: line.text)
        case .tools:
            ToolsRow(line: line)
        case .ask:
            // Waiting, its card answers here; answered, its one line stays where it stood.
            if let ask = line.ask.flatMap({ store.asks[$0] }) {
                AskCard(ask: ask, named: false)
            } else if !line.text.isEmpty {
                Text(line.text)
                    .font(.footnote)
                    .foregroundStyle(Ink.faint)
                    .lineLimit(2)
            }
        case .note:
            Text(line.text)
                .font(.footnote)
                .foregroundStyle(Ink.secondary)
        }
    }

    /// The room above a row, by what stands above it: a tool's lines keep together, and a new turn
    /// stands clear of the last.
    static func spacing(_ kind: TalkLine.Kind, after previous: TalkLine.Kind?) -> CGFloat {
        switch (previous, kind) {
        case (nil, _): 0
        case (.tools, .tools): 8
        case (_, .mine): 26
        default: 16
        }
    }
}

/// A message, a bubble on the right as on the Mac, with a mark for what went with it.
struct MessageBubble: View {
    let text: String
    var pictures = 0
    var ink = Ink.primary
    /// Refused or never taken: the red mark Messages puts beside one undelivered.
    var undelivered = false
    @State private var open = false

    /// The lines a long message shows until it's opened, as the Mac's.
    private static let folded = 12

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 36)
            if undelivered {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Ink.red)
            }
            VStack(alignment: .trailing, spacing: 6) {
                if pictures > 0 {
                    Label("\(pictures)", systemImage: "photo")
                        .font(.footnote)
                        .foregroundStyle(Ink.secondary)
                        .accessibilityLabel(pictures == 1 ? "A picture" : "\(pictures) pictures")
                }
                Text(text)
                    .font(.body)
                    .foregroundStyle(ink)
                    .lineLimit(open ? nil : Self.folded)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 18, style: .continuous))
                    .onTapGesture { if !undelivered { open.toggle() } }
            }
        }
    }
}

/// What the thread that opened this one told it, in a quiet well, its first lines until a tap.
private struct TaskRow: View {
    let text: String
    @State private var open = false

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Ink.secondary)
            .lineLimit(open ? nil : 4)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Ink.card, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
            .onTapGesture { open.toggle() }
    }
}

/// A call, or a run of them as one line that says what they did. A tap opens a run's calls, which
/// came with the page.
private struct ToolsRow: View {
    let line: TalkLine
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(line.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if line.failed > 0 {
                    Text(line.count > 1 ? "· \(line.failed) failed" : "failed")
                        .foregroundStyle(Ink.faint)
                        .layoutPriority(1)
                }
                if !line.calls.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
            }
            .font(.footnote)
            .foregroundStyle(Ink.secondary)
            .contentShape(.rect)
            .onTapGesture { if !line.calls.isEmpty { open.toggle() } }
            if open {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(line.calls.enumerated()), id: \.offset) { _, call in
                        Text(call)
                            .font(.footnote)
                            .foregroundStyle(Ink.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.leading, 10)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: open)
    }
}
