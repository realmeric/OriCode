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
    /// Where the composer's top is in the window, for which side the picker opens on.
    @State private var top: CGFloat = .infinity
    @State private var attachHovered = false
    /// An image or file held over the composer, about to land in it.
    @State private var dropTarget = false
    @FocusState private var focused: Bool

    /// The tallest picker, its gap and the 52pt title bar: with less room than this above the
    /// composer, the picker opens below it.
    static let pickerRoom: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.draftAttachments.isEmpty {
                thumbnails
            }
            row
        }
        .padding(6)
        .frame(minHeight: 48)
        .background(dropTarget ? Surface.dropTarget : Surface.composer, in: .rect(cornerRadius: 24, style: .continuous))
        .animation(Motion.fade, value: dropTarget)
        .overlay {
            // The raised-glass highlight along the top edge, fading out before the sides.
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Surface.composerEdge, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)),
                    lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
            top = $0
            model.composerTop = $0
        }
        // The model button's picker rises out of the composer's right end, the way the slash
        // menu rises out of its left; with the composer in the middle of an empty thread there
        // isn't room above it under the title bar, so it drops below instead.
        .overlay(alignment: top < Self.pickerRoom ? .topTrailing : .bottomTrailing) {
            if model.modelPickerShown {
                let below = top < Self.pickerRoom
                let anchor: UnitPoint = below ? .topTrailing : .bottomTrailing
                PickerCard(chat: model.chat)
                    .padding(below ? .top : .bottom, height + 10)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.92, anchor: anchor).combined(with: .opacity).combined(with: .offset(y: below ? -8 : 8))
                            .animation(Motion.glide),
                        removal: .scale(scale: 0.97, anchor: anchor).combined(with: .opacity).animation(Motion.fade)))
            }
        }
        .onChange(of: model.modelPickerShown) { _, shown in
            if !shown { focused = true }
        }
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
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTarget) { providers in
            accept(providers)
        }
        // The finger is on the trackpad for the whole drag, so this says "let go here".
        .onChange(of: dropTarget) { _, over in
            if over { Haptics.detent() }
        }
        .onAppear { focused = true }
        // Not while a block is open, which has the keyboard until it goes.
        .onChange(of: model.composerFocus) {
            if model.openBlock == nil { focused = true }
        }
        // While Claude waits on a card, the card owns Return and Esc; the field would eat them.
        .onChange(of: waitingAsk?.requestId) { _, waiting in
            if model.openBlock == nil { focused = waiting == nil }
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
            if model.shellPrompt {
                Text("$")
                    .font(Type.mono)
                    .foregroundStyle(Ink.secondary)
                    .padding(.leading, 14)
                    .padding(.vertical, 9)
                    .transition(.opacity)
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(model.shellPrompt ? Type.mono : Type.body)
                .foregroundStyle(Ink.primary)
                .lineLimit(1...maxLines)
                .id(draft)
                .focused($focused)
                // A `!` at the start turns the composer into a shell prompt, as in Claude Code.
                .onChange(of: text) { _, now in
                    guard !model.shellPrompt, now.hasPrefix("!") else { return }
                    withAnimation(Motion.fade) { model.shellPrompt = true }
                    text = String(now.dropFirst())
                }
                // ⌫ in an empty prompt turns it back.
                .onKeyPress(.delete) {
                    guard model.shellPrompt, text.isEmpty else { return .ignored }
                    withAnimation(Motion.fade) { model.shellPrompt = false }
                    return .handled
                }
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
                    } else if model.shellPrompt {
                        runCommand()
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
                .padding(.leading, model.shellPrompt ? 0 : 14)
            HStack(spacing: 4) {
                attachButton
                ModelMenu(chat: model.chat)
                UsageGlass(chat: model.chat)
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
                .foregroundStyle(attachHovered ? Ink.primary : Ink.secondary)
                .frame(width: 30, height: 30)
                .background(attachHovered ? Surface.hover : .clear, in: .circle)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { attachHovered = $0 }
        .help("Attach an image")
        .accessibilityLabel("Attach an image")
    }

    private var maxLines: Int {
        max(1, Int((maxHeight - 28) / 18))
    }

    private var sendButton: some View {
        // At the shell prompt it runs the command, whether or not a turn is running.
        let stops = running && !model.shellPrompt
        return Button {
            if model.shellPrompt { runCommand() } else if running { model.stop() } else { send() }
        } label: {
            Image(systemName: stops ? "stop.fill" : "arrow.up")
                .font(.system(size: stops ? 12 : 15, weight: .semibold))
                // One button changing its job, not two buttons swapping.
                .contentTransition(.symbolEffect(.replace))
                .animation(Motion.fade, value: stops)
                // The fade is for the symbol; where it sits follows the composer as one piece.
                .geometryGroup()
                .frame(width: 36, height: 36)
                // Scoped to colour: a fade on the whole button also animated its position,
                // and it left the capsule behind when the composer slid down.
                .animation(Motion.fade) { content in
                    content
                        .foregroundStyle(canSend || stops ? Color.black.opacity(0.85) : Ink.faint)
                        .background(canSend || stops ? Ink.primary : Surface.selected, in: .circle)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!stops && !canSend)
        .help(model.shellPrompt ? "Run (Return)" : running ? "Stop (⌘.)" : "Send (Return)")
        .accessibilityLabel(model.shellPrompt ? "Run" : running ? "Stop" : "Send")
    }

    private var placeholder: String {
        guard model.shellPrompt else { return "Ask for a change" }
        return "A command for " + (model.chat.map { URL(filePath: $0.cwd).lastPathComponent } ?? model.project?.name ?? "the project")
    }

    private func runCommand() {
        guard canSend else { return }
        model.runCommand(text)
        text = ""
        draft = UUID()
        focused = true
    }

    /// The word after a leading "/", while it's still being typed.
    private var slashQuery: String? {
        guard !model.shellPrompt, text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return nil }
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
        let moving = model.currentConversation?.items.isEmpty ?? true
        // The first message moves the composer from the middle of an empty thread to the bottom.
        var sent = false
        withAnimation(Motion.glide) { sent = model.send(text) }
        guard sent else { return }
        text = ""
        // A new field is inserted at its final place, so while the composer is still sliding
        // it would draw apart from it; rebuild it once the slide is over.
        Task { @MainActor in
            if moving { try? await Task.sleep(for: .milliseconds(650)) }
            text = ""
            draft = UUID()
            focused = true
        }
    }
}
