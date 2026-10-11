import SwiftUI

/// Witness: the same book as Legacy, opened on the changes to read first. Under the header one
/// sentence says what ran and what has changed since; then Read first, each file's line saying
/// why it's there; the runs; what last changed before them, in the order the thread first
/// touched the files; and last what needs no reading, a line each.
struct WitnessReview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // A review opened again has its place, and every row is there to scroll to it.
        ReviewFrame(design: .witness) {
            VStack(spacing: 0) {
                WitnessScroll(placed: model.review.selected != nil)
                WitnessCaption()
            }
        }
    }
}

/// The page as rows, so a long one only lays out what's on screen.
private struct WitnessScroll: View {
    @Environment(AppModel.self) private var model
    /// How many rows are made: the sentence, a heading and a file's line with the panel, then one
    /// to a frame while they fill the first screen, as Legacy makes its own, and then all the
    /// rest at once, which the lazy stack lays out only as they come into view. A row to a frame
    /// to the end costs a long page a frame's work for every row it has.
    @State private var made: Int
    /// How many plain characters a line of code has room for, which says what can't wrap.
    @State private var columns = 100
    private static let firstScreen = 16
    private static let side: CGFloat = 16

    init(placed: Bool) {
        _made = State(initialValue: placed ? .max : 3)
    }

    private enum Row: Identifiable {
        case sentence(String)
        case heading(String)
        /// A file's line, with the lines its changes under it add and take out.
        case file(WitnessPage.FileLine, added: Int, deleted: Int)
        /// A change under its file's line, and what that line has already said of it.
        case unit(ReviewUnit, said: [String])
        case run(Provenance.Run, below: String?)
        case quiet(WitnessPage.Quiet, ReviewUnit)

        var id: String {
            switch self {
            case .sentence: "sentence"
            case .heading(let text): "h:" + text
            case .file(let line, _, _): line.id
            case .unit(let unit, _): unit.id
            case .run(let run, _): WitnessPage.id(of: run)
            case .quiet(_, let unit): unit.id
            }
        }
    }

    private var rows: [Row] {
        let review = model.review
        let page = review.page
        let units = Dictionary(review.book.units.map { ($0.id, $0) }) { first, _ in first }
        var rows: [Row] = [.sentence(page.sentence)]
        func add(_ lines: [WitnessPage.FileLine]) {
            for line in lines {
                let shown = line.units.compactMap { units[$0] }
                guard !shown.isEmpty else { continue }
                rows.append(.file(line, added: shown.reduce(0) { $0 + $1.added }, deleted: shown.reduce(0) { $0 + $1.deleted }))
                // With one change under it, the line's reasons are that change's, and its caption needn't repeat them.
                rows += shown.map { .unit($0, said: shown.count == 1 ? line.reasons : []) }
            }
        }
        if page.queued { rows.append(.heading("Read first · \(page.first) of \(page.total) changes")) }
        // With nothing under them, the runs come first: there is no "before" to head.
        if page.rest.isEmpty { rows += page.runs.map { .run($0, below: nil) } }
        add(page.readFirst)
        if !page.rest.isEmpty {
            rows += page.runs.map { .run($0, below: $0 == page.runs.last ? page.below : nil) }
            add(page.rest)
        }
        let quiet = page.quiet.compactMap { line in units[line.id].map { Row.quiet(line, $0) } }
        if !quiet.isEmpty {
            rows.append(.heading("Spacing, moves and lockfiles"))
            rows += quiet
        }
        return rows
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.prefix(made))) { row in
                        switch row {
                        case .sentence(let text):
                            Text(text)
                                .font(Type.body)
                                .foregroundStyle(Ink.primary)
                                .textSelection(.enabled)
                                .padding(.horizontal, 4)
                                .padding(.top, 2)
                                .padding(.bottom, 6)
                        case .heading(let text):
                            Text(text)
                                .font(Type.secondary)
                                .foregroundStyle(Ink.secondary)
                                .padding(.horizontal, 4)
                                .padding(.top, 16)
                        case .file(let line, let added, let deleted):
                            FileLine(line: line, added: added, deleted: deleted)
                        case .unit(let unit, let said):
                            WitnessUnit(unit: unit, digits: model.review.page.digits, columns: columns, said: said)
                                .padding(.bottom, 4)
                        case .run(let run, let below):
                            RunRow(run: run, below: below)
                        case .quiet(let line, let unit):
                            QuietRow(line: line, unit: unit, digits: model.review.page.digits, columns: columns)
                        }
                    }
                }
                .padding(.horizontal, Self.side)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
            .onGeometryChange(for: Int.self) { geometry in
                // A scroller that is always there takes its width from the page.
                let scroller = NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
                return Int((geometry.size.width - scroller - Self.side * 2 - WitnessHunk.codeX(model.review.page.digits) - 12) / WitnessHunk.advance) - 1
            } action: { columns = max(20, $0) }
            .onAppear {
                guard let selected = model.review.selected else { return }
                proxy.scrollTo(selected, anchor: .center)
            }
            .onChange(of: model.review.selected) { _, selected in
                guard let selected else { return }
                made = .max
                withAnimation(Motion.move) { proxy.scrollTo(selected) }
            }
            .onChange(of: model.review.noting) { _, noting in
                // A from a run's row writes on a change that can be a screen away, and the field
                // is where the keyboard goes: it's brought into view once its row has it.
                guard let noting else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    withAnimation(Motion.move) { proxy.scrollTo(noting) }
                }
            }
            .onChange(of: model.review.unfolded) { _, unfolded in
                // What a line opens can lie under the page's end: it's brought into view once laid out.
                guard let selected = model.review.selected, unfolded.contains(selected) else { return }
                Task {
                    withAnimation(Motion.move) { proxy.scrollTo(selected) }
                }
            }
            .task {
                while made < min(rows.count, Self.firstScreen) {
                    try? await Task.sleep(for: .milliseconds(17))
                    made += 1
                }
                made = .max
            }
        }
    }
}

/// A file's line: what happened to it, its path, and in words why its changes are read first.
private struct FileLine: View {
    let line: WitnessPage.FileLine
    let added: Int
    let deleted: Int

    var body: some View {
        let file = line.file
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(words)
                .font(Type.body)
                .lineLimit(2)
                .help(([file.path] + line.reasons).joined(separator: "\n"))
            Spacer(minLength: 8)
            if let aside = line.aside {
                Text(aside)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            Counts(added: added, deleted: deleted, quiet: true)
                .opacity(0.8)
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var words: AttributedString {
        var text = AttributedString()
        func add(_ words: String, _ ink: Color) {
            var part = AttributedString(words)
            part.foregroundColor = ink
            text.append(part)
        }
        // A deleted file's reason is the word itself.
        if line.file.status != "D", let status = FileHeader.status(line.file) {
            add(status + " ", line.file.status == "D" ? Ink.deleted : line.file.isNew ? Ink.added : Ink.secondary)
        }
        add(line.file.path, Ink.primary)
        for reason in line.reasons {
            add(" · ", Ink.secondary)
            add(reason, Ink.primary)
        }
        return text
    }
}

/// A run's own row: what ran and how it ended, when its ending was its own. It heads what last
/// changed before it and says nothing of the code.
private struct RunRow: View {
    @Environment(AppModel.self) private var model
    let run: Provenance.Run
    let below: String?

    var body: some View {
        let review = model.review
        let id = WitnessPage.id(of: run)
        let open = review.unfolded.contains(id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                review.selected = id
                if open { review.unfolded.remove(id) } else { review.unfolded.insert(id) }
                review.focusTick += 1
            } label: {
                row(selected: review.selected == id)
            }
            .buttonStyle(.plain)
            .help(open ? "Close it (←)" : "The end of what it printed (→)")
            if open { RunOutput(run: run) }
        }
        .padding(.top, 14)
    }

    private func row(selected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // In a narrow review the command gives way first, so how it ended is never cut.
            (Text("Ran ").foregroundStyle(Ink.secondary)
                + Text(Self.line(run.command)).font(Type.mono).foregroundStyle(Ink.primary))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(run.command)
            (Text(" · ").foregroundStyle(Ink.secondary)
                + Text(WitnessPage.result(run)).foregroundStyle(Ink.primary))
                .lineLimit(1)
                .layoutPriority(2)
            Spacer(minLength: 16)
            if let below {
                Text(below)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .font(Type.secondary)
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Surface.selected : Surface.hover, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
    }

    /// The command on one line, as it was typed.
    static func line(_ command: String) -> String {
        command.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "; ")
    }
}

/// The end of what a run printed, as it is stored: its last twelve lines and nothing made of them.
private struct RunOutput: View {
    @Environment(AppModel.self) private var model
    let run: Provenance.Run
    @State private var printed: (lines: [String], of: Int)?
    @State private var read = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let printed, !printed.lines.isEmpty {
                if printed.of > printed.lines.count {
                    Text("the last \(printed.lines.count) of the \(printed.of) lines it printed")
                        .foregroundStyle(Ink.faint)
                }
                Text(printed.lines.joined(separator: "\n"))
                    .font(Type.mono)
                    .foregroundStyle(Ink.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if read {
                Text(printed == nil ? "What it printed isn't kept." : "It printed nothing.")
                    .foregroundStyle(Ink.faint)
            }
        }
        .font(Type.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .task(id: run) {
            printed = model.printed(by: run).map { WitnessPage.tail(of: $0) }
            read = true
        }
    }
}

/// Under the page, what the thread says of the change the keyboard is on: which it is, the
/// message that asked for it, its file's edits and the runs between, a worker's name, and what
/// the agent said before the edit, in quotes and as its own word. It is there for that one
/// change, orders nothing, and stands beside no run's result.
struct WitnessCaption: View {
    @Environment(AppModel.self) private var model
    /// The change it tells of, which follows the keyboard a frame behind: laid out in the frame
    /// of the key press itself, it put the page's own layout in that frame too.
    @State private var told: String?

    var body: some View {
        let review = model.review
        // A stack, there with nothing in it too: the task is its own.
        VStack(spacing: 0) {
            if let told, let account = review.page.accounts[told] {
                words(account)
            }
        }
        .task(id: review.selected) { told = review.selected }
    }

    @ViewBuilder
    private func words(_ account: WitnessPage.Account) -> some View {
        let review = model.review
        let worker = account.ray.map { ray in model.providers.first { $0.id == ray.agent }?.name ?? ray.agent }
        let words = Self.words(account, of: review.page.total, worker: worker)
        VStack(alignment: .leading, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    Text(words).lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                    if account.edit != nil {
                        Text("T shows the edit in the thread").foregroundStyle(Ink.faint).fixedSize()
                    }
                }
                // In a narrow review it takes the lines it needs: what it says of the file is the last of it.
                Text(words)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let said = account.said {
                Text("the agent said, before this edit “\(said)”")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(said)
            }
        }
        .font(Type.secondary)
        .foregroundStyle(Ink.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A surface of its own, so the code the page cuts off above it isn't read into it.
        .background(Surface.card, in: .rect(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    /// The caption's first line.
    static func words(_ account: WitnessPage.Account, of total: Int, worker: String?) -> String {
        var parts = ["Change \(account.number) of \(total)"]
        parts.append(account.asked.map { "asked by “\($0)”" } ?? "no edit in this thread made it")
        if let edits = account.edits { parts.append("its file was \(edits)") }
        if let worker, let ray = account.ray { parts.append(ray.label.isEmpty ? "\(worker)'s worker" : "\(worker)'s worker, \(ray.label)") }
        return parts.joined(separator: " · ")
    }
}

/// A change that needs no reading: one line saying what it is, until → or a click opens it.
private struct QuietRow: View {
    @Environment(AppModel.self) private var model
    let line: WitnessPage.Quiet
    let unit: ReviewUnit
    let digits: Int
    let columns: Int

    var body: some View {
        let review = model.review
        let open = review.unfolded.contains(unit.id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                review.selected = unit.id
                if open { review.unfolded.remove(unit.id) } else { review.unfolded.insert(unit.id) }
                review.focusTick += 1
            } label: {
                HStack(spacing: 6) {
                    Text(line.path).lineLimit(1).truncationMode(.head)
                    Text("· " + line.what).lineLimit(1)
                    if unit.reviewed { Text("· reviewed") }
                    let notes = review.notes.count { $0.unit == unit.id }
                    if notes > 0, !open { Text(notes == 1 ? "· 1 note" : "· \(notes) notes") }
                    Counts(added: unit.added, deleted: unit.deleted, quiet: true).opacity(0.6)
                    Spacer()
                }
                .font(Type.secondary)
                .foregroundStyle(Ink.faint)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(review.selected == unit.id && !open ? Surface.selected : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(open ? "Close it (←)" : "Open it (→)")
            .contextMenu { if !open { WitnessActions(unit: unit) } }
            if open {
                WitnessUnit(unit: unit, digits: digits, columns: columns, said: [line.what])
            }
        }
    }
}

/// Witness's top row: the branch, how much changed, the file the keyboard is in with the
/// page's others behind it, and everything else behind "…".
struct WitnessHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let review = model.review
        let book = review.book
        let files = review.page.files
        HStack(spacing: 8) {
            // The buttons keep their words. What's left of the row goes to the branch, which
            // gives way in its middle, then goes, and the counts go after it.
            ViewThatFits(in: .horizontal) {
                place(branch: .infinity)
                place(branch: 320)
                place(branch: 200)
                place(branch: 110)
                place(branch: nil)
                place(branch: nil, counts: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if review.loading || review.asking {
                ProgressView().controlSize(.mini)
            }
            if !files.isEmpty {
                Menu(Self.place(of: review.selectedUnit, in: files)) {
                    ForEach(files, id: \.first) { entry in
                        Button(entry.file.path) {
                            review.select(book.units.first { $0.id == entry.first })
                            review.focusTick += 1
                        }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.action(small: true))
                .fixedSize()
                .help("The file the keyboard is in, and the others (Tab, ⇧Tab)")
                Menu {
                    WitnessActions(unit: review.selectedUnit)
                    Divider()
                    Button("Ask for a Review") { model.askForReview() }
                        .disabled(review.asking)
                    Button("Mark All Reviewed") { model.setReviewed(book.units.filter { !$0.reviewed }, true) }
                        .disabled(book.toReview == 0)
                    Menu("Mark Reviewed by Turn") {
                        ForEach(book.chapters) { chapter in
                            Button(AppModel.turnName(chapter)) { model.setReviewed(chapter.units.filter { !$0.reviewed }, true) }
                                .disabled(chapter.units.allSatisfy(\.reviewed))
                        }
                    }
                    Menu("Take Back by Turn") {
                        ForEach(book.chapters) { chapter in
                            Button(AppModel.turnName(chapter)) {
                                model.takeBack(chapter.units, label: chapter.turn == nil ? "Take Back All" : "Take Back Turn", undoManager: undoManager)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.action(small: true))
                .fixedSize()
                .help("What can be done with the change under the keyboard, and with all of them")
                .accessibilityLabel("More")
            }
            Button("Close") { model.closeReview() }
                .buttonStyle(.action(small: true))
                .fixedSize()
                .help("Close the review (⌘⇧D)")
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    /// The row's words: Review, the branch in as much width as it's given, and the counts.
    private func place(branch width: CGFloat?, counts: Bool = true) -> some View {
        let book = model.review.book
        return HStack(spacing: 8) {
            Text("Review")
                .font(Type.body.weight(.medium))
                .foregroundStyle(Ink.primary)
            if let width, let info = model.currentBranch {
                Text(info.branch).font(Type.mono).foregroundStyle(Ink.secondary)
                    .truncationMode(.middle)
                    .frame(maxWidth: width, alignment: .leading)
                    .help(info.branch)
                if info.ahead > 0 { Text("↑\(info.ahead)").font(Type.mono).foregroundStyle(Ink.faint) }
            }
            if counts, !book.units.isEmpty {
                Counts(added: book.added, deleted: book.deleted, quiet: true).opacity(0.8)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: width == .infinity || width == nil, vertical: false)
    }

    /// "RootView.swift · 1 of 9": the keyboard's file among the page's, or how many there are.
    static func place(of unit: ReviewUnit?, in files: [(file: FileDiff, first: String)]) -> String {
        guard let unit, let index = files.firstIndex(where: { $0.file.path == unit.file.path && $0.file.status == unit.file.status }) else {
            return files.count == 1 ? "1 file" : "\(files.count) files"
        }
        return "\((unit.file.path as NSString).lastPathComponent) · \(index + 1) of \(files.count)"
    }
}
