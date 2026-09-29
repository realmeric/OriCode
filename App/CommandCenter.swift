import SwiftUI

/// ⌘K, the command center: every command the app has, its threads and projects, and lists and
/// lines to type one level down. Arrows move, Return runs, Tab opens a level, Esc or ⌫ in an
/// empty field goes back one, and Esc at the top closes it.
struct CommandCenter: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    /// What has been built since it opened: nothing but the glass, then the field, then some rows,
    /// a screenful, and the rest. SwiftUI takes some 40ms to make all of it, so it comes in a part
    /// to a frame, behind the glass, which shows none of it until it has begun to grow. The arrows
    /// go straight to the last.
    @State private var stage = 0
    /// The level's rows, made by `remake` and not by the body: they read the threads, the
    /// commands and the model's own state, and the body ran them all again for any change once it
    /// had gone, on the frame that closes it.
    @State private var made: [Line] = []
    private static let last = 6
    /// How many lines each stage shows.
    private static let lines = [0, 0, 4, 8, 12, 16]

    static let width: CGFloat = 560
    private static let row: CGFloat = 30
    private static let heading: CGFloat = 26
    /// About twelve rows, and past that it scrolls.
    private static let tallest: CGFloat = 380
    /// The field's row, so what stands in for it is as tall.
    private static let header: CGFloat = 41

    private enum Line: Identifiable {
        case heading(String)
        case item(PaletteItem, index: Int)

        var id: String {
            switch self {
            case .heading(let title): "heading." + title
            case .item(let item, _): item.id
            }
        }
    }

    var body: some View {
        let palette = model.palette
        let level = palette.level
        let all = stage >= 2 ? made : []
        let lines = stage >= Self.last ? all : Array(all.prefix(Self.lines[stage]))
        let items = all.compactMap { line -> PaletteItem? in
            if case .item(let item, _) = line { return item }
            return nil
        }
        VStack(alignment: .leading, spacing: 0) {
            if stage < 1 {
                Color.clear.frame(height: Self.header)
            } else {
                field(level, palette: palette, items: items)
            }
            if let status = status(of: level) {
                HStack(spacing: 6) {
                    if palette.busy != nil { ProgressView().controlSize(.mini) }
                    Text(status)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
            if stage < 2 {
                Color.clear.frame(height: Self.tallest)
            } else if !lines.isEmpty {
                list(lines, height: height(of: all), selected: level.selected)
            }
        }
        .padding(.bottom, lines.isEmpty && stage >= 2 ? 0 : 6)
        .animation(Motion.fade, value: status(of: level))
        // The field isn't in the window until the slide-in starts, so focus it a beat later.
        .task {
            for next in 1..<Self.last {
                try? await Task.sleep(for: .milliseconds(17))
                stage = next
                if next == 2 { remake() }
            }
            try? await Task.sleep(for: .milliseconds(9))
            focused = true
            try? await Task.sleep(for: .milliseconds(300))
            stage = Self.last
        }
    }

    /// Makes the rows for the level being shown, and again when anything they read changes while
    /// it's up.
    private func remake() {
        let model = model
        made = withObservationTracking {
            lines(for: model.palette.level)
        } onChange: {
            DispatchQueue.main.async { if model.commandCenterShown { remake() } }
        }
    }

    /// The field, and the level's title before it when it's a level down.
    private func field(_ level: PaletteState.Level, palette: PaletteState, items: [PaletteItem]) -> some View {
        HStack(spacing: 6) {
            if let title = title(of: level) {
                Text(title + " ›")
                    .font(.system(size: 16))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize()
            }
            TextField(placeholder(of: level), text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(Ink.primary)
                .focused($focused)
                // One handler for the four keys: each modifier is a node SwiftUI makes on open.
                .onKeyPress(phases: [.down, .repeat]) { press in
                    switch press.key {
                    case .downArrow:
                        stage = Self.last
                        move(1, in: items)
                    case .upArrow:
                        stage = Self.last
                        move(-1, in: items)
                    case .tab:
                        // Opens a row's level, and otherwise stays put rather than take the
                        // keyboard out of the field.
                        if items.indices.contains(level.selected), items[level.selected].opensLevel {
                            model.activate(items[level.selected])
                        }
                    // The Backspace key sends DEL, 0x7F, which isn't SwiftUI's .delete, 0x08.
                    case .delete, KeyEquivalent("\u{7F}"):
                        guard level.query.isEmpty, palette.stack.count > 1 else { return .ignored }
                        _ = palette.pop()
                    default:
                        return .ignored
                    }
                    return .handled
                }
                .onSubmit { run(level, items) }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.header)
    }

    /// A scroll view of lazy rows rather than a List: a List makes an outline view with its own
    /// scroll view and reads every row's identity as it opens, which was most of ⌘K's first
    /// frame. The rows draw their own selection and are all one height, so it gives up nothing.
    private func height(of lines: [Line]) -> CGFloat {
        lines.reduce(CGFloat(8)) { total, line in
            if case .heading = line { return total + Self.heading }
            return total + Self.row
        }
    }

    private func list(_ lines: [Line], height: CGFloat, selected: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        switch line {
                        case .heading(let title):
                            Text(title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Ink.faint)
                                .padding(.horizontal, 8)
                                .frame(height: Self.heading, alignment: .bottomLeading)
                        case .item(let item, let index):
                            row(item, selected: index == selected) {
                                model.palette.level.selected = index
                                model.activate(item)
                            }
                            .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 3)
                .padding(.bottom, 5)
            }
            .frame(height: min(height, Self.tallest))
            .onChange(of: selected) { _, index in
                let items = lines.compactMap { line -> PaletteItem? in
                    if case .item(let item, _) = line { return item }
                    return nil
                }
                if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
            }
        }
    }

    private func row(_ item: PaletteItem, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let project = item.project, item.kind != .message {
                    ProjectBadge(project: project)
                } else if let agent = item.agent {
                    AgentMark(agent: agent)
                        .frame(width: 14, height: 14)
                        .frame(width: 22)
                } else {
                    Image(systemName: item.icon ?? "command")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.faint)
                        .frame(width: 22)
                }
                Text(item.title)
                    .font(Type.body)
                    .foregroundStyle(item.unavailable == nil ? Ink.primary : Ink.faint)
                    .lineLimit(1)
                    .layoutPriority(1)
                if item.kind == .message, let project = item.project {
                    ProjectBadge(project: project)
                }
                if let line = item.unavailable ?? item.subtitle {
                    Text(line)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if item.checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                }
                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.faint)
                }
                if item.opensLevel {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Ink.faint)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Self.row)
            .background(selected ? Surface.selected : .clear, in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - What each level shows

    private var query: Binding<String> {
        Binding {
            model.palette.level.query
        } set: { text in
            model.palette.level.query = text
            model.palette.level.selected = 0
            model.palette.problem = nil
        }
    }

    private func lines(for level: PaletteState.Level) -> [Line] {
        var index = 0
        func numbered(_ items: [PaletteItem]) -> [Line] {
            items.map { item in
                defer { index += 1 }
                return .item(item, index: index)
            }
        }
        switch level.kind {
        case .root:
            if level.query.trimmingCharacters(in: .whitespaces).isEmpty {
                return model.paletteSections().flatMap { section in [.heading(section.title)] + numbered(section.items) }
            }
            let messages = model.paletteMessages(for: level.query)
            // Fewer ranked rows over messages, so the Messages heading is still in view.
            let ranked = numbered(Array(Palette.rank(model.paletteSearchable(), by: level.query, recents: model.paletteRecents)
                .prefix(messages.isEmpty ? 40 : 6)))
            return messages.isEmpty ? ranked : ranked + [.heading("Messages")] + numbered(messages)
        case .list(let list):
            var items = Palette.rank(level.items, by: level.query, recents: model.paletteRecents)
            let typed = level.query.trimmingCharacters(in: .whitespaces)
            let named = level.items.contains { list.typedFirst ? $0.title == typed : $0.title.caseInsensitiveCompare(typed) == .orderedSame }
            if !typed.isEmpty, !named, let made = list.typed?(typed) {
                if list.typedFirst { items.insert(made, at: 0) } else { items.append(made) }
            } else if list.typedFirst, let exact = items.firstIndex(where: { $0.title == typed }) {
                items.insert(items.remove(at: exact), at: 0)
            }
            return numbered(items)
        case .input:
            return []
        }
    }

    private func title(of level: PaletteState.Level) -> String? {
        switch level.kind {
        case .root: nil
        case .list(let list): list.title
        case .input(let input): input.title
        }
    }

    private func placeholder(of level: PaletteState.Level) -> String {
        switch level.kind {
        case .root: "Search commands, threads, projects and messages"
        case .list(let list): list.placeholder
        case .input(let input): input.placeholder
        }
    }

    /// One line under the field: what's running, what went wrong, or the hint for what's typed.
    private func status(of level: PaletteState.Level) -> String? {
        if let busy = model.palette.busy { return busy }
        if let problem = model.palette.problem { return problem }
        if case .list = level.kind, level.loading { return "Loading…" }
        if case .input(let input) = level.kind {
            switch input.hint(level.query) {
            case .none: return nil
            case .info(let line), .problem(let line): return line
            }
        }
        return nil
    }

    private func move(_ by: Int, in items: [PaletteItem]) {
        guard !items.isEmpty else { return }
        model.palette.level.selected = min(max(model.palette.level.selected + by, 0), items.count - 1)
    }

    private func run(_ level: PaletteState.Level, _ items: [PaletteItem]) {
        if case .input(let input) = level.kind {
            model.submit(input, text: level.query.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if items.indices.contains(level.selected) {
            model.activate(items[level.selected])
        }
    }
}
