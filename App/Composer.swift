import AppKit
import SwiftUI

struct Composer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let running: Bool
    let maxHeight: CGFloat
    /// What's typed, in an object of its own: the body never reads it, so a key redraws only the
    /// field and the few views below that do.
    @State private var draft = Draft()
    /// A new id after each send rebuilds the field, whose editor otherwise sometimes writes the
    /// sent text back after Return.
    @State private var field = UUID()
    @State private var slashSelected = 0
    /// What Tab found when several things match, as the last word would read with each, and the
    /// one the text holds while Tab cycles through them.
    @State private var completions: [String] = []
    @State private var completionIndex: Int?
    /// What zsh lists beside a match, when it says.
    @State private var completionNotes: [String: String] = [:]
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
    /// Whether the queue's lines are scrolled to the last, which leaves nothing below to fade into.
    @State private var queueAtEnd = true
    @FocusState private var focused: Bool

    /// The tallest picker, its gap and the 52pt title bar: with less room than this above the
    /// composer, the picker opens below it.
    static let pickerRoom: CGFloat = 380
    /// A text field's placeholder, as AppKit draws it.
    private static let placeholderInk = Color(nsColor: .placeholderTextColor)

    private var text: String {
        get { draft.text }
        nonmutating set { draft.text = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !queue.isEmpty {
                queuedLines
            }
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
            Isolated {
                if !slashMatches.isEmpty {
                    SlashMenu(commands: slashMatches, selected: min(slashSelected, slashMatches.count - 1)) { complete($0) }
                        .frame(maxWidth: 520, alignment: .leading)
                        .padding(.bottom, height + 8)
                        .transition(.opacity)
                } else if !completions.isEmpty {
                    CompletionMenu(candidates: completions, descriptions: completionNotes, selected: completionIndex) { pick($0) }
                        .frame(maxWidth: 520, alignment: .leading)
                        .padding(.bottom, height + 8)
                        .transition(.opacity)
                }
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
        // Messages that won't go out after all, sent into the turn or queued, come back here when
        // their thread is the one showing: oldest first, ahead of what's typed. Not into a command
        // being typed at the prompt; they wait for the prompt to turn back into the composer.
        .onChange(of: model.shellPrompt ? nil : model.currentConversation?.returning, initial: true) {
            guard !model.shellPrompt, let back = model.currentConversation?.takeHandedBack(), !back.isEmpty else { return }
            withAnimation(Motion.fade) {
                text = QueuedMessage.joined(back.map(\.text) + [text])
                model.draftAttachments = back.flatMap(\.images) + model.draftAttachments
            }
        }
    }

    /// The thread's queue, in the order it goes, inside the composer's glass as the thumbnails are.
    private var queuedLines: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(queue) { message in
                    // A message taken back to edit would land in the command being typed.
                    QueuedLine(message: message, editable: !model.shellPrompt) {
                        takeBack(message)
                    } remove: {
                        model.currentConversation?.removeQueued(message.id)
                    }
                    .transition(.opacity)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 1
        } action: { _, atEnd in
            queueAtEnd = atEnd
        }
        // The half line under the third fades out, as the transcript does above the composer.
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, queueAtEnd ? .black : .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: QueuedLine.height / 2)
            }
        }
        .frame(height: queueHeight)
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    private var queue: [QueuedMessage] {
        model.currentConversation?.queue ?? []
    }

    /// Up to three lines and half of a fourth, which says the rest scroll.
    private var queueHeight: CGFloat {
        min(CGFloat(queue.count), 3.5) * QueuedLine.height
    }

    /// A queued message back in the field to be edited, after what's typed, its images with it.
    private func takeBack(_ message: QueuedMessage) {
        withAnimation(Motion.fade) {
            guard let taken = model.currentConversation?.takeBack(message.id) else { return }
            text = QueuedMessage.joined([text, taken.text])
            model.draftAttachments += taken.images
        }
        focused = true
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
                    // It grows out of the composer's left end as the text moves over for it.
                    .transition(reduceMotion ? .opacity.animation(Motion.fade) : .scale(scale: 0, anchor: .leading).combined(with: .opacity))
            }
            // Fonts don't interpolate, so the field's text and placeholder fade in with the new type
            // over a copy of what it showed in the old one. The field itself stays, and keeps the
            // keyboard; SwiftUI's opacity doesn't reach its AppKit view, so its colours fade instead.
            KeyframeAnimator(initialValue: 1.0, trigger: model.shellPrompt) { shown in
                let placeholder = placeholder(shell: model.shellPrompt)
                TextField(placeholder, text: Bindable(draft).text, prompt: Text(placeholder).foregroundStyle(Self.placeholderInk.opacity(shown)), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(model.shellPrompt ? Type.mono : Type.body)
                    .foregroundStyle(Ink.primary.opacity(shown))
                    .lineLimit(1...maxLines)
                    .focused($focused)
                    .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                        // In and out with the keyframes alone, not faded in by the move spring.
                        if shown < 1 { ghost.opacity(1 - shown).transition(.identity) }
                    }
                    // Here, where a key already redraws, rather than in the composer's body.
                    // A `!` at the start turns the composer into a shell prompt, as in Claude Code.
                    .onChange(of: text) { _, now in
                        if now != completed { completions = [] }
                        guard !model.shellPrompt, now.hasPrefix("!") else { return }
                        model.shellPrompt = true
                        text = String(now.dropFirst())
                    }
                    .onChange(of: slashQuery) { _, query in
                        slashSelected = 0
                        if query != nil, let chat = model.chat { model.loadCommands(for: chat) }
                    }
            } keyframes: { _ in
                MoveKeyframe(0)
                LinearKeyframe(1, duration: 0.18, timingCurve: .easeOut)
            }
            .id(field)
            // ⌫ in an empty prompt turns it back. The Backspace key sends DEL, 0x7F, which
            // isn't SwiftUI's .delete, 0x08.
            .onKeyPress(keys: [.delete, KeyEquivalent("\u{7F}")]) { _ in
                guard model.shellPrompt, text.isEmpty else { return .ignored }
                model.shellPrompt = false
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
                // The last message queued comes back to be edited before any sent before it.
                if text.isEmpty, !model.shellPrompt, let last = queue.last {
                    takeBack(last)
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
                // Which Return does what is Settings › Shortcuts' to say; the prompt has no queue.
                let action = model.shortcuts.returnPress(press.modifiers, working: working && !model.shellPrompt)
                if action == .queue {
                    sendAfterTurn()
                } else if action == .newLine {
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
            Isolated { sendButton }
        }
        // The prompt comes and goes with the move spring, or, with Reduce Motion, fades in place.
        .animation(reduceMotion ? nil : Motion.move, value: model.shellPrompt)
    }

    /// The field as it looked before the prompt turned, fading out as the field fades in.
    private var ghost: some View {
        Text(text.isEmpty ? placeholder(shell: !model.shellPrompt) : text)
            .font(model.shellPrompt ? Type.body : Type.mono)
            .foregroundStyle(text.isEmpty ? Self.placeholderInk : Ink.primary)
            .lineLimit(1...maxLines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
        // The queue's lines, their gap and padding count against the same 40%.
        let queued = queue.isEmpty ? 0 : queueHeight + 8
        return max(1, Int((maxHeight - 28 - queued) / 18))
    }

    /// At the shell prompt the button runs the command, whether or not a turn is running. Otherwise,
    /// while a turn runs, it sends what's typed into it and stops the turn when nothing is; a thread
    /// waiting on you from before a quit has no turn to send into, so it keeps Stop. ⌥Return queues
    /// what's typed for after the turn instead, which the help says.
    private var sendButton: some View {
        let stops = running && !model.shellPrompt && (!canSend || model.currentConversation?.waitingAfterQuit == true)
        return Button {
            if model.shellPrompt { runCommand() } else if stops { model.stop() } else { send() }
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
        .help(help(stops: stops))
        .accessibilityLabel(model.shellPrompt ? "Run" : stops ? "Stop" : "Send")
    }

    private func help(stops: Bool) -> String {
        let shortcuts = model.shortcuts
        let send = shortcuts.label(.send)
        if model.shellPrompt { return "Run (\(send))" }
        if stops { return "Stop (\(shortcuts.label(.stop)))" }
        return working ? "Send now (\(send)), or after this turn (\(shortcuts.label(.queue)))" : "Send (\(send))"
    }

    private func placeholder(shell: Bool) -> String {
        guard shell else { return "Ask for a change" }
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
            field = UUID()
            try? await Task.sleep(for: .milliseconds(30))
            // A program that took the whole screen meanwhile, vim run as the first command, keeps it.
            if model.openShell == nil { focused = true }
        }
    }

    /// Tab: the slash command the list is on; again, the next of several matches; else the word
    /// being typed, as the user's shell would at the prompt, or a path after `@` in a message.
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
        // With no thread open, the project's folder.
        guard let folder = model.chat?.cwd ?? model.project?.path else { return }
        guard model.shellPrompt else {
            apply(ShellCompletion.mention(text, folder: folder))
            return
        }
        let line = text
        Task { @MainActor in
            let result = await model.completeCommand(line, in: folder)
            // Typed on while the shell answered: that Tab is stale.
            guard text == line else { return }
            apply(result)
        }
    }

    private func apply(_ result: ShellCompletion.Result?) {
        guard let result else { return }
        completed = result.text
        text = result.text
        if !result.candidates.isEmpty {
            completionHead = result.head
            completionIndex = nil
            completionNotes = result.descriptions
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
            if case .user(_, let text, _, _) = item { text } else { nil }
        } ?? []
        // What the app sent for you isn't yours to send again.
        return sent.filter { $0 != AppModel.quitLine && !$0.hasSuffix(AppModel.limitLineEnd) }
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
        !draft.blank || !model.draftAttachments.isEmpty
    }

    private func send() {
        guard canSend else { return }
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

    /// A turn running, or messages sent into one still to run.
    private var working: Bool {
        running || model.currentConversation?.waiting.isEmpty == false
    }

    /// ⌥Return while the thread works: what's typed fades into the queue's lines.
    private func sendAfterTurn() {
        guard canSend, model.queue(text) else { return }
        text = ""
        recalled = nil
        rebuild(after: false)
    }
}

@Observable
private final class Draft {
    var text = "" {
        didSet {
            let blank = text.allSatisfy(\.isWhitespace)
            if blank != self.blank { self.blank = blank }
        }
    }
    /// Nothing but spaces and newlines. The send button reads this rather than the text, so it's
    /// drawn again when this changes, not at every key.
    private(set) var blank = true
}

/// Its content drawn in a body of its own, so what only the content reads redraws it alone.
private struct Isolated<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

/// One queued message: a click takes it back into the field, and the cross at its end drops it.
private struct QueuedLine: View {
    let message: QueuedMessage
    let editable: Bool
    let takeBack: () -> Void
    let remove: () -> Void
    @State private var hovered = false
    @State private var removeHovered = false

    static let height: CGFloat = 28

    var body: some View {
        HStack(spacing: 2) {
            Button(action: takeBack) {
                HStack(spacing: 8) {
                    Image(systemName: message.images.isEmpty ? "arrow.turn.down.right" : "photo")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.faint)
                        .frame(width: 14)
                    Text(message.line)
                        .font(Type.secondary)
                        .foregroundStyle(hovered ? Ink.primary : Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .frame(height: Self.height)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!editable)
            .onHover { hovered = $0 && editable }
            .help("Edit")
            .accessibilityLabel("Edit queued message: \(message.line)")
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(removeHovered ? Ink.primary : Ink.faint)
                    .frame(width: 24, height: 24)
                    .background(removeHovered ? Surface.hover : .clear, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .onHover { removeHovered = $0 }
            .help("Remove")
            .accessibilityLabel("Remove queued message")
        }
        .padding(.trailing, 2)
        .background(hovered ? Surface.hover : .clear, in: .rect(cornerRadius: 10, style: .continuous))
        .animation(Motion.fade, value: hovered)
        .animation(Motion.fade, value: removeHovered)
    }
}
