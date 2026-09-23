import SwiftUI

/// ⌘K, the command center: every command the app has, its threads and projects, and lists and
/// lines to type one level down. Arrows move, Return runs, Tab opens a level, Esc or ⌫ in an
/// empty field goes back one, and Esc at the top closes it.
struct CommandCenter: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    private static let row: CGFloat = 30
    private static let heading: CGFloat = 26
    /// About twelve rows, and past that it scrolls.
    private static let tallest: CGFloat = 380

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
        let lines = lines(for: level)
        let items = lines.compactMap { line -> PaletteItem? in
            if case .item(let item, _) = line { return item }
            return nil
        }
        VStack(alignment: .leading, spacing: 0) {
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
                    .onKeyPress(.downArrow) {
                        move(1, in: items)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        move(-1, in: items)
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        guard items.indices.contains(level.selected), items[level.selected].opensLevel else { return .ignored }
                        model.activate(items[level.selected])
                        return .handled
                    }
                    .onKeyPress(.delete) {
                        guard level.query.isEmpty, palette.stack.count > 1 else { return .ignored }
                        _ = palette.pop()
                        return .handled
                    }
                    .onSubmit { run(level, items) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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
            if !lines.isEmpty {
                list(lines, selected: level.selected)
            }
        }
        .padding(.bottom, lines.isEmpty ? 0 : 6)
        .frame(width: 560)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .background(Surface.drawer, in: .rect(cornerRadius: 14, style: .continuous))
        .animation(Motion.fade, value: status(of: level))
        // The field isn't in the window until the slide-in starts, so focus it a beat later.
        .task {
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
    }

    private func list(_ lines: [Line], selected: Int) -> some View {
        let height = lines.reduce(CGFloat(8)) { total, line in
            if case .heading = line { return total + Self.heading }
            return total + Self.row
        }
        return ScrollViewReader { proxy in
            List(lines) { line in
                switch line {
                case .heading(let title):
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Ink.faint)
                        .padding(.horizontal, 8)
                        .frame(height: Self.heading, alignment: .bottomLeading)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                case .item(let item, let index):
                    row(item, selected: index == selected) {
                        model.palette.level.selected = index
                        model.activate(item)
                    }
                    .id(item.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
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
                if let project = item.project {
                    ProjectBadge(project: project)
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
            return numbered(Array(Palette.rank(model.paletteSearchable(), by: level.query, recents: model.paletteRecents).prefix(40)))
        case .list(let list):
            var items = Palette.rank(level.items, by: level.query, recents: model.paletteRecents)
            let typed = level.query.trimmingCharacters(in: .whitespaces)
            if !typed.isEmpty, !level.items.contains(where: { $0.title.caseInsensitiveCompare(typed) == .orderedSame }),
               let made = list.typed?(typed) {
                items.append(made)
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
        case .root: "Search commands, threads and projects"
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
