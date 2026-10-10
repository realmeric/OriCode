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
    /// Tab and ⇧Tab: the first change of the next file's line on the page, or of the one before.
    /// False when there is none that way, and the key is the window's to move on with.
    @discardableResult
    func walkFile(_ step: Int) -> Bool {
        let units = visibleUnits
        guard !units.isEmpty else { return false }
        guard let index = units.firstIndex(where: { $0.id == selected }) else {
            select(units.first)
            return true
        }
        let line = { (unit: ReviewUnit) in self.page.lineOf[unit.id] }
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
              let unit = book.units.first(where: { $0.id == selected }), opens(unit)
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
        guard let prompt = chapter.prompt else { return "Changes no edit here made" }
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard line.count > 48 else { return line.isEmpty ? "A message with no words" : line }
        let cut = line.prefix(48)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
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
