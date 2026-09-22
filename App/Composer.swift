import AppKit
import SwiftUI

struct Composer: View {
    @Environment(AppModel.self) private var model
    let running: Bool
    let maxHeight: CGFloat
    @State private var text = ""
    /// A new id after each send rebuilds the field, whose editor otherwise sometimes writes the
    /// sent text back after Return.
    @State private var draft = UUID()
    @State private var slashSelected = 0
    @State private var height: CGFloat = 48
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.draftAttachments.isEmpty {
                thumbnails
            }
            row
        }
        .padding(6)
        .frame(minHeight: 48)
        .background(Surface.composer, in: .rect(cornerRadius: 24, style: .continuous))
        .overlay {
            // The raised-glass highlight along the top edge, fading out before the sides.
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Surface.composerEdge, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)),
                    lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .overlay(alignment: .bottomLeading) {
            if !slashMatches.isEmpty {
                SlashMenu(commands: slashMatches, selected: min(slashSelected, slashMatches.count - 1)) { complete($0) }
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(.bottom, height + 8)
                    .transition(.opacity)
            }
        }
        .onChange(of: slashQuery) { _, query in
            slashSelected = 0
            if query != nil, let chat = model.chat { model.loadCommands(for: chat) }
        }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            accept(providers)
        }
        .onAppear { focused = true }
        // While Claude waits on a card, the card owns Return and Esc; the field would eat them.
        .onChange(of: waitingAsk?.requestId) { _, waiting in
            focused = waiting == nil
        }
    }

    private var thumbnails: some View {
        HStack(spacing: 6) {
            ForEach(model.draftAttachments) { attachment in
                Image(nsImage: attachment.thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            model.draftAttachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Ink.primary, Color.black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("Remove image")
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func accept(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSURL.self) {
                took = true
                _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                    guard let url = url as? URL else { return }
                    Task { @MainActor in _ = model.attach(fileAt: url) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                took = true
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in model.attach([image]) }
                }
            }
        }
        return took
    }

    private var row: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Ask for a change", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Type.body)
                .foregroundStyle(Ink.primary)
                .lineLimit(1...maxLines)
                .id(draft)
                .focused($focused)
                .onKeyPress(.downArrow) {
                    guard !slashMatches.isEmpty else { return .ignored }
                    slashSelected = min(slashSelected + 1, slashMatches.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !slashMatches.isEmpty else { return .ignored }
                    slashSelected = max(slashSelected - 1, 0)
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard let command = selectedSlash else { return .ignored }
                    complete(command)
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        text += "\n"
                    } else if let command = selectedSlash, text != "/" + command.name {
                        complete(command)
                    } else if !canSend, let ask = waitingPermission {
                        model.answer(ask, allow: true)
                    } else {
                        send()
                    }
                    return .handled
                }

                .padding(.vertical, 9)
                .padding(.leading, 14)
            HStack(spacing: 4) {
                attachButton
                ModelMenu(chat: model.chat)
                ContextRing(chat: model.chat)
                    .padding(.horizontal, 4)
            }
            .frame(height: 36)
            sendButton
        }
    }

    /// The native panel for images; they go in the way a paste or a drop does.
    private var attachButton: some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = true
            panel.prompt = "Attach"
            guard panel.runModal() == .OK else { return }
            for url in panel.urls { _ = model.attach(fileAt: url) }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 14))
                .foregroundStyle(Ink.secondary)
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Attach an image")
        .accessibilityLabel("Attach an image")
    }

    private var maxLines: Int {
        max(1, Int((maxHeight - 28) / 18))
    }

    private var sendButton: some View {
        Button {
            if running { model.stop() } else { send() }
        } label: {
            Image(systemName: running ? "stop.fill" : "arrow.up")
                .font(.system(size: running ? 12 : 15, weight: .semibold))
                .foregroundStyle(canSend || running ? Color.black.opacity(0.85) : Ink.faint)
                .frame(width: 36, height: 36)
                .background(canSend || running ? Ink.primary : Surface.selected, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!running && !canSend)
        .help(running ? "Stop (⌘.)" : "Send (Return)")
        .accessibilityLabel(running ? "Stop" : "Send")
        .animation(Motion.fade, value: running)
    }

    /// The word after a leading "/", while it's still being typed.
    private var slashQuery: String? {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return nil }
        return String(text.dropFirst())
    }

    private var slashMatches: [SlashCommandInfo] {
        guard let query = slashQuery, let chat = model.chat, let commands = model.slashCommands[chat.cwd] else { return [] }
        return Array(Fuzzy.rank(commands, by: query) { $0.name }.prefix(8))
    }

    private var selectedSlash: SlashCommandInfo? {
        let matches = slashMatches
        return matches.isEmpty ? nil : matches[min(slashSelected, matches.count - 1)]
    }

    private func complete(_ command: SlashCommandInfo) {
        text = "/" + command.name + ((command.hint ?? "").isEmpty ? "" : " ")
    }

    private var waitingAsk: PendingAsk? {
        model.currentConversation?.waitingAsk
    }

    private var waitingPermission: PendingAsk? {
        waitingAsk.flatMap { $0.kind == "permission" ? $0 : nil }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.draftAttachments.isEmpty
    }

    private func send() {
        guard !running, canSend else { return }
        model.send(text)
        text = ""
        draft = UUID()
        Task { @MainActor in focused = true }
    }
}

/// How full the thread's context is, as a thin ring around the send button.
struct ContextRing: View {
    let chat: Chat?

    var body: some View {
        let used = chat?.contextUsed ?? 0
        let window = chat?.contextWindow ?? 0
        let fraction = window > 0 ? min(1, Double(used) / Double(window)) : 0
        ZStack {
            Circle().stroke(Surface.selected, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(fraction > 0.8 ? Ink.primary : Ink.secondary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.move, value: fraction)
        }
        .frame(width: 20, height: 20)
        .help(window > 0 ? "\(used.formatted(.number.notation(.compactName))) of \(window.formatted(.number.notation(.compactName))) tokens" : "")
        .allowsHitTesting(false)
    }
}
