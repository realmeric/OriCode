import MarkdownUI
import SwiftUI

struct TranscriptView: View {
    let conversation: Conversation
    let cwd: String
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var pinned = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(conversation.items.enumerated()), id: \.element.id) { index, item in
                    ItemView(
                        item: item, cwd: cwd, listening: conversation.waitingAsk?.requestId,
                        live: conversation.running && index == conversation.items.count - 1)
                        .padding(.top, index == 0 ? 0 : spacing(before: item, after: conversation.items[index - 1]))
                }
            }
            .column()
            .padding(.top, 52)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
        } action: { _, atBottom in
            pinned = atBottom
        }
        .onChange(of: conversation.items) {
            if pinned { position.scrollTo(edge: .bottom) }
        }
        .mask {
            // Fades under the top edge and above the composer instead of ending at a line.
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 44)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24)
            }
        }
    }

    private func spacing(before item: Item, after previous: Item) -> CGFloat {
        switch (previous, item) {
        case (.tool(_, let a), .tool(_, let b)) where a.isEdit || b.isEdit: 8
        case (.tool, .tool): 4
        case (_, .footer): 8
        case (.footer, _): 28
        default: 14
        }
    }
}

struct ItemView: View {
    let item: Item
    let cwd: String
    let listening: String?
    let live: Bool

    var body: some View {
        switch item {
        case .user(_, let text):
            Text(text)
                .font(Type.body)
                .foregroundStyle(Ink.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Surface.userMessage, in: .rect(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: 560, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .text(_, let text):
            Markdown(text)
                .markdownTheme(.glass)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking(_, let text):
            ThinkingLine(text: text, live: live)
        case .tool(_, let call):
            if call.isEdit && !call.isError {
                DiffCard(call: call, cwd: cwd)
            } else {
                ToolLine(call: call, cwd: cwd)
            }
        case .ask(_, let ask):
            AskCard(ask: ask, cwd: cwd, listens: ask.requestId == listening)
        case .footer(_, let footer):
            HStack(spacing: 5) {
                Text(footer.line)
                if footer.files > 0 {
                    Text("· \(footer.files) \(footer.files == 1 ? "file" : "files") ·")
                    Counts(added: footer.added, deleted: footer.deleted)
                        .opacity(0.8)
                }
            }
            .font(Type.secondary)
            .foregroundStyle(Ink.faint)
        case .note(_, let text):
            Text(text)
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .textSelection(.enabled)
        }
    }
}

struct ToolLine: View {
    let call: ToolCall
    let cwd: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.fade) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(ToolSummary.line(for: call, cwd: cwd))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if call.isError {
                        Text("failed").foregroundStyle(Ink.faint)
                    } else if call.result == nil {
                        ProgressView().controlSize(.mini).tint(Ink.secondary)
                    }
                }
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(call.result == nil)
            if open, let result = call.result {
                ScrollView {
                    Text(result.isEmpty ? "(no output)" : String(result.prefix(20_000)))
                        .font(Type.mono)
                        .foregroundStyle(Ink.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
                .background(Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
                .transition(.opacity)
            }
        }
    }
}

/// Thinking, folded to one line; the summary Claude streamed is underneath.
struct ThinkingLine: View {
    let text: String
    let live: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.fade) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(live ? "Thinking…" : "Thought")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(Type.secondary)
                .foregroundStyle(Ink.faint)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                Text(text)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 10)
                    .transition(.opacity)
            }
        }
    }
}

extension TurnFooter {
    var line: String {
        let seconds = Int((durationMs / 1000).rounded())
        let time = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        if stopReason == "interrupted" { return "Stopped after \(time)" }
        return "Worked for \(time) · " + String(format: "$%.2f", costUSD)
    }
}
