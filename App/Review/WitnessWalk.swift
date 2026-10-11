import AppKit
import SwiftUI

/// Where the keyboard is in Witness, by what outlasts a read: the file and the line its change
/// starts at. A change the thread edits again comes back as another hunk, and the keyboard
/// goes to the nearest one there.
struct ReviewPlace: Hashable, Sendable {
    let path: String
    let line: Int

    init(path: String, line: Int) {
        self.path = path
        self.line = line
    }

    init(_ unit: ReviewUnit) {
        self.init(path: unit.file.path, line: unit.hunk?.newStart ?? 0)
    }

    /// The change in the place's file that starts nearest its line, or nil when the file has none.
    func nearest(in units: [ReviewUnit]) -> ReviewUnit? {
        units.filter { $0.file.path == path }.min { abs(($0.hunk?.newStart ?? 0) - line) < abs(($1.hunk?.newStart ?? 0) - line) }
    }
}

extension ReviewState {
    /// ↑↓ and J K in Witness: the next change on the page, or a run's row where one stands
    /// between two. A row is walked onto for what → opens on it, and nothing marks it.
    func walk(_ step: Int) {
        let units = visibleUnits
        let changes = Set(units.map(\.id))
        let stops = page.walk.filter { changes.contains($0) || page.run($0) != nil }
        guard let selected, let index = stops.firstIndex(of: selected) else {
            select((step > 0 ? units.first { !$0.reviewed } : units.last { !$0.reviewed }) ?? units.first)
            return
        }
        guard stops.indices.contains(index + step) else { return }
        let next = stops[index + step]
        if let unit = units.first(where: { $0.id == next }) { select(unit) } else { self.selected = next }
    }

    /// Tab and ⇧Tab: the first change of the next file's line on the page, or of the one before.
    /// False when there is none that way, and the key is the window's to move on with.
    @discardableResult
    func walkFile(_ step: Int) -> Bool {
        let units = visibleUnits
        guard !units.isEmpty else { return false }
        let line = { (unit: ReviewUnit) in self.page.lineOf[unit.id] }
        // From a run's row: the first change under it, or the top of the file's line over it.
        if page.run(selected) != nil, let at = page.walk.firstIndex(of: selected ?? "") {
            let change = { (id: String) in units.first { $0.id == id } }
            if step > 0 {
                guard let next = page.walk[(at + 1)...].lazy.compactMap(change).first else { return false }
                select(next)
            } else {
                guard let before = page.walk[..<at].reversed().lazy.compactMap(change).first else { return false }
                select(units.first { line($0) == line(before) } ?? before)
            }
            return true
        }
        guard let index = units.firstIndex(where: { $0.id == selected }) else {
            select(units.first)
            return true
        }
        let here = line(units[index])
        if step > 0 {
            guard let next = units[(index + 1)...].first(where: { line($0) != here }) else { return false }
            select(next)
            return true
        }
        // Back: to the top of this line when the keyboard is below it, else to the line before's.
        let top = units.firstIndex { line($0) == here } ?? index
        if top == index {
            guard top > 0 else { return false }
            let before = line(units[top - 1])
            select(units[units.firstIndex { line($0) == before } ?? top - 1])
        } else {
            select(units[top])
        }
        return true
    }

    /// Whether → has something to open on a change: a line that needs no reading, or a removal
    /// long enough to be one row.
    func opens(_ unit: ReviewUnit) -> Bool {
        page.isQuiet(unit.id) || !WitnessHunk.removals(in: unit.lines, words: unit.words).isEmpty
    }

    /// Esc, before it closes the review: what → opened under the keyboard closes first.
    func closeOpened() -> Bool {
        guard design == .witness, let selected, unfolded.contains(selected),
              page.run(selected) != nil || book.units.first(where: { $0.id == selected }).map(opens) == true
        else { return false }
        unfolded.remove(selected)
        return true
    }
}

extension AppModel {
    /// ⇧Space: marks every change of the file the keyboard is in and goes on to the next
    /// change not reviewed; with all of them marked, unmarks them.
    func toggleFileReviewed(of unit: ReviewUnit? = nil) {
        guard let unit = unit ?? review.selectedUnit else { return }
        let units = review.visibleUnits
        let same = { (other: ReviewUnit) in other.file.path == unit.file.path && other.file.status == unit.file.status }
        let open = units.filter { same($0) && !$0.reviewed }
        guard !open.isEmpty else { return setReviewed(units.filter(same), false) }
        let index = units.firstIndex { $0.id == unit.id } ?? 0
        let next = (units[index...] + units[..<index]).first { !$0.reviewed && !same($0) }
        setReviewed(open, true)
        review.select(next ?? unit)
    }

    /// A click in a change's number column: marks it or unmarks it, and the keyboard comes to it.
    func markByClick(_ unit: ReviewUnit) {
        setReviewed([unit], !unit.reviewed)
        review.selected = unit.id
        review.focusTick += 1
    }

    /// O: the change's file, at the line it starts. The review makes way and keeps its place.
    func openAtLine(_ unit: ReviewUnit) {
        guard !unit.file.status.hasPrefix("D") else { return }
        review.selected = unit.id
        openFile(unit.file.path, line: WitnessHunk.line(of: unit))
    }

    /// T: the review makes way and the thread shows the edit behind a change, lit for a moment;
    /// on a run's row, the command. The review opened again is where it was.
    func showInThread(_ unit: ReviewUnit? = nil) {
        let change = unit ?? review.selectedUnit
        guard let item = change.map(edit(behind:)) ?? review.page.run(review.selected).flatMap(item(of:)) else { return }
        if let unit { review.selected = unit.id }
        closeReview()
        reveal = item
    }

    /// The transcript's item that shows the edit behind a change, when the thread has one.
    func edit(behind unit: ReviewUnit) -> UUID? {
        review.page.accounts[unit.id]?.edit
    }

    /// The transcript's item a run was: the thread's own call or a command of yours. A
    /// subagent's command has none.
    private func item(of run: Provenance.Run) -> UUID? {
        guard let chat else { return nil }
        switch run.source {
        case .shell(let id): return id
        case .call(let call):
            return conversation(for: chat).items.first { if case .tool(_, let made) = $0 { made.toolUseId == call } else { false } }?.id
        case nil: return nil
        }
    }

    /// What a run printed, as it is stored: a call's result, or a command of yours as its
    /// terminal left it.
    func printed(by run: Provenance.Run) -> String? {
        guard let chat else { return nil }
        let conversation = conversation(for: chat)
        switch run.source {
        case .call(let id):
            for case .tool(_, let call) in conversation.items where call.toolUseId == id { return call.result }
            return conversation.under.values.joined().first { $0.toolUseId == id }?.result
        case .shell(let id):
            guard case .shell(_, let block)? = conversation.items.first(where: { $0.id == id }) else { return nil }
            return ShellRender.plain(ShellRender.lines(ShellRender.replay(block.output)))
        case nil:
            return nil
        }
    }

    /// A: the note's field opens already asking for the check again, to be changed or sent as
    /// it is. Nothing goes until Send. On a run's row the note is on the first change that
    /// changed after the run.
    func askAgain(from unit: ReviewUnit? = nil) {
        let page = review.page
        let row = unit == nil && review.selectedUnit == nil ? page.run(review.selected) : nil
        let units = review.visibleUnits
        let under = row.flatMap { run in units.first { page.changedAfter[run.check]?.contains($0.file.path) == true } ?? units.first }
        guard let target = unit ?? review.selectedUnit ?? under, review.noting != target.id,
              let line = page.askAgain(for: target.file.path, on: row)
        else { return }
        review.noteStart = line
        note(on: target)
    }

    /// The change's lines to the pasteboard, signed as a diff has them.
    func copy(_ unit: ReviewUnit) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(unit.lines.map(\.signed).joined(separator: "\n"), forType: .string)
    }

    func note(on unit: ReviewUnit) {
        review.selected = unit.id
        // A line that needs no reading opens for its note.
        if review.page.isQuiet(unit.id) { review.unfolded.insert(unit.id) }
        review.noting = unit.id
    }

    /// A turn as a menu names it: its message's first words, never its number.
    static func turnName(_ chapter: ReviewChapter) -> String {
        chapter.prompt.map(WitnessPage.firstWords) ?? "Changes no edit here made"
    }
}

/// What can be done with a change, as menu items: the context menu's on a right-click and the
/// header's "…" for the change under the keyboard. Each has its key beside it as a badge, which
/// is where the keys are learned. They are no shortcuts of the menu's own: a menu's letter would
/// be taken from whatever field is being typed in, and the review's keys are the review's.
struct WitnessActions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let unit: ReviewUnit?

    var body: some View {
        let review = model.review
        Group {
            Button(unit?.reviewed == true ? "Mark Not Reviewed" : "Mark Reviewed") {
                if let unit { model.toggleReviewed(unit) }
            }
            .badge(Text("Space"))
            Button("Mark File Reviewed") { model.toggleFileReviewed(of: unit) }
                .badge(Text("⇧Space"))
            Button("Note") {
                if let unit { model.note(on: unit) }
            }
            .badge(Text("N"))
            Button("Take Back") {
                if let unit { model.takeBack([unit], label: "Take Back", undoManager: undoManager) }
            }
            .badge(Text("⌫"))
            Button("Open at Line") {
                if let unit { model.openAtLine(unit) }
            }
            .badge(Text("O"))
            .disabled(unit?.file.status.hasPrefix("D") ?? true)
            Button("Copy") {
                if let unit { model.copy(unit) }
            }
            .disabled(unit?.hunk == nil)
            Button("Show in Thread") { model.showInThread(unit) }
                .badge(Text("T"))
                .disabled(unit.flatMap(model.edit(behind:)) == nil)
            Button("Ask for the Check Again") { model.askAgain(from: unit) }
                .badge(Text("A"))
                .disabled(review.page.runs.isEmpty)
            if let unit, review.opens(unit) {
                let open = review.unfolded.contains(unit.id)
                Button(open ? "Close" : review.page.isQuiet(unit.id) ? "Open" : "Show Removed Lines") {
                    review.selected = unit.id
                    if open { review.unfolded.remove(unit.id) } else { review.unfolded.insert(unit.id) }
                }
                .badge(Text(open ? "←" : "→"))
            }
        }
        .disabled(unit == nil)
    }
}
