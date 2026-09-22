import AppKit
import MarkdownUI
import SwiftUI

struct TranscriptView: View {
    let conversation: Conversation
    let cwd: String
    // Starting at .bottom scrolled past a long transcript's lazily measured content and left the
    // window blank at launch; defaultScrollAnchor places the first frame instead.
    @State private var position = ScrollPosition()
    @State private var pinned = true
    @State private var showAll = false

    /// A plain VStack: LazyVStack left a long transcript blank at launch when anchored to the
    /// bottom. To keep a long thread cheap, only the latest items are laid out until asked.
    private static let recent = 200

    private var shown: ArraySlice<Item> {
        showAll ? conversation.items[...] : conversation.items.suffix(Self.recent)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if shown.count < conversation.items.count {
                    Button("Show \(conversation.items.count - shown.count) earlier") { showAll = true }
                        .buttonStyle(.plain)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.faint)
                        .padding(.bottom, 20)
                }
                ForEach(Array(zip(shown.indices, shown)), id: \.1.id) { index, item in
                    ItemView(
                        item: item, cwd: cwd, listening: conversation.waitingAsk?.requestId,
                        live: conversation.running && index == conversation.items.count - 1)
                        .padding(.top, index == shown.startIndex ? 0 : spacing(before: item, after: conversation.items[index - 1]))
                }
                if let retrying = conversation.retrying {
                    Text(retrying)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.secondary)
                        .padding(.top, 14)
                        .transition(.opacity)
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
        case .user(_, let text, let images):
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                            if let image = NSImage(data: data) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 96, height: 72)
                                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                }
                Text(text)
                    .font(Type.body)
                    .foregroundStyle(Ink.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Surface.userMessage, in: .rect(cornerRadius: 18, style: .continuous))
            }
            .frame(maxWidth: 560, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .text(_, let text):
            Markdown(text)
                .markdownTheme(.glass)
                .markdownSoftBreakMode(.lineBreak)
                .markdownCodeSyntaxHighlighter(TranscriptCodeHighlighter.shared)
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
            FooterLine(footer: footer)
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
        let line = ToolSummary.line(for: call, cwd: cwd)
        let path = ToolSummary.path(for: call)
        let shown = path.map { ToolSummary.relative($0, to: cwd) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(Motion.fade) { open.toggle() }
                } label: {
                    Text(shown.map { line.hasSuffix($0) ? String(line.dropLast($0.count)) : line } ?? line)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(call.result == nil)
                if let path, let shown {
                    FileLink(path: path, label: shown)
                }
                if call.isError {
                    Text("failed").foregroundStyle(Ink.faint)
                } else if call.result == nil {
                    ProgressView().controlSize(.mini).tint(Ink.secondary)
                }
            }
            .font(Type.secondary)
            .foregroundStyle(Ink.secondary)
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

/// A path that opens the file read-only; underlined while the mouse is on it.
struct FileLink: View {
    @Environment(AppModel.self) private var model
    let path: String
    let label: String
    @State private var hovering = false

    var body: some View {
        Button {
            model.openFile(path)
        } label: {
            Text(label)
                .underline(hovering)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(label)")
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

/// What a turn did. Its files always; how long it took and what it cost only when
/// Settings › Transcript asks, and nothing at all when there's nothing to say.
struct FooterLine: View {
    let footer: TurnFooter
    @AppStorage(TranscriptSettings.showTime) private var showTime = false
    @AppStorage(TranscriptSettings.showCost) private var showCost = false

    var body: some View {
        let words = footer.words(time: showTime, cost: showCost)
        if !words.isEmpty || footer.files > 0 {
            HStack(spacing: 5) {
                if !words.isEmpty { Text(words) }
                if footer.files > 0 {
                    Text((words.isEmpty ? "" : "· ") + "\(footer.files) \(footer.files == 1 ? "file" : "files") ·")
                    Counts(added: footer.added, deleted: footer.deleted)
                        .opacity(0.8)
                }
            }
            .font(Type.secondary)
            .foregroundStyle(Ink.faint)
        }
    }
}

enum TranscriptSettings {
    static let showTime = "showTurnTime"
    static let showCost = "showTurnCost"
}

extension TurnFooter {
    func words(time showTime: Bool, cost showCost: Bool) -> String {
        let seconds = Int((durationMs / 1000).rounded())
        let time = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        // A stopped turn says so either way: it's what happened, not a statistic.
        if stopReason == "interrupted" { return showTime ? "Stopped after \(time)" : "Stopped" }
        var parts: [String] = []
        if showTime { parts.append("Worked for \(time)") }
        if showCost { parts.append(String(format: "$%.2f", costUSD)) }
        return parts.joined(separator: " · ")
    }
}
