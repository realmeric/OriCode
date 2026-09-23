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

/// Claude's mark and the model's name: the way to the list of models.
struct ModelLine: View {
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
struct ModelRow: View {
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
struct ModeTiles: View {
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
