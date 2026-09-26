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
    /// What Tab found when several things match, as the last word would read with each, and the
    /// one the text holds while Tab cycles through them.
    @State private var completions: [String] = []
    @State private var completionIndex: Int?
    /// The line before the word Tab completes, and the text as Tab last left it: typing anything
    /// else puts the list away.
    @State private var completionHead = ""
    @State private var completed = ""
    /// Where ↑ has got to in what was sent or run, while the text is still that line.
    @State private var recalled: Int?
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
            if !shown { focused = model.composerTakesKeyboard }
        }
        .overlay(alignment: .bottomLeading) {
            if !slashMatches.isEmpty {
                SlashMenu(commands: slashMatches, selected: min(slashSelected, slashMatches.count - 1)) { complete($0) }
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(.bottom, height + 8)
                    .transition(.opacity)
            } else if !completions.isEmpty {
                CompletionMenu(candidates: completions, selected: completionIndex) { pick($0) }
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(.bottom, height + 8)
                    .transition(.opacity)
            }
        }
        // Esc puts the list away before anything else hears it.
        .onChange(of: completions.isEmpty) { _, empty in model.composerMenu = !empty }
        .onChange(of: model.composerMenu) { _, shown in
            if !shown { completions = [] }
        }
        .onChange(of: model.shellPrompt) { _, prompt in
            completions = []
            recalled = nil
            // Tab at the prompt wants the shell's commands; asked once, as the prompt opens.
            if prompt { model.loadShellCommands() }
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
        .onAppear { focused = model.composerTakesKeyboard }
        // Not while a block is open, which has the keyboard until it goes.
        .onChange(of: model.composerFocus) {
            if model.openShell == nil { focused = true }
        }
        // While Claude waits on a card, the card owns Return and Esc; the field would eat them.
        .onChange(of: waitingAsk?.requestId) { _, waiting in
            if waiting != nil {
                focused = false
            } else if !model.keyboardTaken {
                focused = model.composerTakesKeyboard
            }
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
                    if now != completed { completions = [] }
                    guard !model.shellPrompt, now.hasPrefix("!") else { return }
                    withAnimation(Motion.fade) { model.shellPrompt = true }
                    text = String(now.dropFirst())
                }
                // ⌫ in an empty prompt turns it back. The Backspace key sends DEL, 0x7F, which
                // isn't SwiftUI's .delete, 0x08.
                .onKeyPress(keys: [.delete, KeyEquivalent("\u{7F}")]) { _ in
                    guard model.shellPrompt, text.isEmpty else { return .ignored }
                    withAnimation(Motion.fade) { model.shellPrompt = false }
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    if !slashMatches.isEmpty {
                        slashSelected = min(slashSelected + 1, slashMatches.count - 1)
                        return .handled
                    }
                    if !completions.isEmpty {
                        tab(backward: false)
                        return .handled
                    }
                    return recall(older: false) ? .handled : .ignored
                }
                .onKeyPress(.upArrow) {
                    if !slashMatches.isEmpty {
                        slashSelected = max(slashSelected - 1, 0)
                        return .handled
                    }
                    if !completions.isEmpty {
                        tab(backward: true)
                        return .handled
                    }
                    return recall(older: true) ? .handled : .ignored
                }
                // Tab never takes the keyboard out of the composer: it completes, or does nothing.
                // ⇧Tab arrives as a backtab.
                .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
                    tab(backward: press.key != .tab || press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    completions = []
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
        let moving = model.currentConversation?.items.isEmpty ?? true
        model.rememberCommand(text)
        model.runCommand(text)
        text = ""
        recalled = nil
        rebuild(after: moving)
    }

    /// A new field after each send or command, whose editor otherwise sometimes writes the sent
    /// text back after Return, given the keyboard once it's in the window: asked for in the same
    /// update as the new field, focus stayed with the old one on its way out, and the next keys
    /// went nowhere. After a first message the composer slides down first.
    private func rebuild(after moving: Bool) {
        Task { @MainActor in
            if moving { try? await Task.sleep(for: .milliseconds(650)) }
            text = ""
            draft = UUID()
            try? await Task.sleep(for: .milliseconds(30))
            // A program that took the whole screen meanwhile, vim run as the first command, keeps it.
            if model.openShell == nil { focused = true }
        }
    }

    /// Tab: the slash command the list is on; again, the next of several matches; else the word
    /// being typed, as a command or path at the prompt, or a path after `@` in a message.
    private func tab(backward: Bool) {
        if let command = selectedSlash {
            complete(command)
            return
        }
        if !completions.isEmpty {
            let count = completions.count
            let next = completionIndex.map { (backward ? $0 - 1 + count : $0 + 1) % count } ?? (backward ? count - 1 : 0)
            pick(next)
            return
        }
        guard let chat = model.chat else { return }
        guard model.shellPrompt else {
            apply(ShellCompletion.mention(text, folder: chat.cwd))
            return
        }
        let line = text
        Task { @MainActor in
            let commands = await model.shellCommands()
            // Typed on while the shell answered: that Tab is stale.
            guard text == line else { return }
            apply(ShellCompletion.complete(line, folder: chat.cwd, commands: commands))
        }
    }

    private func apply(_ result: ShellCompletion.Result?) {
        guard let result else { return }
        completed = result.text
        text = result.text
        if !result.candidates.isEmpty {
            completionHead = ShellCompletion.split(result.text).head
            completionIndex = nil
            completions = result.candidates
        }
    }

    /// One of several matches, in place of the word being completed.
    private func pick(_ index: Int) {
        guard completions.indices.contains(index) else { return }
        completionIndex = index
        completed = completionHead + completions[index]
        text = completed
    }

    /// ↑ and ↓ through what was run at the prompt, or sent in this thread, the way a shell and
    /// Claude Code go back: only from an empty composer or a line ↑ brought back, so the arrows
    /// still move about in text you're writing.
    private func recall(older: Bool) -> Bool {
        let lines = history
        if let index = recalled, lines.indices.contains(index), text == lines[index] {
            let next = older ? index - 1 : index + 1
            if next < 0 { return true }
            if next >= lines.count {
                recalled = nil
                text = ""
            } else {
                recalled = next
                text = lines[next]
            }
            return true
        }
        guard older, text.isEmpty, let last = lines.indices.last else { return false }
        recalled = last
        text = lines[last]
        return true
    }

    private var history: [String] {
        if model.shellPrompt { return model.shellHistory }
        let sent = model.currentConversation?.items.compactMap { item -> String? in
            if case .user(_, let text, _) = item { text } else { nil }
        } ?? []
        // What the app sent for you isn't yours to send again.
        return sent.filter { $0 != AppModel.quitLine && $0 != AppModel.limitLine }
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
        recalled = nil
        // A new field is inserted at its final place, so while the composer is still sliding
        // it would draw apart from it; it's rebuilt once the slide is over.
        rebuild(after: moving)
    }
}
