import SwiftUI

/// ⌘⇧D, or the button at the top right: what the working tree changes, told the way the thread
/// went. Each of your messages, then what it changed, in the order it changed it; then what no
/// edit here made. It stretches down out of the title capsule and keeps up with Claude while
/// it's open.
struct ReviewPanel: View {
    static let width: CGFloat = 960
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @FocusState private var focused: Bool

    var body: some View {
        let review = model.review
        VStack(spacing: 0) {
            ReviewHeader()
            if let problem = review.problem, review.diff == nil {
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
                ReviewScroll()
            }
            ReviewFooter()
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
        .onAppear { model.review.placeFiles() }
        .onChange(of: review.noting) { _, noting in
            if noting == nil { focused = true }
        }
        .onChange(of: review.focusTick) {
            focused = true
        }
        .task {
            try? await Task.sleep(for: .milliseconds(60))
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
            // The file the keyboard is in, folded under it or not.
            guard let unit = model.review.book.units.first(where: { $0.id == model.review.selected }) else { return .ignored }
            model.review.setOpen(unit.section, press.key == .rightArrow)
        case .space:
            model.toggleSelectedReviewed()
        case .return where press.modifiers.contains(.command):
            guard model.review.busy == nil, !model.review.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .ignored }
            model.commitReview(reviewedOnly: ReviewFooter.reviewedOnly(model.review.book))
        case "n":
            guard let unit = model.review.selectedUnit else { return .ignored }
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
private struct ReviewHeader: View {
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
            if review.loading {
                ProgressView().controlSize(.mini)
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

/// The chapters, flattened into rows so a long review only lays out what's on screen.
private struct ReviewScroll: View {
    @Environment(AppModel.self) private var model

    private enum Row: Identifiable {
        case chapter(ReviewChapter)
        case folded(ReviewChapter)
        case file(ReviewFileSection)
        /// A hunk of an open file, which knows whether it's the file's only one and its last.
        case unit(ReviewUnit, alone: Bool, last: Bool)

        var id: String {
            switch self {
            case .chapter(let chapter): "c:" + chapter.id
            case .folded(let chapter): "f:" + chapter.id
            case .file(let section): "s:" + section.id
            case .unit(let unit, _, _): unit.id
            }
        }
    }

    private var rows: [Row] {
        let review = model.review
        var rows: [Row] = []
        for chapter in review.book.chapters {
            rows.append(.chapter(chapter))
            if review.folded(chapter) {
                rows.append(.folded(chapter))
                continue
            }
            for section in chapter.files {
                rows.append(.file(section))
                if review.openFiles.contains(section.id) {
                    rows += section.units.map { .unit($0, alone: section.units.count == 1, last: $0.id == section.units.last?.id) }
                }
            }
        }
        return rows
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .chapter(let chapter):
                            ChapterHeader(chapter: chapter)
                        case .folded(let chapter):
                            FoldedChapter(chapter: chapter)
                        case .file(let section):
                            FileHeader(section: section)
                        case .unit(let unit, let alone, let last):
                            UnitView(unit: unit, alone: alone)
                                .padding(.horizontal, 4)
                                .padding(.top, 4)
                                .padding(.bottom, last ? 4 : 0)
                                .background(Surface.card, in: .fileCard(bottom: last))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.review.selected) { _, selected in
                guard let selected else { return }
                withAnimation(Motion.move) { proxy.scrollTo(selected) }
            }
        }
    }
}

/// Your message, the way the transcript shows it, over what it changed; or, for what no edit
/// here made, a line saying so.
private struct ChapterHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let chapter: ReviewChapter
    @State private var hovering = false

    var body: some View {
        let units = chapter.units
        VStack(alignment: .trailing, spacing: 6) {
            if let prompt = chapter.prompt {
                Text(prompt)
                    .font(Type.body)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Surface.userMessage, in: .rect(cornerRadius: 18, style: .continuous))
                    .frame(maxWidth: 560, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(prompt)
            } else if model.review.book.threadEdited {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not from this thread's edits")
                        .font(Type.body)
                        .foregroundStyle(Ink.primary)
                    Text("No edit in this thread shows these changes: they're yours, a command's, or another thread's.")
                        .font(Type.secondary)
                        .foregroundStyle(Ink.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Since the last commit")
                    .font(Type.body)
                    .foregroundStyle(Ink.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                if !chapter.checks.isEmpty {
                    Checks(checks: chapter.checks)
                }
                Spacer()
                if hovering {
                    let open = units.filter { !$0.reviewed }
                    Button(open.isEmpty ? "Unmark" : "Mark Reviewed") { model.setReviewed(open.isEmpty ? units : open, open.isEmpty ? false : true) }
                    Button(chapter.turn == nil ? "Take Back All" : "Take Back This Turn") {
                        model.takeBack(units, label: chapter.turn == nil ? "Take Back All" : "Take Back Turn", undoManager: undoManager)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(Type.secondary)
            .foregroundStyle(Ink.secondary)
            .frame(height: 16)
        }
        .padding(.top, 18)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// The builds and tests a turn ran, with a mark for the ones that failed: what was checked
/// before you look, and what wasn't.
private struct Checks: View {
    let checks: [Provenance.Check]

    var body: some View {
        HStack(spacing: 6) {
            Text("Ran").foregroundStyle(Ink.faint)
            ForEach(checks.prefix(4), id: \.self) { check in
                HStack(spacing: 3) {
                    Text(Self.short(check.command))
                        .font(Type.mono)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                    Image(systemName: check.failed ? "xmark" : "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(check.failed ? Ink.primary : Ink.faint)
                }
                .help(check.failed ? "\(check.command)\nIt failed." : check.command)
            }
            if checks.count > 4 { Text("and \(checks.count - 4) more").foregroundStyle(Ink.faint) }
        }
        .font(Type.secondary)
    }

    /// The command without the cd in front and cut to a glance.
    static func short(_ command: String) -> String {
        let last = command.components(separatedBy: "&&").last?.trimmingCharacters(in: .whitespaces) ?? command
        let line = last.split(separator: "\n").first.map(String.init) ?? last
        return line.count > 36 ? String(line.prefix(35)) + "…" : line
    }
}

private struct FoldedChapter: View {
    @Environment(AppModel.self) private var model
    let chapter: ReviewChapter

    var body: some View {
        let units = chapter.units
        Button {
            _ = model.review.unfolded.insert(chapter.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                Text("Reviewed · \(chapter.files.count) \(chapter.files.count == 1 ? "file" : "files")")
                Counts(added: units.reduce(0) { $0 + $1.added }, deleted: units.reduce(0) { $0 + $1.deleted }, quiet: true)
                    .opacity(0.6)
                Spacer()
            }
            .font(Type.secondary)
            .foregroundStyle(Ink.faint)
            .frame(height: 26)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A file's path, what happened to it, and its counts for this chapter. A click shows its hunks
/// or folds the file to this line; its circle, in the column of its hunks' circles, marks them all.
/// Open, it's the top of the file's card, with its hunks under it.
private struct FileHeader: View {
    @Environment(AppModel.self) private var model
    let section: ReviewFileSection
    @State private var hovering = false

    var body: some View {
        let file = section.file
        let folder = (file.path as NSString).deletingLastPathComponent
        let open = model.review.openFiles.contains(section.id)
        let reviewed = section.units.allSatisfy(\.reviewed)
        HStack(spacing: 6) {
            Button {
                model.review.toggle(section, all: NSEvent.modifierFlags.contains(.option))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(hovering ? Ink.secondary : Ink.faint)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    if let status = Self.status(file) {
                        Text(status).foregroundStyle(file.status == "D" ? Ink.deleted : file.isNew ? Ink.added : Ink.faint)
                    }
                    HStack(spacing: 0) {
                        if !folder.isEmpty { Text(folder + "/").foregroundStyle(Ink.faint) }
                        Text((file.path as NSString).lastPathComponent).foregroundStyle(Ink.primary)
                    }
                    .font(Type.mono)
                    .lineLimit(1)
                    .truncationMode(.head)
                    Counts(added: section.units.reduce(0) { $0 + $1.added }, deleted: section.units.reduce(0) { $0 + $1.deleted }, quiet: true)
                        .opacity(0.8)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(open ? "Fold this file (←); ⌥-click folds every file" : "Unfold this file (→); ⌥-click unfolds every file")
            if hovering, file.status != "D" {
                Button("Open") { model.openFile(file.path) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.secondary)
                    .help("Open \(file.path) (O)")
            }
            Button {
                model.toggleReviewed(section)
            } label: {
                Image(systemName: reviewed ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.secondary)
            .help(reviewed ? "Mark this file not reviewed" : "Mark this file reviewed and go on to the next")
        }
        .font(Type.secondary)
        .padding(.horizontal, 16)
        .frame(minHeight: 32)
        .background(open ? Surface.card : .clear, in: .fileCard(top: true))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .padding(.top, 8)
    }

    static func status(_ file: FileDiff) -> String? {
        switch file.status {
        case "?", "A": "new"
        case "D": "deleted"
        case "R": file.oldPath.map { "from \($0) ·" } ?? "renamed"
        case "T": "type changed"
        default: nil
        }
    }
}

private extension Shape where Self == UnevenRoundedRectangle {
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
private struct UnitView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let unit: ReviewUnit
    /// The file's only hunk, whose circle would say what the header's does.
    let alone: Bool
    @State private var hovering = false

    /// Past this many lines a hunk shows its start until asked, so one new file can't stall the list.
    private static let long = 400

    var body: some View {
        let review = model.review
        let selected = review.selected == unit.id
        if review.folded(unit) {
            Button {
                review.selected = unit.id
                review.unfolded.insert(unit.id)
            } label: {
                HStack(spacing: 6) {
                    if unit.reviewed {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                    } else {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    Text(unit.lockfile && !unit.reviewed ? "lockfile" : unit.hunk.map { Self.place($0) } ?? "Reviewed")
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
                    Image(systemName: unit.reviewed ? "checkmark.circle.fill" : "circle")
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
private struct LineRow: View {
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
private struct NoteCard: View {
    @Environment(AppModel.self) private var model
    let note: ReviewNote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "text.bubble").foregroundStyle(Ink.faint)
            Text(note.text)
                .foregroundStyle(Ink.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.removeNote(note)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.faint)
            .help("Remove this note")
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
private struct NoteEditor: View {
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
private struct ReviewFooter: View {
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
            if !review.notes.isEmpty {
                HStack(spacing: 10) {
                    Text("\(review.notes.count) \(review.notes.count == 1 ? "note" : "notes") to send")
                        .foregroundStyle(Ink.primary)
                    Spacer()
                    Button("Discard") { withAnimation(Motion.move) { review.notes.removeAll() } }
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
                    Button(review.writing ? "Writing…" : "Write Message") { model.writeReviewMessage(reviewedOnly: reviewedOnly) }
                        .disabled(review.writing)
                        .help("Haiku writes a message from the diff")
                        .buttonStyle(.action)
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
