import SwiftUI

/// What the model button opens. One page says how Claude runs the thread: how hard it thinks,
/// whether it's served fast, and what it may do without asking. The other lists the models and
/// opens from the model's name. Both are the same size, because a popover that changes size
/// while it's open jumps, or opens off to the side.
struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    /// Without the lines under the rail and the tiles, for when there's too little room above
    /// the composer for the whole picker.
    let compact: Bool
    @State private var page = Page.effort

    enum Page { case effort, models }

    static let width: CGFloat = 360
    static let height: CGFloat = 226
    static let compactHeight: CGFloat = 168

    var body: some View {
        ZStack {
            switch page {
            case .effort:
                EffortPage(chat: chat, compact: compact) { turn(to: .models) }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: -24)).animation(Motion.move),
                                            removal: .opacity.combined(with: .offset(x: -24)).animation(Motion.fade)))
            case .models:
                ModelsPage(chat: chat) { turn(to: .effort) }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)).animation(Motion.move),
                                            removal: .opacity.combined(with: .offset(x: 24)).animation(Motion.fade)))
            }
        }
        .frame(width: Self.width, height: compact ? Self.compactHeight : Self.height)
        .onAppear {
            // Fast mode left on from an earlier launch hasn't been checked in this one.
            if let chat, model.fastMode(of: chat), model.conversations[chat.id]?.fastState == nil {
                model.checkFast(chat)
            }
        }
        .onKeyPress(.escape) {
            guard page == .models else { return .ignored }
            turn(to: .effort)
            return .handled
        }
    }

    private func turn(to next: Page) {
        page = next
    }
}

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

    var fastAsked: Bool { option?.fast == true && (chat?.fastMode ?? model.startingFast) }

    var fastState: String? { conversation?.fastState }

    var fastServed: Bool { fastAsked && fastState == "on" }

    var mode: PermissionModeOption {
        PermissionModeOption(rawValue: chat?.permissionMode ?? model.startingPermissionMode) ?? .ask
    }

    /// What fast mode can't do right now, in the app's words, while it's asked for.
    var fastProblem: String? {
        // With no thread there's no CLI to ask yet.
        guard fastAsked, chat != nil else { return nil }
        guard let state = fastState else { return "Checking fast mode…" }
        switch state {
        case "on": return nil
        case "cooldown": return "Paused after a rate limit, back shortly"
        default: return conversation?.fastReason.map(FastCopy.why) ?? "Not available right now"
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
private struct ResetWave: TransactionKey {
    static let defaultValue = false
}

extension View {
    /// In a Back to Defaults, this lands `order` steps of 40ms after the first.
    fileprivate func resetWave(_ order: Int, glide: Bool = false) -> some View {
        transaction { transaction in
            guard transaction[ResetWave.self] else { return }
            transaction.animation = (glide ? Motion.glide : Motion.move).delay(Double(order) * 0.04)
        }
    }
}

private struct EffortPage: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    let compact: Bool
    let openModels: () -> Void
    @State private var held: String?
    @State private var hovered: String?
    /// The level the title showed last, for which way the next word comes in.
    @State private var lastLevel: String?
    @State private var previewingReset = false
    @State private var resetTurns = 0
    /// A click on Ultracode while workflows keep it off, said for a moment.
    @State private var blockedNote = false

    private var state: PickerState { PickerState(model: model, chat: chat) }

    var body: some View {
        let state = state
        VStack(spacing: 0) {
            header(state)
                .frame(height: 48)
            Group {
                if let option = state.option, !option.efforts.isEmpty {
                    EffortRail(stops: option.stops, home: state.home, blocked: option.ultraBlocked != nil && !option.ultra,
                               effort: Binding(get: { state.effort }, set: { model.setEffort($0, for: chat) }),
                               held: $held, hovered: $hovered, compact: compact,
                               ghost: previewingReset ? resetTarget(state) : nil,
                               onBlocked: showBlocked, onReturn: { model.modelPickerShown = false })
                        .resetWave(1, glide: true)
                        .transition(.asymmetric(insertion: .opacity.animation(Motion.fade.delay(0.14)), removal: .identity))
                } else {
                    Text("\(ModelMenu.shortName(state.option?.name ?? "This model")) has one reasoning level.")
                        .font(Type.secondary)
                        .foregroundStyle(Ink.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? EffortRail.row : EffortRail.row + 16)
                        .transition(.asymmetric(insertion: .opacity.animation(Motion.fade.delay(0.14)), removal: .identity))
                }
            }
            .padding(.top, 12)
            if !compact {
                levelLine(state)
                    .frame(height: 16)
                    .padding(.top, 4)
            }
            ModeTiles(mode: Binding(get: { state.mode.rawValue }, set: { model.setPermissionMode($0, for: chat) }),
                      preview: previewingReset ? PermissionModeOption(rawValue: model.threadDefaults.permissionMode) : nil,
                      compact: compact)
                .resetWave(3)
                .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .animation(Motion.move, value: state.option?.id)
        .onChange(of: held ?? state.level, initial: true) { _, now in lastLevel = now }
    }

    private func header(_ state: PickerState) -> some View {
        HStack(spacing: 0) {
            Group {
                if state.option?.fast == true {
                    FastButton(asked: state.fastAsked, state: state.fastState, dimmed: previewingReset && !model.threadDefaults.fast) {
                        model.setFast(!state.fastAsked, for: chat)
                    }
                    .resetWave(2)
                    .transition(.opacity.animation(Motion.fade))
                } else {
                    Color.clear
                }
            }
            .frame(width: 30, height: 30)
            Spacer(minLength: 8)
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    let shown = held ?? state.level
                    Text(title(state))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .id(title(state))
                        // The new word comes up from below as effort rises and down from above as
                        // it falls; the old one blurs out where it is, since it leaves with the
                        // transition it was last drawn with, before the direction was known.
                        .transition(.asymmetric(insertion: AnyTransition(.blurReplace).combined(with: .offset(y: rising ? 6 : -6)),
                                                removal: AnyTransition(.blurReplace)))
                    if shown == Effort.ultracode {
                        Tag(text: "This thread")
                            .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)).animation(Motion.fade))
                    } else if compact, shown != nil, held == nil ? state.effort == nil : held == state.home {
                        Tag(text: "Default")
                            .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)).animation(Motion.fade))
                    }
                }
                .frame(height: 24)
                .animation(Motion.move, value: title(state))
                ModelLine(option: state.option, preview: previewingReset ? model.models.first { $0.id == model.threadDefaults.model } : nil,
                          action: openModels)
                    .resetWave(0)
            }
            Spacer(minLength: 8)
            Group {
                if !model.atDefaults(chat) {
                    ResetButton(turns: resetTurns, previewing: $previewingReset) { reset() }
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.6)).animation(Motion.move),
                                                removal: .opacity.animation(Motion.fade)))
                } else {
                    Color.clear
                }
            }
            .frame(width: 30, height: 30)
        }
    }

    private func title(_ state: PickerState) -> String {
        guard let option = state.option, !option.efforts.isEmpty else { return "Standard" }
        return (held ?? state.level).map(ModelMenu.effortName) ?? "Default"
    }

    /// Whether the title's new word comes up from below, as effort rises, or down from above.
    private var rising: Bool {
        let stops = state.option?.stops ?? []
        guard let now = held ?? state.level else { return true }
        return (stops.firstIndex(of: now) ?? 0) >= (stops.firstIndex(of: lastLevel ?? now) ?? 0)
    }

    /// Where the thumb lands after Back to Defaults, when the model stays the same.
    private func resetTarget(_ state: PickerState) -> String? {
        let target = model.threadDefaults
        guard target.model == state.option?.id else { return nil }
        return target.effort ?? state.home
    }

    /// One line under the rail: a preview while the pointer is on a stop, then fast mode's
    /// trouble, then an Ultracode that didn't come on, then what the level does.
    private func levelLine(_ state: PickerState) -> some View {
        let line: (words: String, cost: String?, preview: Bool)
        let blocked = state.option.map { $0.ultraBlocked != nil && !$0.ultra } ?? false
        if blockedNote || (hovered == Effort.ultracode && blocked) {
            line = (Self.needsWorkflows, nil, false)
        } else if let previewed = held ?? hovered {
            if previewed == state.home, held == nil {
                line = ("\(ModelMenu.effortName(previewed)) · \(homeReason(state))", nil, true)
            } else {
                let own = EffortScale.line(previewed)
                line = (own.words, own.cost, held == nil)
            }
        } else if let problem = state.fastProblem {
            line = (problem, nil, false)
        } else if let missing = state.ultracodeMissing {
            line = (missing, nil, false)
        } else if let level = state.level {
            let own = EffortScale.line(level)
            line = (own.words, own.cost, false)
        } else if state.option?.efforts.isEmpty == false {
            // Before the engine has read where Default lands.
            line = ("Claude Code picks the level for this model", nil, false)
        } else {
            line = ("", nil, false)
        }
        return Text(line.cost.map { "\(line.words) · \($0)" } ?? line.words)
        .font(Type.secondary)
        .foregroundStyle(Ink.secondary)
        .lineLimit(1)
        .id(line.words)
        .transition(.opacity.animation(line.preview ? .easeOut(duration: 0.12) : Motion.fade))
    }

    /// Why Default lands where it does.
    private func homeReason(_ state: PickerState) -> String {
        if let reading = state.conversation?.defaultReading, reading.model == chat?.model, reading.level != state.option?.defaultEffort {
            return "Claude Code's default for this thread"
        }
        if model.settingsEffort != nil, model.settingsEffort == state.option?.defaultEffort {
            return "Claude Code's default, from your settings"
        }
        return "Claude Code's default for this model"
    }

    static let needsWorkflows = "Needs dynamic workflows, see /config in Claude Code"

    private func showBlocked() {
        AccessibilityNotification.Announcement(Self.needsWorkflows).post()
        blockedNote = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            blockedNote = false
        }
    }

    private func reset() {
        resetTurns += 1
        previewingReset = false
        var wave = Transaction(animation: Motion.move)
        wave[ResetWave.self] = true
        withTransaction(wave) { model.resetToDefaults(for: chat) }
    }
}

/// A word beside a choice that says what it is: Default, or This thread for Ultracode.
private struct Tag: View {
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

/// Claude's mark and the model's name: the way to the list of models.
private struct ModelLine: View {
    let option: ModelOption?
    /// The model Back to Defaults would pick, while the pointer is on it.
    let preview: ModelOption?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shown = preview ?? option
        Button(action: action) {
            HStack(spacing: 5) {
                ClaudeMark()
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

/// Fast mode: off, asked, served, paused or refused, all in white.
private struct FastButton: View {
    let asked: Bool
    /// What the CLI last said: on, off or cooldown; nil while it hasn't answered.
    let state: String?
    /// Back to Defaults, previewed, would turn it off.
    let dimmed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let served = asked && state == "on"
        let refused = asked && state != nil && state != "on" && state != "cooldown"
        Button(action: action) {
            Image(systemName: refused ? "bolt.slash" : asked ? "bolt.fill" : "bolt")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(asked && !refused && state != "cooldown" ? Ink.primary : Ink.secondary)
                .opacity(dimmed && asked ? 0.45 : 1)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: asked)
                .frame(width: 30, height: 30)
                .background(fill(asked: asked, served: served, refused: refused), in: .circle)
                .shadow(color: .white.opacity(served ? 0.22 : 0), radius: 6)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: state)
        .animation(Motion.fade, value: dimmed)
        .help(asked ? "Fast mode is on" : "Fast mode: faster output from the same model")
        .accessibilityLabel("Fast mode")
        .accessibilityValue(served ? "On" : refused ? "Not available" : asked ? "Asked for" : "Off")
    }

    private func fill(asked: Bool, served: Bool, refused: Bool) -> Color {
        if served { return Color.white.opacity(0.16) }
        if asked, !refused { return Color.white.opacity(0.12) }
        return hovering ? Surface.hover : Surface.card
    }
}

/// Everything back to its default, previewed while the pointer is on it, turning back once as
/// it goes.
private struct ResetButton: View {
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

private struct ModelsPage: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    let back: () -> Void
    @Namespace private var glide
    /// The row the arrow keys are on.
    @State private var keyed: String?
    @FocusState private var focused: Bool

    var body: some View {
        let chosen = PickerState(model: model, chat: chat).option?.id
        ScrollViewReader { reader in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.models) { option in
                        ModelRow(option: option, chosen: option.id == chosen, keyed: option.id == keyed, glide: glide) {
                            pick(option.id)
                        }
                        .id(option.id)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            .onAppear {
                keyed = chosen
                focused = true
                reader.scrollTo(chosen)
            }
            .onChange(of: keyed) { _, row in
                withAnimation(Motion.move) { reader.scrollTo(row) }
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
            pick(keyed)
            return .handled
        }
    }

    private func move(_ by: Int) -> KeyPress.Result {
        let ids = model.models.map(\.id)
        let at = keyed.flatMap(ids.firstIndex(of:)) ?? -1
        guard ids.indices.contains(at + by) else { return .ignored }
        keyed = ids[at + by]
        return .handled
    }

    private func pick(_ id: String) {
        withAnimation(Motion.move) { model.setModel(id, for: chat) }
        Task {
            // Long enough to see the highlight land before the page turns back.
            try? await Task.sleep(for: .milliseconds(140))
            back()
        }
    }
}

/// A model: its name and the SDK's line about it, a bolt if it can go fast, on the gliding
/// highlight when it's the one.
private struct ModelRow: View {
    let option: ModelOption
    let chosen: Bool
    let keyed: Bool
    let glide: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ClaudeMark()
                    .frame(width: 14, height: 14)
                    .opacity(chosen ? 1 : 0.45)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.name)
                        .font(Type.body)
                        .foregroundStyle(chosen ? Ink.primary : Ink.primary.opacity(0.8))
                    Text(option.description)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
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
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background {
                if chosen {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Surface.selected)
                        .matchedGeometryEffect(id: "model", in: glide)
                } else if hovering || keyed {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Surface.hover)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(option.description)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The permission modes as five tiles, the highlight moving to the chosen one, with its name
/// and line under them; a hovered tile previews its line.
private struct ModeTiles: View {
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
                ForEach(PermissionModeOption.allCases) { option in
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
                    ForEach(PermissionModeOption.allCases) { Text($0.title).tag($0.rawValue) }
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
