import SwiftUI

/// The review as it was before Witness, kept whole: what the working tree changes, told the way
/// the thread went. Each of your messages, then what it changed, in the order it changed it;
/// then what no edit here made.
struct LegacyReview: View {
    var body: some View {
        ReviewFrame(design: .legacy) { ReviewScroll() }
    }
}

/// The chapters, flattened into rows so a long review only lays out what's on screen.
private struct ReviewScroll: View {
    @Environment(AppModel.self) private var model
    /// How many rows are made. A hunk is a row, and each costs a frame or more of text layout, so
    /// the first two, the chapter and its file, come with the panel and the rest one to a frame after; a row asked for
    /// by the keyboard is made at once.
    @State private var made = 2

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
                    ForEach(Array(rows.prefix(made))) { row in
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
                made = .max
                withAnimation(Motion.move) { proxy.scrollTo(selected) }
            }
            .task {
                while made < rows.count {
                    try? await Task.sleep(for: .milliseconds(17))
                    made += 1
                }
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
struct FileHeader: View {
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
                    if let ray = section.ray { RayLabel(ray: ray) }
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
