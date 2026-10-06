import AppKit
import SwiftUI

struct Composer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let running: Bool
    let windowHeight: CGFloat
    /// What's typed, in an object of its own: the body never reads it, so a key redraws only the
    /// few views below that do.
    @State private var draft = Draft()
    @State private var slashSelected = 0
    @State private var mentionSelected = 0
    /// Esc put the files away, until the word they were for is done with.
    @State private var mentionOff = false
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
    /// The picker in the tree, which leaves a turn after model.modelPickerShown does.
    @State private var cardShown = false
    /// Whether the queue's lines are scrolled to the last, which leaves nothing below to fade into.
    @State private var queueAtEnd = true

    /// The tallest picker, its gap and the 52pt title bar: with less room than this above the
    /// composer, the picker opens below it.
    static let pickerRoom: CGFloat = 380
    /// The title bar's 52pt and a gap under it, which the picker stays clear of when it rises.
    private static let pickerTop: CGFloat = 62
    /// The gap the picker keeps from the window's foot when it drops below.
    private static let pickerFoot: CGFloat = 16
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
        // Before the picker and the menus: every change inside the view a drop target is on
        // gathers its drop preferences again, which the picker's page turns paid on every frame.
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTarget) { providers in
            accept(providers)
        }
        // The finger is on the trackpad for the whole drag, so this says "let go here".
        .onChange(of: dropTarget) { _, over in
            if over { Haptics.detent() }
        }
        // The model button's picker rises out of the composer's right end, the way the slash
        // menu rises out of its left; with the composer in the middle of an empty thread there
        // isn't room above it under the title bar, so it drops below instead.
        .overlay(alignment: top < Self.pickerRoom ? .topTrailing : .bottomTrailing) {
            if cardShown {
                let below = top < Self.pickerRoom
                let anchor: UnitPoint = below ? .topTrailing : .bottomTrailing
                // The Rays page grows past the effort page's height, so the card is held to the
                // room the window has on its side of the composer, and the list scrolls in it.
                let room = below ? windowHeight - top - height - 10 - Self.pickerFoot : top - 10 - Self.pickerTop
                PickerCard(chat: model.chat, room: room, below: below)
                    .padding(below ? .top : .bottom, height + 10)
                    // It rises by itself, a turn after it's built.
                    .transition(.asymmetric(insertion: .identity,
                                            removal: .scale(scale: 0.97, anchor: anchor).combined(with: .opacity).animation(Motion.fade)))
            }
        }
        .onChange(of: model.modelPickerShown) { _, shown in
            guard !shown else {
                cardShown = true
                return
            }
            // The field takes the keyboard back while the card still stands, and the card fades
            // from the next turn, so the fade's first frame isn't the one that moves the keyboard.
            draft.keyboard(model.composerTakesKeyboard)
            DispatchQueue.main.async {
                if !model.modelPickerShown { cardShown = false }
            }
        }
        .overlay(alignment: .bottomLeading) {
            // Reads only what a key seldom changes, so typing redraws nothing here.
            Isolated {
                ZStack(alignment: .bottomLeading) {
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
                    } else if !mentionMatches.isEmpty {
                        MentionMenu(paths: mentionMatches, selected: min(mentionSelected, mentionMatches.count - 1)) { mention($0) }
                            .frame(maxWidth: 520, alignment: .leading)
                            .padding(.bottom, height + 8)
                            .transition(.opacity)
                    }
                }
                // An `@` starting the last word lists the project's files, read as it's typed.
                .onChange(of: draft.at) { before, word in
                    mentionSelected = 0
                    if word == nil { mentionOff = false }
                    // As the word begins, typed or pasted whole.
                    if before == nil, word != nil, !model.shellPrompt, let folder = model.chat?.cwd ?? model.project?.path {
                        model.loadProjectFiles(in: folder)
                    }
                }
                // Esc puts the files away as it does Tab's list.
                .onChange(of: completions.isEmpty && mentionMatches.isEmpty) { _, none in model.composerMenu = !none }
                // Typing anything but what Tab left puts its list away; only watched while there is one.
                .onChange(of: completions.isEmpty ? 0 : draft.edits) {
                    if !completions.isEmpty, text != completed { completions = [] }
                }
                // A `!` at the start turns the composer into a shell prompt, as in Claude Code, once
                // there's a project for the command to run in.
                .onChange(of: draft.bang) { _, bang in
                    guard bang, !model.shellPrompt, model.project != nil else { return }
                    model.shellPrompt = true
                    text = String(text.dropFirst())
                }
                .onChange(of: slashQuery) { _, query in
                    slashSelected = 0
                    if query != nil, let chat = model.chat { model.loadCommands(for: chat) }
                }
            }
        }
        // Esc puts the list away before anything else hears it.
        .onChange(of: model.composerMenu) { _, shown in
            guard !shown else { return }
            completions = []
            if draft.at != nil { mentionOff = true }
        }
        .onChange(of: model.shellPrompt) { _, prompt in
            completions = []
            recalled = nil
            // Tab at the prompt wants the shell's commands; asked once, as the prompt opens.
            if prompt { model.loadShellCommands() }
        }
        .onAppear {
            draft.keyboard(model.composerTakesKeyboard)
            cardShown = model.modelPickerShown
        }
        // Not while a block is open, which has the keyboard until it goes.
        .onChange(of: model.composerFocus) {
            if model.openShell == nil { draft.keyboard(true) }
        }
        // While Claude waits on a card, the card owns Return and Esc; the field would eat them.
        .onChange(of: waitingAsk?.requestId) { _, waiting in
            if waiting != nil {
                draft.keyboard(false)
            } else if !model.keyboardTaken {
                draft.keyboard(model.composerTakesKeyboard)
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
                    QueuedLine(message: message, editable: !model.shellPrompt, sendNow: canSteer ? { model.sendQueuedNow(message.id) } : nil) {
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

    /// Whether the thread's agent takes a message while it works, which Send now needs, and has a
    /// turn to take it into: none runs in a thread waiting from before a quit.
    private var canSteer: Bool {
        guard model.currentConversation?.waitingAfterQuit != true else { return false }
        return model.chat.map { model.agent(for: $0).capabilities.steer } ?? false
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
        draft.keyboard(true)
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
                    Task { @MainActor in attach(url) }
                }
            } else if offers.attachments, provider.canLoadObject(ofClass: NSImage.self) {
                took = true
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in model.attach([image]) }
                }
            }
        }
        return took
    }

    /// A picture goes among the attachments when the agent takes pictures; any other file, a folder
    /// or a PDF, is named in the message, for the agent to open with its own tools.
    private func attach(_ url: URL) {
        if !model.shellPrompt, offers.attachments, model.attach(fileAt: url) { return }
        guard url.isFileURL else { return }
        text = Self.naming(url, from: model.namingFolder, in: text, shell: model.shellPrompt)
    }

    /// The file's path at the end of the message as a mention, from the thread's folder when it's
    /// inside it; at the prompt, as a word the shell reads whole.
    nonisolated static func naming(_ url: URL, from folder: String, in text: String, shell: Bool = false) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let root = folder.hasSuffix("/") ? folder : folder + "/"
        let shown = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
        let gap = text.isEmpty || text.last?.isWhitespace == true ? "" : " "
        if shell {
            let plain = shown.allSatisfy { $0.isLetter || $0.isNumber || "/._-+~".contains($0) }
            return text + gap + (plain ? shown : "'" + shown.replacing("'", with: "'\\''") + "'") + " "
        }
        return text + gap + (shown.contains(where: \.isWhitespace) ? "@\"\(shown)\"" : "@" + shown) + " "
    }

    /// Images and files dropped on the field's text.
    private func accept(_ board: NSPasteboard) -> Bool {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            urls.forEach(attach)
            return true
        }
        guard offers.attachments, let images = board.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty else { return false }
        model.attach(images)
        return true
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
                let font = model.shellPrompt ? ComposerTextView.mono : ComposerTextView.body
                let baseline = Alignment(horizontal: .leading, vertical: .firstTextBaseline)
                let underTop = ComposerTextView.baseline(font)
                ComposerField(draft: draft, placeholder: placeholder, font: font, shown: shown, maxLines: maxLines, keys: keys)
                    .frame(height: draft.height)
                    .alignmentGuide(.firstTextBaseline) { _ in underTop }
                    .background(alignment: baseline) {
                        if draft.empty {
                            Text(placeholder)
                                .font(model.shellPrompt ? Type.mono : Type.body)
                                .foregroundStyle(Self.placeholderInk.opacity(shown))
                                .lineLimit(1)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .overlay(alignment: baseline) {
                        // In and out with the keyframes alone, not faded in by the move spring.
                        if shown < 1 { ghost.opacity(1 - shown).transition(.identity) }
                    }
            } keyframes: { _ in
                MoveKeyframe(0)
                LinearKeyframe(1, duration: 0.18, timingCurve: .easeOut)
            }
            .padding(.vertical, 9)
            .padding(.leading, model.shellPrompt ? 0 : 14)
            HStack(spacing: 4) {
                attachButton
                ModelMenu(chat: model.chat)
                if offers.usage { UsageGlass(chat: model.chat) }
            }
            .frame(height: 36)
            Isolated { sendButton }
        }
        // The prompt comes and goes with the move spring, or, with Reduce Motion, fades in place.
        .animation(reduceMotion ? nil : Motion.move, value: model.shellPrompt)
    }

    /// The keys the field hands the composer.
    private var keys: ComposerKeys {
        ComposerKeys(
            enter: enter,
            up: {
                if !slashMatches.isEmpty {
                    slashSelected = max(slashSelected - 1, 0)
                    return true
                }
                if !completions.isEmpty {
                    tab(backward: true)
                    return true
                }
                if !mentionMatches.isEmpty {
                    mentionSelected = max(min(mentionSelected, mentionMatches.count - 1) - 1, 0)
                    return true
                }
                // The last message queued comes back to be edited before any sent before it.
                if text.isEmpty, !model.shellPrompt, let last = queue.last {
                    takeBack(last)
                    return true
                }
                return recall(older: true)
            },
            down: {
                if !slashMatches.isEmpty {
                    slashSelected = min(slashSelected + 1, slashMatches.count - 1)
                    return true
                }
                if !completions.isEmpty {
                    tab(backward: false)
                    return true
                }
                if !mentionMatches.isEmpty {
                    mentionSelected = min(mentionSelected + 1, mentionMatches.count - 1)
                    return true
                }
                return recall(older: false)
            },
            tab: tab,
            // ⌫ in an empty prompt turns it back.
            delete: {
                guard model.shellPrompt, text.isEmpty else { return false }
                model.shellPrompt = false
                return true
            },
            drop: { accept($0) },
            dropping: { dropTarget = $0 })
    }

    /// Return: Settings › Shortcuts says whether it sends, queues or breaks the line. The prompt has
    /// no queue.
    private func enter(_ modifiers: EventModifiers) {
        completions = []
        let action = model.shortcuts.returnPress(modifiers, working: working && !model.shellPrompt)
        if action == .queue {
            sendAfterTurn()
        } else if action == .newLine {
            // Where the caret is: at the start it pushes the text down.
            draft.newLine()
        } else if model.shellPrompt {
            runCommand()
        } else if let command = selectedSlash, text != "/" + command.name {
            complete(command)
        } else if let path = selectedMention, draft.at != path {
            mention(path)
        } else if !canSend, let ask = waitingPermission {
            model.answer(ask, allow: true)
        } else {
            send()
        }
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

    /// The native panel for files; they go in the way a paste or a drop does.
    private var attachButton: some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            // No folder's own folder is empty and deep in Library: there the panel opens where it last was.
            if let folder = model.workingFolder, !model.inNoFolder { panel.directoryURL = URL(filePath: folder) }
            panel.prompt = "Attach"
            guard panel.runModal() == .OK else { return }
            panel.urls.forEach(attach)
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
        .help("Attach a file")
        .accessibilityLabel("Attach a file")
    }

    private var maxHeight: CGFloat { windowHeight * 0.4 }

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
        guard working else { return "Send (\(send))" }
        return offers.steer ? "Send now (\(send)), or after this turn (\(shortcuts.label(.queue)))" : "Send after this turn (\(send))"
    }

    /// What the thread's agent can do, or the next thread's.
    private var offers: ProviderInfo.Capabilities {
        model.agent(for: model.chat).capabilities
    }

    private func placeholder(shell: Bool) -> String {
        guard shell else { return "Ask for a change" }
        // No folder by its name, not its folder's.
        if model.inNoFolder { return "A command for " + Project.noFolderName }
        return "A command for " + (model.chat.map { URL(filePath: $0.cwd).lastPathComponent } ?? model.project?.name ?? "the project")
    }

    private func runCommand() {
        guard canSend else { return }
        model.rememberCommand(text)
        model.runCommand(text)
        text = ""
        recalled = nil
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
        if let path = selectedMention {
            mention(path)
            return
        }
        // With no thread open, the project's folder, and with no project where No folder would be.
        let folder = model.namingFolder
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
        model.shellPrompt ? nil : draft.slash
    }

    private var slashMatches: [SlashCommandInfo] {
        guard let query = slashQuery, let chat = model.chat, let commands = model.slashCommands[chat.providerID]?[chat.cwd] else { return [] }
        return Array(Fuzzy.rank(commands, by: query) { $0.name }.prefix(8))
    }

    private var selectedSlash: SlashCommandInfo? {
        let matches = slashMatches
        return matches.isEmpty ? nil : matches[min(slashSelected, matches.count - 1)]
    }

    private func complete(_ command: SlashCommandInfo) {
        text = "/" + command.name + ((command.hint ?? "").isEmpty ? "" : " ")
    }

    /// The project's files that match the word after an `@`, best first; a path from the root or
    /// from home isn't the project's, and Tab completes it.
    private var mentionMatches: [String] {
        guard !model.shellPrompt, !mentionOff, let word = draft.at, !word.hasPrefix("/"), !word.hasPrefix("~") else { return [] }
        return Array(Fuzzy.rank(model.projectFiles, by: word) { $0 }.prefix(8))
    }

    private var selectedMention: String? {
        let matches = mentionMatches
        return matches.isEmpty ? nil : matches[min(mentionSelected, matches.count - 1)]
    }

    /// The file's path in place of the word being typed, as the agent reads a mention.
    private func mention(_ path: String) {
        text = Self.mentioning(path, in: text)
    }

    nonisolated static func mentioning(_ path: String, in text: String) -> String {
        let start = text.lastIndex(where: \.isWhitespace).map(text.index(after:)) ?? text.startIndex
        return text[..<start] + (path.contains(where: \.isWhitespace) ? "@\"\(path)\"" : "@" + path) + " "
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
        // The first message moves the composer from the middle of an empty thread to the bottom.
        var sent = false
        withAnimation(Motion.glide) { sent = model.send(text) }
        guard sent else { return }
        text = ""
        recalled = nil
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
    }
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
    /// Sends it into the turn; nil for an agent that takes nothing mid-turn.
    let sendNow: (() -> Void)?
    let takeBack: () -> Void
    let remove: () -> Void
    @State private var hovered = false
    @State private var sendHovered = false
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
            if let sendNow {
                Button(action: sendNow) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(sendHovered ? Ink.primary : Ink.faint)
                        .frame(width: 24, height: 24)
                        .background(sendHovered ? Surface.hover : .clear, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .onHover { sendHovered = $0 }
                .help("Send now")
                .accessibilityLabel("Send queued message now")
            }
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
        .animation(Motion.fade, value: sendHovered)
        .animation(Motion.fade, value: removeHovered)
    }
}
