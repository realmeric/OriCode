import SwiftUI

/// What either review stands in: the header, its page of the book, the footer, and the keys. It
/// stretches down out of the title capsule and keeps up with Claude while it's open.
struct ReviewFrame<Page: View>: View {
    let design: ReviewDesign
    @ViewBuilder let page: Page
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @FocusState private var focused: Bool
    /// What has been made since it opened: nothing but the glass, then its top row, its bottom
    /// row and the middle. SwiftUI takes the better part of a second to lay out a screen of selectable
    /// code, so it comes in a part to a frame, behind the glass, which shows none of it until it
    /// has begun to grow.
    @State private var stage = 0

    var body: some View {
        let review = model.review
        VStack(spacing: 0) {
            if stage >= 1 { ReviewHeader() }
            if stage < 3 {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let problem = review.problem, review.diff == nil {
                Text(problem)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if review.diff == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if review.book.chapters.isEmpty {
                Text("Nothing has changed since the last commit.")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                page
            }
            if stage >= 2 { ReviewFooter() }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .space, .return, "j", "k", "n", "o"], phases: .down) { press in
            key(press)
        }
        // The Delete key reaches a focused view as the Delete command, never as a key press.
        .onDeleteCommand {
            guard model.review.noting == nil, let unit = model.review.selectedUnit else { return }
            model.takeBack([unit], label: "Take Back", undoManager: undoManager)
        }
        .onAppear {
            model.useReview(design)
            model.review.placeFiles()
        }
        .onChange(of: review.noting) { _, noting in
            if noting == nil { focused = true }
        }
        .onChange(of: review.focusTick) {
            focused = true
        }
        .task {
            for next in 1...3 {
                try? await Task.sleep(for: .milliseconds(17))
                stage = next
            }
            try? await Task.sleep(for: .milliseconds(9))
            focused = true
        }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard model.review.noting == nil else { return .ignored }
        switch press.key {
        case .downArrow, "j":
            model.review.move(1)
        case .upArrow, "k":
            model.review.move(-1)
        case .leftArrow, .rightArrow:
            // The file the keyboard is in, folded under it or not; in Witness, the line it's on.
            guard model.review.book.units.contains(where: { $0.id == model.review.selected }) else { return .ignored }
            model.review.open(press.key == .rightArrow)
        case .space:
            model.toggleSelectedReviewed()
        case .return where press.modifiers.contains(.command):
            guard model.review.busy == nil, !model.review.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .ignored }
            model.commitReview(reviewedOnly: ReviewFooter.reviewedOnly(model.review.book))
        case "n":
            guard let unit = model.review.selectedUnit else { return .ignored }
            // A line closed under the keyboard in Witness opens for its note.
            if model.review.design == .witness { model.review.unfolded.insert(unit.id) }
            model.review.noting = unit.id
        case "o":
            guard let unit = model.review.selectedUnit, !unit.file.status.hasPrefix("D") else { return .ignored }
            model.openFile(unit.file.path)
        default:
            return .ignored
        }
        return .handled
    }
}

/// The review's top row: where you are, how much changed and how much is left to look at.
struct ReviewHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let review = model.review
        let book = review.book
        HStack(spacing: 8) {
            Text("Review")
                .font(Type.body.weight(.medium))
                .foregroundStyle(Ink.primary)
            if let info = model.currentBranch {
                Text(info.branch).font(Type.mono).foregroundStyle(Ink.secondary)
                if info.ahead > 0 { Text("↑\(info.ahead)").font(Type.mono).foregroundStyle(Ink.faint) }
            }
            if let diff = review.diff, !diff.files.isEmpty {
                Text("\(diff.files.count) \(diff.files.count == 1 ? "file" : "files")")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.faint)
                Counts(added: book.added, deleted: book.deleted, quiet: true)
                    .opacity(0.8)
                let left = book.toReview
                Text(left == 0 ? "all reviewed" : "\(left) to review")
                    .font(Type.secondary)
                    .foregroundStyle(left == 0 ? Ink.secondary : Ink.faint)
            }
            Spacer()
            if review.loading || review.asking {
                ProgressView().controlSize(.mini)
            }
            if let diff = review.diff, !diff.files.isEmpty {
                Button("Ask for a Review") { model.askForReview() }
                    .buttonStyle(.action(small: true))
                    .disabled(review.asking)
                    .help("The thread's agent reads the diff and comments on its lines. It joins no turn.")
            }
            if book.toReview > 0 {
                Button("Mark All Reviewed") { model.setReviewed(book.units.filter { !$0.reviewed }, true) }
                    .buttonStyle(.action(small: true))
            }
            Button("Close") { model.closeReview() }
                .buttonStyle(.action(small: true))
                .help("Close the review (⌘⇧D)")
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }
}

/// Which ray changed a file: the worker's agent mark and its task, faint beside the counts.
struct RayLabel: View {
    @Environment(AppModel.self) private var model
    let ray: Provenance.Ray

    var body: some View {
        let name = model.providers.first { $0.id == ray.agent }?.name ?? ray.agent
        HStack(spacing: 4) {
            AgentMark(agent: ray.agent)
                .frame(width: 10, height: 10)
                .opacity(0.7)
            Text(ray.label)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Ink.faint)
        .help("\(name)'s worker made these changes: \(ray.label)")
    }
}

extension Shape where Self == UnevenRoundedRectangle {
    /// A piece of a file's card, which the review's rows draw one at a time so a long file stays
    /// lazy: the header rounds the top, the last hunk the bottom, and the rows between are square.
    static func fileCard(top: Bool = false, bottom: Bool = false) -> Self {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: top ? 12 : 0, bottomLeading: bottom ? 12 : 0, bottomTrailing: bottom ? 12 : 0, topTrailing: top ? 12 : 0),
            style: .continuous)
    }
}

/// One hunk: its lines with both sides' numbers, the words that changed, where it came from,
/// and what you can do with it. Folded to one line once reviewed. It sits on its file's card,
/// lit when the keyboard is on it by the card's tint laid over again, as bright as Surface.selected.
struct UnitView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let unit: ReviewUnit
    /// The file's only hunk, whose circle would say what the header's does.
    let alone: Bool
    @State private var hovering = false

    /// Past this many lines a hunk shows its start until asked, so one new file can't stall the list.
    private static let long = 400

    /// Witness draws no tick, which elsewhere on its page would read as a run's word on the code;
    /// what you reviewed is a filled circle and the word.
    private var ticks: Bool { model.review.design == .legacy }

    var body: some View {
        let review = model.review
        let selected = review.selected == unit.id
        if review.folded(unit) {
            Button {
                review.selected = unit.id
                review.unfolded.insert(unit.id)
            } label: {
                HStack(spacing: 6) {
                    if unit.reviewed, ticks {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                    } else {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    Text(unit.lockfile && !unit.reviewed ? "lockfile" : (unit.reviewed && !ticks ? "reviewed · " : "") + (unit.hunk.map { Self.place($0) } ?? "Reviewed"))
                        .lineLimit(1)
                    Counts(added: unit.added, deleted: unit.deleted, quiet: true).opacity(0.6)
                    Spacer()
                }
                .font(Type.secondary)
                .foregroundStyle(Ink.faint)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(selected ? Surface.card : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header(selected: selected)
                if unit.hunk != nil {
                    lines
                } else {
                    Text(Self.whole(unit.file))
                        .font(Type.secondary)
                        .foregroundStyle(Ink.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                ForEach(review.notes.filter { $0.unit == unit.id }) { note in
                    NoteCard(note: note)
                }
                if review.noting == unit.id {
                    NoteEditor(unit: unit)
                }
            }
            .background(selected ? Surface.card : .clear, in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
            .onTapGesture {
                review.selected = unit.id
                review.focusTick += 1
            }
            .onHover { hovering = $0 }
        }
    }

    private func header(selected: Bool) -> some View {
        HStack(spacing: 8) {
            if let hunk = unit.hunk {
                Text(Self.place(hunk))
                    .font(Type.mono)
                    .foregroundStyle(Ink.faint)
                    .lineLimit(1)
            }
            if unit.changedSince {
                Text("changed since you reviewed it").foregroundStyle(Ink.secondary)
            }
            ForEach(unit.labels, id: \.self) { label in
                if Self.warning(label) {
                    Label(label, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Ink.primary)
                        .help("Worth a closer look: an agent can make a failing test pass by changing what it checks.")
                } else {
                    Text(label)
                        .foregroundStyle(label.hasSuffix("changed on the way") ? Ink.primary : Ink.secondary)
                        .help(label.hasSuffix("changed on the way") ? "The block moved and some of it changed too; the lines still lit are the ones that did." : "")
                }
            }
            Spacer(minLength: 0)
            if hovering || selected {
                Button {
                    model.review.noting = unit.id
                } label: {
                    Image(systemName: "text.bubble")
                }
                .help("Add a note (N)")
                Button {
                    model.takeBack([unit], label: "Take Back", undoManager: undoManager)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help(unit.file.revertsByHunk ? "Take this back out of the file (⌫)" : "Put the file back as it was at the last commit (⌫)")
            }
            if !alone {
                Button {
                    model.toggleReviewed(unit)
                } label: {
                    Image(systemName: unit.reviewed ? (ticks ? "checkmark.circle.fill" : "circle.fill") : "circle")
                }
                .help(unit.reviewed ? "Mark not reviewed (Space)" : "Mark reviewed (Space)")
            }
        }
        .buttonStyle(.plain)
        .font(Type.secondary)
        .foregroundStyle(Ink.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    @ViewBuilder
    private var lines: some View {
        let review = model.review
        // Colours drawn for exactly these lines, or none: a stale list could run past the end.
        let colours = review.colours[unit.colourKey].flatMap { $0.count == unit.lines.count ? $0 : nil }
        let words = unit.words
        let width = CGFloat(String(max(unit.hunk.map { $0.oldStart + $0.oldLines } ?? 0, unit.hunk.map { $0.newStart + $0.newLines } ?? 0)).count) * 7 + 14
        let whole = unit.lines.count <= Self.long || review.expanded.contains(unit.id)
        let shown = whole ? unit.lines.indices : unit.lines.indices.prefix(200)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown, id: \.self) { index in
                LineRow(line: unit.lines[index], code: colours?[index], words: words[index], gutter: width)
            }
            if !whole {
                Button("Show all \(unit.lines.count) lines") {
                    _ = review.expanded.insert(unit.id)
                }
                .buttonStyle(.plain)
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .padding(.bottom, 8)
    }

    /// The labels about a test, which get the triangle; a move out of a file named for tests
    /// doesn't.
    static func warning(_ label: String) -> Bool {
        Signals.testWarnings.contains(label)
    }

    /// Where a hunk's changes are, in the file as it is now or, for lines that only went, as it
    /// was; and the function or type git found them in.
    static func place(_ hunk: DiffHunk) -> String {
        let lines = ReviewBook.lines(of: hunk)
        let added = lines.filter { $0.kind == .added }.compactMap(\.new)
        let numbers = added.isEmpty ? lines.filter { $0.kind == .deleted }.compactMap(\.old) : added
        let range = switch (numbers.min(), numbers.max()) {
        case (let low?, let high?) where low == high: "line \(low)"
        case (let low?, let high?): "lines \(low)–\(high)"
        default: "line \(hunk.newStart)"
        }
        let context = hunk.context.trimmingCharacters(in: .whitespaces)
        return context.isEmpty ? range : "\(range) · \(context)"
    }

    /// What there is to say about a file the review can't show line by line.
    static func whole(_ file: FileDiff) -> String {
        if file.binary { return file.isNew ? "A new binary file." : file.status == "D" ? "A binary file, deleted." : "A binary file, changed." }
        if file.cut { return "Too large to show here: +\(file.added) −\(file.deleted). Open the file to read it." }
        if file.status == "R" { return "Renamed, with nothing inside changed." }
        if file.isNew { return "A new, empty file." }
        return "Its mode changed, and nothing inside it."
    }
}

/// A line of a hunk: its old and new numbers, its sign, and its code in colour, with the words
/// that changed lit.
struct LineRow: View {
    let line: ReviewLine
    let code: AttributedString?
    let words: [Range<Int>]?
    let gutter: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.old.map(String.init) ?? "")
                .frame(width: gutter, alignment: .trailing)
            Text(line.new.map(String.init) ?? "")
                .frame(width: gutter, alignment: .trailing)
            Group {
                if line.foreign {
                    Text("•").foregroundStyle(Ink.secondary)
                        .help("No edit in this thread made this line: it's yours, a command's, or another thread's.")
                } else {
                    Text(" ")
                }
            }
            .frame(width: 12)
            Text(sign)
                .foregroundStyle(line.moved ? Ink.faint : ink)
                .frame(width: 14, alignment: .leading)
            Text(styled)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Ink.faint)
        .padding(.trailing, 12)
        .padding(.vertical, 1)
        .background(line.moved ? tint.opacity(0.35) : tint)
        .opacity(line.seen ? 0.45 : line.moved ? 0.6 : 1)
        .help(line.seen ? "You saw this line when you reviewed the hunk before." : "")
    }

    private var sign: String {
        switch line.kind {
        case .context: " "
        case .added: "+"
        case .deleted: "−"
        }
    }

    private var ink: Color {
        switch line.kind {
        case .context: Ink.faint
        case .added: Ink.added
        case .deleted: Ink.deleted
        }
    }

    private var tint: Color {
        switch line.kind {
        case .context: .clear
        case .added: Ink.added.opacity(0.10)
        case .deleted: Ink.deleted.opacity(0.10)
        }
    }

    private var styled: AttributedString {
        var text = code ?? AttributedString(line.text)
        // A CRLF file's lines end in \r, which would draw as a break of its own.
        if text.unicodeScalars.last == "\r" { text.unicodeScalars.removeLast() }
        text.font = Type.mono
        if code == nil { text.foregroundColor = line.kind == .context ? Ink.secondary : Ink.primary }
        if line.noNewline { text.append(AttributedString(" ⏎̸", attributes: AttributeContainer().foregroundColor(Ink.faint))) }
        guard let words, line.kind != .context, !line.moved else { return text }
        let lit = (line.kind == .added ? Ink.added : Ink.deleted).opacity(0.28)
        let count = text.characters.count
        for range in words where range.upperBound <= count {
            let start = text.characters.index(text.startIndex, offsetBy: range.lowerBound)
            let end = text.characters.index(text.startIndex, offsetBy: range.upperBound)
            text[start..<end].backgroundColor = lit
        }
        return text
    }
}

/// A note you wrote on a hunk, waiting to go to Claude with the others.
struct NoteCard: View {
    @Environment(AppModel.self) private var model
    let note: ReviewNote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: note.suggested ? "sparkle" : "text.bubble").foregroundStyle(Ink.faint)
            Text(note.text)
                .foregroundStyle(note.suggested ? Ink.secondary : Ink.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if note.suggested {
                Button("Keep") { model.keepNote(note) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.primary)
                    .help("Keep it as a note of yours, to send back with the rest")
            }
            Button {
                model.removeNote(note)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.faint)
            .help(note.suggested ? "Dismiss this comment" : "Remove this note")
        }
        .font(Type.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Surface.userMessage, in: .rect(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

/// Where a note is written: Return keeps it, Esc lets it go.
struct NoteEditor: View {
    @Environment(AppModel.self) private var model
    let unit: ReviewUnit
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("A note about these lines", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Type.secondary)
                .foregroundStyle(Ink.primary)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit { model.addNote(on: unit, text: text) }
            Button("Add") { model.addNote(on: unit, text: text) }
                .buttonStyle(.action(prominent: true, small: true))
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Surface.userMessage, in: .rect(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .task {
            try? await Task.sleep(for: .milliseconds(40))
            focused = true
        }
    }
}

/// Notes waiting to go, what was just taken back, and the commit.
struct ReviewFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    /// Commit takes what's reviewed when some of it is and some isn't; otherwise everything.
    static func reviewedOnly(_ book: ReviewBook) -> Bool {
        let units = book.units
        return units.contains(where: \.reviewed) && units.contains { !$0.reviewed }
    }

    var body: some View {
        @Bindable var review = model.review
        let book = review.book
        let reviewedOnly = Self.reviewedOnly(book)
        let running = model.currentConversation?.running ?? false
        VStack(alignment: .leading, spacing: 8) {
            let notes = model.ownNotes
            if !notes.isEmpty {
                HStack(spacing: 10) {
                    Text("\(notes.count) \(notes.count == 1 ? "note" : "notes") to send")
                        .foregroundStyle(Ink.primary)
                    Spacer()
                    Button("Discard") { withAnimation(Motion.move) { review.notes.removeAll { !$0.suggested } } }
                    Button("Send") { model.sendNotes() }
                        .disabled(running)
                        .help(running ? "The thread is still working; send when it's done." : "Send the notes as your next message")
                }
                .font(Type.secondary)
                .buttonStyle(.action(small: true))
            }
            if let step = review.lastTakeback {
                HStack(spacing: 10) {
                    Text("Took that back.").foregroundStyle(Ink.secondary)
                    Button("Undo") { model.putBack(step, undoManager: undoManager) }
                        .disabled(review.busy != nil)
                        .buttonStyle(.plain)
                        .foregroundStyle(Ink.primary)
                        .help("Put it back (⌘Z)")
                    Spacer()
                }
                .font(Type.secondary)
            }
            if !book.units.isEmpty {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(reviewedOnly ? "Message for what you reviewed" : "Commit message", text: $review.message, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Type.body)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1...6)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Surface.card, in: .rect(cornerRadius: 10, style: .continuous))
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.contains(.command) else { return .ignored }
                            commit(reviewedOnly)
                            return .handled
                        }
                    if model.agent(for: model.chat).capabilities.commitMessage {
                        Button(review.writing ? "Writing…" : "Write Message") { model.writeReviewMessage(reviewedOnly: reviewedOnly) }
                            .disabled(review.writing)
                            .help("Haiku writes a message from the diff")
                            .buttonStyle(.action)
                    }
                    Button(reviewedOnly ? "Commit Reviewed" : "Commit") { commit(reviewedOnly) }
                        .buttonStyle(.action(prominent: true))
                        .disabled(!canCommit)
                        .help(reviewedOnly ? "Commit only the hunks you marked reviewed (⌘Return)" : "Commit every change here (⌘Return)")
                    // The other way to commit, beside the one ⌘Return takes: a menu of the same
                    // kind, since a menu drawn as the white button hides its arrow.
                    Menu {
                        if reviewedOnly {
                            Button("Commit All Changes") { commit(false) }
                        } else {
                            Button("Commit Reviewed Only") { commit(true) }
                                .disabled(!book.units.contains(where: \.reviewed))
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.action)
                    .fixedSize()
                    .disabled(!canCommit)
                    .help(reviewedOnly ? "Commit all changes instead" : "Commit only the hunks you marked reviewed")
                    .accessibilityLabel("Other ways to commit")
                    Button("Push") { model.pushReview() }
                        .disabled(review.busy != nil || (model.currentBranch.map { $0.upstream && $0.ahead == 0 } ?? true))
                        .buttonStyle(.action)
                }
            }
            if let busy = review.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(Ink.secondary)
                }
                .font(Type.secondary)
            } else if let problem = review.problem, review.diff != nil {
                Text(problem)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
    }

    private var canCommit: Bool {
        let review = model.review
        return review.busy == nil && !review.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commit(_ reviewedOnly: Bool) {
        guard canCommit else { return }
        model.commitReview(reviewedOnly: reviewedOnly)
    }
}

/// Top right, beside nothing: how much the working tree changes, and the way into the review.
struct ReviewButton: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let review = model.review
        let counts = review.folder != nil && review.folder == model.workingFolder ? review.counts : nil
        Button {
            model.toggleReview()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.forwardslash.minus")
                    .font(.system(size: 13))
                    .foregroundStyle(hovering || model.reviewShown ? Ink.primary : Ink.secondary)
                if let counts {
                    HStack(spacing: 4) {
                        if counts.added > 0 || counts.deleted == 0 { Text("+\(counts.added)").foregroundStyle(Ink.added) }
                        if counts.deleted > 0 { Text("−\(counts.deleted)").foregroundStyle(Ink.deleted) }
                    }
                    .font(Type.secondary.monospacedDigit())
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(hovering || model.reviewShown ? Surface.hover : .clear, in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(model.workingFolder == nil)
        .help(counts == nil ? "Review changes (⌘⇧D)" : "Review what changed since the last commit (⌘⇧D)")
        .accessibilityLabel("Review changes")
    }
}
