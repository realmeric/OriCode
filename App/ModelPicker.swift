import SwiftUI

/// The thread's choices, or with no thread open the ones the next thread starts with.
@MainActor
struct PickerState {
    let model: AppModel
    let chat: Chat?

    var option: ModelOption? { model.option(for: chat) }

    /// The level picked, nil for Default, and never one the model doesn't have.
    var effort: String? {
        guard let effort = chat == nil ? model.startingEffort : chat?.effort, option?.levels.contains(effort) == true else { return nil }
        return effort
    }

    var conversation: Conversation? { chat.flatMap { model.conversations[$0.id] } }

    /// Where Default lands: what the thread's own CLI reported while it sent no level, which
    /// counts a project's settings, or else what the engine read for the model.
    var home: String? { model.defaultLevel(for: chat) }

    /// The level the thread runs at: the one picked, or where Default lands.
    var level: String? { effort ?? home }

    /// Fast mode as the user set it. The bolt and the effects follow this, not Claude Code's
    /// answer, which `fastProblem` puts into words when it won't serve it.
    var fastAsked: Bool { option?.fast == true && (chat?.fastMode ?? model.startingFast) }

    var mode: PermissionModeOption {
        PermissionModeOption(rawValue: chat?.permissionMode ?? model.startingPermissionMode) ?? .ask
    }

    var agent: ProviderInfo { model.agent(for: chat) }

    /// The tiles: none for an agent with no modes.
    var modes: [PermissionModeOption] { agent.permissionModes }

    var unsupervised: Bool { agent.unsupervised }

    /// Why fast mode, turned on, isn't running fast right now, in the app's words.
    var fastProblem: String? {
        guard fastAsked else { return nil }
        guard let reading = model.fastReading(for: chat) else { return "Checking fast mode…" }
        switch reading.state {
        case "on": return nil
        case "cooldown": return "Paused after a rate limit, back shortly"
        default: return FastCopy.why(reading.reason ?? "")
        }
    }

    /// Ultracode picked, but the thread's CLI says it didn't come on.
    var ultracodeMissing: String? {
        guard effort == Effort.ultracode, conversation?.askedUltracode == true, conversation?.appliedUltracode == false else { return nil }
        let running = conversation?.appliedEffort.flatMap { $0 }.map(ModelMenu.effortName) ?? "its own level"
        return "Ultracode didn't turn on here · running at \(running)"
    }
}

/// Marks what Back to Defaults moves, so its changes can land one after another.
struct ResetWave: TransactionKey {
    static let defaultValue = false
}

extension View {
    /// In a Back to Defaults, this lands `order` steps of 40ms after the first.
    func resetWave(_ order: Int, glide: Bool = false) -> some View {
        transaction { transaction in
            guard transaction[ResetWave.self] else { return }
            transaction.animation = (glide ? Motion.glide : Motion.move).delay(Double(order) * 0.04)
        }
    }
}

/// A word beside a choice that says what it is: Default, or This thread for Ultracode.
struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Surface.selected, in: .capsule)
    }
}

/// The agent's mark and the model's name: the way to the list of models.
struct ModelLine: View {
    let option: ModelOption?
    /// The agent whose mark it shows: the thread's, or the one Back to Defaults would move it to.
    let agent: String
    /// The model Back to Defaults would pick, while the pointer is on it.
    let preview: ModelOption?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shown = preview ?? option
        Button(action: action) {
            HStack(spacing: 5) {
                AgentMark(agent: agent)
                    .frame(width: 12, height: 12)
                Text(shown?.name ?? "Model")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .opacity(preview == nil || preview?.id == option?.id ? 1 : 0.6)
                    .id(shown?.id)
                    .transition(.opacity.animation(Motion.fade))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Ink.faint)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(hovering ? Surface.hover : .clear, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Choose the model")
        .accessibilityLabel("Model: \(option?.name ?? "none")")
        .accessibilityHint("Shows the models")
    }
}

/// Fast mode: a bolt that lights up white on a lit circle when it's turned on, faint while it's
/// off. Whether Claude Code serves it is for the line under the level to say.
struct FastButton: View {
    let on: Bool
    /// Back to Defaults, previewed, would turn it off.
    let dimmed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "bolt.fill" : "bolt")
                .font(.system(size: 13, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? Color.white : hovering ? Ink.secondary : Ink.faint)
                .opacity(dimmed && on ? 0.45 : 1)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: on)
                .frame(width: 30, height: 30)
                .background(on ? Color.white.opacity(0.2) : hovering ? Surface.hover : Surface.card, in: .circle)
                .shadow(color: .white.opacity(on ? 0.35 : 0), radius: 8)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: on)
        .animation(Motion.fade, value: dimmed)
        .help(on ? "Fast mode is on" : "Fast mode: faster output from the same model")
        .accessibilityLabel("Fast mode")
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// Everything back to its default, previewed while the pointer is on it, turning back once as
/// it goes.
struct ResetButton: View {
    let turns: Int
    @Binding var previewing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(previewing ? Ink.primary : Ink.secondary)
                .symbolEffect(.rotate.counterClockwise, value: turns)
                .frame(width: 30, height: 30)
                .background(previewing ? Surface.hover : Surface.card, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(Motion.fade) { previewing = inside } }
        .help("Back to the defaults")
        .accessibilityLabel("Back to the defaults")
    }
}

struct ModelsPage: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    let back: () -> Void
    @Namespace private var glide
    /// The row the arrow keys are on.
    @State private var keyed: String?
    @FocusState private var focused: Bool

    /// A model with its agent.
    struct Row: Identifiable, Hashable {
        let agent: String
        let option: ModelOption

        var ref: ModelRef { ModelRef(provider: agent, id: option.id) }
        /// ModelRef's key, so two agents' models never share one.
        var id: String { ref.stored }
    }

    /// Rows and headings as the page draws them.
    struct RowGroup: Identifiable {
        let id: String
        let title: String?
        /// The agent whose mark the heading shows, when the page lists more than one.
        let agent: String?
        let rows: [Row]
    }

    /// Favorites first, from every agent; then with one agent its models, under Models when
    /// there are favorites, and with several each agent's under its name; and Claude Code's
    /// older ones under More models after its own.
    static func groups(_ agents: [(agent: ProviderInfo, models: [ModelOption])], favorites: [String]) -> [RowGroup] {
        let listed = agents.filter { !$0.models.isEmpty }
        let all = listed.flatMap { entry in entry.models.map { Row(agent: entry.agent.id, option: $0) } }
        let starred = favorites.compactMap { id in all.first { $0.id == id } }
        let rest = all.filter { !favorites.contains($0.id) }
        let several = listed.count > 1
        var groups = [RowGroup(id: "Favorites", title: "Favorites", agent: nil, rows: starred)]
        for entry in listed {
            let own = rest.filter { $0.agent == entry.agent.id }
            let title = several ? entry.agent.name : starred.isEmpty ? nil : "Models"
            groups.append(RowGroup(id: several ? "agent:" + entry.agent.id : title ?? "", title: title, agent: several ? entry.agent.id : nil,
                                   rows: own.filter { $0.option.more != true }))
            groups.append(RowGroup(id: several ? "more:" + entry.agent.id : "More models", title: "More models", agent: nil,
                                   rows: own.filter { $0.option.more == true }))
        }
        return groups.filter { !$0.rows.isEmpty }
    }

    private static let row: CGFloat = 42
    private static let heading: CGFloat = 28

    /// The page's height: all of it up to the effort page's, and past that it scrolls.
    static func height(for groups: [RowGroup]) -> CGFloat {
        let rows = groups.reduce(0) { $0 + $1.rows.count }
        let headings = groups.filter { $0.title != nil }.count
        return min(CGFloat(rows) * row + CGFloat(headings) * heading + 16, MarkPicker.effortHeight)
    }

    /// Whether a row ends past what the page shows before it scrolls.
    static func below(_ id: String?, in groups: [RowGroup]) -> Bool {
        var top: CGFloat = 8
        for group in groups {
            if group.title != nil { top += heading }
            for candidate in group.rows {
                if candidate.id == id { return top + row > height(for: groups) }
                top += row
            }
        }
        return false
    }

    var body: some View {
        let chosen = PickerState(model: model, chat: chat).option.map { ModelRef(provider: model.providerID(for: chat), id: $0.id).stored }
        ScrollViewReader { reader in
            ScrollView {
                // Lazy, since an agent can list hundreds: OpenCode's 392 took 0.9s to draw at once.
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.modelGroups(for: chat)) { group in
                        if let title = group.title {
                            heading(title, agent: group.agent)
                                .padding(.horizontal, 10)
                                .frame(height: Self.heading - 2, alignment: .bottomLeading)
                                .id(group.id)
                        }
                        ForEach(group.rows) { row in
                            ModelRow(option: row.option, agent: row.agent, forbidden: model.forbiddenHelp(row.option, on: row.agent),
                                     chosen: row.id == chosen, keyed: row.id == keyed,
                                     favorite: model.favoriteModels.contains(row.id), glide: glide,
                                     star: { withAnimation(Motion.move) { model.toggleFavorite(row.id) } }) {
                                pick(row.ref)
                            }
                            .id(row.id)
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            .onAppear {
                keyed = chosen
                focused = true
                // Only when it has to: a lazy stack scrolled while the page glides in comes to rest
                // a fraction of a point to the side.
                if Self.below(chosen, in: model.modelGroups(for: chat)) { reader.scrollTo(scrollTarget(chosen)) }
            }
            .onChange(of: keyed) { _, row in
                withAnimation(Motion.move) { reader.scrollTo(scrollTarget(row)) }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.leftArrow) {
            back()
            return .handled
        }
        .onKeyPress(.return) {
            guard let keyed else { return .ignored }
            pick(ModelRef(stored: keyed))
            return .handled
        }
    }

    /// A group's name, and with several agents on the page the agent's mark before it.
    @ViewBuilder
    private func heading(_ title: String, agent: String?) -> some View {
        let text = Text(title)
            .font(Type.secondary)
            .foregroundStyle(Ink.faint)
        if let agent {
            HStack(spacing: 5) {
                AgentMark(agent: agent)
                    .frame(width: 10, height: 10)
                text
            }
        } else {
            text
        }
    }

    /// A group's first row brings its heading into view with it.
    private func scrollTarget(_ row: String?) -> String? {
        model.modelGroups(for: chat).first { $0.rows.first?.id == row }.flatMap { $0.title == nil ? nil : $0.id } ?? row
    }

    private func move(_ by: Int) -> KeyPress.Result {
        let ids = model.modelGroups(for: chat).flatMap(\.rows).filter(\.option.pickable).map(\.id)
        let at = keyed.flatMap(ids.firstIndex(of:)) ?? -1
        guard ids.indices.contains(at + by) else { return .ignored }
        keyed = ids[at + by]
        return .handled
    }

    private func pick(_ ref: ModelRef) {
        withAnimation(Motion.move) { model.setModel(ref, for: chat) }
        Task {
            // Long enough to see the highlight land before the page turns back.
            try? await Task.sleep(for: .milliseconds(140))
            back()
        }
    }
}

/// A group's models in a native menu, the Thread menu's or Settings', under its agent's name
/// when the menu lists several agents.
struct ModelMenuItems: View {
    let group: ModelsPage.RowGroup

    var body: some View {
        if let title = group.title, group.agent != nil {
            Section(title) { items }
        } else {
            items
        }
    }

    private var items: some View {
        ForEach(group.rows.filter(\.option.pickable)) { row in
            Text(row.option.name).tag(row.id)
        }
    }
}

/// A model: its agent's mark, its name and the agent's line about it, a bolt if it can go fast,
/// on the gliding highlight when it's the one, and at the end a star of its own, which shows on
/// the row under the pointer or the arrow keys and stays on a favorite.
struct ModelRow: View {
    let option: ModelOption
    let agent: String
    /// What a model its maker's login keeps from OriCode says of the toggle that would let it run.
    let forbidden: String?
    let chosen: Bool
    let keyed: Bool
    let favorite: Bool
    let glide: Namespace.ID
    let star: () -> Void
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let unavailable = !option.pickable
        let starShown = !unavailable && (favorite || hovering || keyed)
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 10) {
                    AgentMark(agent: agent)
                        .frame(width: 14, height: 14)
                        .opacity(chosen ? 1 : 0.45)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.name)
                            .font(Type.body)
                            .foregroundStyle(chosen ? Ink.primary : Ink.primary.opacity(0.8))
                        if !option.description.isEmpty {
                            Text(option.description)
                                .font(Type.secondary)
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if option.fast {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Ink.faint)
                            .help("Can run in fast mode")
                    }
                    if chosen {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .frame(height: 40)
                .opacity(unavailable ? 0.45 : 1)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(unavailable)
            .help(option.needs.map { "Run claude update in Terminal to use \(option.name), which needs Claude Code \($0)" }
                ?? forbidden
                ?? (option.description.isEmpty ? option.name : option.description))
            .accessibilityAddTraits(chosen ? .isSelected : [])
            .accessibilityAction(named: favorite ? "Remove from Favorites" : "Add to Favorites") { if !unavailable { star() } }
            Button(action: star) {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(favorite ? Ink.secondary : Ink.faint)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18, height: 40)
                    .padding(.trailing, 10)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .opacity(starShown ? 1 : 0)
            .disabled(unavailable)
            .animation(Motion.fade, value: starShown)
            .help(favorite ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel(favorite ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityHidden(!starShown)
        }
        .background {
            if chosen {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Surface.selected)
                    .matchedGeometryEffect(id: "model", in: glide)
            } else if !unavailable, hovering || keyed {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Surface.hover)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if !unavailable {
                Button(favorite ? "Remove from Favorites" : "Add to Favorites", action: star)
            }
        }
    }
}

/// The permission modes the agent has as tiles, five for Claude Code, the highlight moving to the
/// chosen one, with its name and line under them; a hovered tile previews its line.
struct ModeTiles: View {
    let modes: [PermissionModeOption]
    @Binding var mode: String
    /// The mode Back to Defaults would pick, lit as if hovered.
    let preview: PermissionModeOption?
    let compact: Bool
    @State private var hovered: PermissionModeOption?
    @Namespace private var glide

    var body: some View {
        let current = PermissionModeOption(rawValue: mode) ?? .ask
        let shown = hovered ?? current
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(modes) { option in
                    let chosen = option == current
                    Button {
                        withAnimation(Motion.move) { mode = option.rawValue }
                    } label: {
                        Image(systemName: option.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(chosen ? Ink.primary : Ink.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background {
                                if chosen {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Surface.selected)
                                        .matchedGeometryEffect(id: "mode", in: glide)
                                } else if hovered == option || preview == option {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Surface.hover)
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        withAnimation(.easeOut(duration: 0.12)) { hovered = inside ? option : (hovered == option ? nil : hovered) }
                    }
                    .help(option == .ask ? "Ask (default)" : option.title)
                }
            }
            .accessibilityRepresentation {
                Picker("Permission mode", selection: $mode) {
                    ForEach(modes) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            if !compact {
                HStack(spacing: 0) {
                    Text(shown.title)
                        .foregroundStyle(Ink.primary.opacity(hovered == nil ? 1 : 0.7))
                        .fontWeight(.medium)
                    if shown == .ask {
                        Tag(text: "Default")
                            .padding(.leading, 5)
                    }
                    Text(" · " + shown.summary)
                        .foregroundStyle(Ink.secondary)
                }
                .font(Type.secondary)
                .lineLimit(1)
                .frame(height: 16)
                .id(shown)
                .transition(.opacity.animation(hovered == nil ? Motion.fade : .easeOut(duration: 0.12)))
            }
        }
    }
}
