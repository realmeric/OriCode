import SwiftUI

enum PermissionModeOption: String, CaseIterable, Identifiable {
    case ask = "default"
    case acceptEdits
    case auto
    case plan
    case dontAsk = "bypassPermissions"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .acceptEdits: "Accept edits"
        case .auto: "Auto"
        case .plan: "Plan"
        case .dontAsk: "Don't ask"
        }
    }

    var icon: String {
        switch self {
        case .ask: "hand.raised"
        case .acceptEdits: "pencil"
        case .auto: "sparkles"
        case .plan: "list.bullet.clipboard"
        case .dontAsk: "lock.open"
        }
    }

    var summary: String {
        switch self {
        case .ask: "Edits and commands wait for you"
        case .acceptEdits: "Edits go through, commands ask"
        case .auto: "Claude decides what is safe"
        case .plan: "Reads and thinks, changes nothing"
        case .dontAsk: "Everything goes through"
        }
    }
}

/// The model button in the composer and the picker it opens: model, effort and permission mode
/// as rows of the app's own rather than a system menu. That breaks rule 1 on purpose (see the
/// board's Exceptions); the Thread menu keeps the native pickers for the keyboard.
struct ModelMenu: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    @State private var hovering = false

    var body: some View {
        Button {
            model.modelPickerShown.toggle()
        } label: {
            HStack(spacing: 6) {
                ClaudeMark()
                    .frame(width: 14, height: 14)
                let name = selectedModel.map { Self.shortName($0.name) } ?? "Model"
                Text(name)
                    .foregroundStyle(Ink.primary)
                    .id(name)
                    .transition(.blurReplace)
                if let chat, model.fastMode(of: chat) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Ink.secondary)
                        .help("Fast mode")
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                // Default names the level it lands on, fainter than one picked.
                if let level = shownEffort ?? model.defaultLevel(for: chat) {
                    Text(Self.effortName(level))
                        .foregroundStyle(shownEffort == nil ? Ink.faint : Ink.secondary)
                        .id(level)
                        .transition(.blurReplace)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
            }
            .font(Type.secondary)
            // The picker's choices arrive here as it makes them; the button grows leftwards,
            // since the composer's field gives way and the send button holds its right.
            .animation(Motion.move, value: [selectedModel?.id, shownEffort, chat.map(model.fastMode(of:)) == true ? "fast" : nil])
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(hovering || model.modelPickerShown ? Surface.hover : .clear, in: .capsule)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        // From the button's right end, which stays put while its label grows leftwards with
        // the effort and the bolt, so the picker doesn't drift as choices change.
        .popover(isPresented: Binding(get: { model.modelPickerShown }, set: { model.modelPickerShown = $0 }),
                 attachmentAnchor: .point(.trailing), arrowEdge: .top) {
            ModelPanel(chat: chat, selectedModel: selectedModel, effort: effortBinding, mode: modeBinding, fast: fastBinding)
        }
        .help("Model and permission mode")
        .accessibilityLabel("Model: \(selectedModel?.name ?? "none")")
        .accessibilityValue(accessibilityEffort)
    }

    private var selectedModel: ModelOption? { model.option(for: chat) }

    /// The thread's level, or with no thread the one the next starts with, if its model has it.
    private var shownEffort: String? {
        guard let effort = chat == nil ? model.startingEffort : chat?.effort,
              selectedModel?.levels.contains(effort) == true
        else { return nil }
        return effort
    }

    private var accessibilityEffort: String {
        if let effort = shownEffort { return "Effort \(Self.effortName(effort))" }
        return model.defaultLevel(for: chat).map { "Effort \(Self.effortName($0)), the default" } ?? ""
    }

    static func effortName(_ effort: String) -> String {
        switch effort {
        case "xhigh": "Extra high"
        case Effort.ultracode: "Ultracode"
        default: effort.capitalized
        }
    }

    static func shortName(_ name: String) -> String {
        String(name.split(separator: " (").first ?? Substring(name))
    }

    private var effortBinding: Binding<String> {
        Binding {
            shownEffort ?? ""
        } set: { effort in
            model.setEffort(effort.isEmpty ? nil : effort, for: chat)
        }
    }

    private var fastBinding: Binding<Bool> {
        Binding {
            chat?.fastMode ?? model.startingFast
        } set: { on in
            model.setFast(on, for: chat)
        }
    }

    private var modeBinding: Binding<String> {
        Binding {
            chat?.permissionMode ?? model.startingPermissionMode
        } set: { mode in
            model.setPermissionMode(mode, for: chat)
        }
    }
}

/// What the model button opens: models on the left; effort, speed and permissions on the right.
/// Two columns, so it stays short enough to open above the composer.
private struct ModelPanel: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    let selectedModel: ModelOption?
    @Binding var effort: String
    @Binding var mode: String
    @Binding var fast: Bool
    /// The chosen model's and mode's highlights move between choices instead of jumping.
    @Namespace private var glide

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                heading("Model")
                ForEach(model.models) { option in
                    ModelRow(option: option, chosen: option.id == selectedModel?.id, glide: glide) {
                        model.setModel(option.id, for: chat)
                    }
                }
            }
            .frame(width: 250)
            VStack(alignment: .leading, spacing: 4) {
                if let levels = selectedModel?.efforts, !levels.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            heading("Effort")
                            Spacer()
                            // The bars don't say which level they are; Default says so on its pill.
                            if !effort.isEmpty {
                                Text(ModelMenu.effortName(effort))
                                    .font(Type.secondary)
                                    .foregroundStyle(Ink.secondary)
                                    .padding(.top, 6)
                                    .transition(.opacity)
                            }
                        }
                        EffortMeter(levels: levels, defaultLevel: selectedModel?.defaultEffort, effort: $effort)
                    }
                    .transition(section)
                }
                if selectedModel?.fast == true {
                    VStack(alignment: .leading, spacing: 4) {
                        heading("Speed")
                        FastChip(on: $fast, status: fastStatus)
                    }
                    .transition(section)
                }
                heading("Permissions")
                ModeTiles(mode: $mode, glide: glide)
            }
            .frame(width: 292)
        }
        .padding(10)
        .animation(Motion.move, value: selectedModel?.id)
        .animation(Motion.move, value: mode)
        .onAppear {
            // Fast mode left on from an earlier launch hasn't been checked in this one.
            if let chat, model.fastMode(of: chat), model.conversations[chat.id]?.fastState == nil {
                model.checkFast(chat)
            }
        }
    }

    /// A section that comes and goes with the model: gone at once when it leaves, so what's
    /// under it doesn't slide over it, and fading in once the rest has made room.
    private var section: AnyTransition {
        .asymmetric(insertion: .opacity.animation(Motion.fade.delay(0.14)), removal: .identity)
    }

    /// What the CLI last said about fast mode for the thread, in the app's words.
    private var fastStatus: String {
        guard fast else { return "Faster output from the same model" }
        let conversation = chat.flatMap { model.conversations[$0.id] }
        guard let state = conversation?.fastState else { return "Checking…" }
        switch state {
        case "on": return "On for this model"
        case "cooldown": return "Paused after a rate limit, back shortly"
        default: return conversation?.fastReason.map(FastChip.why) ?? "Not available right now"
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Ink.faint)
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

/// A model: its name and the SDK's line about it, on the gliding highlight when it's the one.
private struct ModelRow: View {
    let option: ModelOption
    let chosen: Bool
    let glide: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(option.name)
                    .font(Type.body)
                    .foregroundStyle(chosen ? Ink.primary : Ink.primary.opacity(0.8))
                Text(option.description)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                if chosen {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Surface.selected)
                        .matchedGeometryEffect(id: "model", in: glide)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
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

/// Effort as a meter: Default, then a bar for each level the model has, taller as they go,
/// lit up to the chosen one.
private struct EffortMeter: View {
    let levels: [String]
    /// Where Default lands, lit fainter than a level picked.
    let defaultLevel: String?
    @Binding var effort: String
    @State private var hovered: String?

    var body: some View {
        let chosen = levels.firstIndex(of: effort) ?? defaultLevel.flatMap(levels.firstIndex(of:)) ?? -1
        HStack(alignment: .bottom, spacing: 2) {
            Button {
                effort = ""
            } label: {
                Text("Default")
                    .font(Type.secondary)
                    .foregroundStyle(effort.isEmpty ? Ink.primary : Ink.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(effort.isEmpty ? Surface.selected : hovered == "" ? Surface.hover : Surface.card, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 ? "" : (hovered == "" ? nil : hovered) }
            .padding(.trailing, 8)
            ForEach(Array(levels.enumerated()), id: \.element) { index, level in
                Button {
                    effort = level
                } label: {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(index <= chosen ? (effort.isEmpty ? Ink.secondary : Ink.primary) : Color.white.opacity(hovered == level ? 0.3 : 0.15))
                        .frame(width: 10, height: 8 + CGFloat(index) * 16 / CGFloat(max(levels.count - 1, 1)))
                        // A wider, full-height target than the bar it holds.
                        .frame(width: 22, height: 28, alignment: .bottom)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? level : (hovered == level ? nil : hovered) }
                .help(ModelMenu.effortName(level))
                .accessibilityLabel("Effort \(ModelMenu.effortName(level))")
                .accessibilityAddTraits(level == effort ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .animation(Motion.move, value: effort)
    }
}

/// Fast mode as a bolt chip that lights when it's on, with what the CLI said beside it.
private struct FastChip: View {
    @Binding var on: Bool
    let status: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                on.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: on ? "bolt.fill" : "bolt")
                        .symbolEffect(.bounce, value: on)
                    Text("Fast")
                }
                .font(Type.secondary.weight(.medium))
                .foregroundStyle(on ? Ink.primary : Ink.secondary)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(on ? Color.white.opacity(0.18) : hovering ? Surface.hover : Surface.card, in: .capsule)
                .shadow(color: .white.opacity(on ? 0.22 : 0), radius: 6)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel("Fast mode")
            .accessibilityValue(on ? "On" : "Off")
            Text(status)
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .animation(Motion.move, value: on)
    }

    /// The CLI's reasons, in the app's words.
    static func why(_ reason: String) -> String {
        switch reason {
        case "free": "Needs a paid Claude plan"
        case "extra_usage_disabled": "Needs usage credits on your Claude account"
        case "preference": "Your organization has turned it off"
        case "model_not_allowed": "Not allowed for this model"
        case "not_first_party": "Only when Claude Code talks to Anthropic directly"
        case "disabled_by_env": "Turned off on this Mac"
        case "network_error": "Couldn't check just now"
        case "pending": "Checking…"
        default: "Not available right now"
        }
    }
}

/// The permission modes as five tiles, the highlight moving to the chosen one, with its name
/// and line under them.
private struct ModeTiles: View {
    @Binding var mode: String
    let glide: Namespace.ID
    @State private var hovered: String?

    var body: some View {
        let current = PermissionModeOption(rawValue: mode) ?? .ask
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(PermissionModeOption.allCases) { option in
                    let chosen = option == current
                    Button {
                        mode = option.rawValue
                    } label: {
                        Image(systemName: option.icon)
                            .font(.system(size: 15))
                            .foregroundStyle(chosen ? Ink.primary : Ink.secondary)
                            .frame(width: 52, height: 40)
                            .background {
                                if chosen {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Surface.selected)
                                        .matchedGeometryEffect(id: "mode", in: glide)
                                } else if hovered == option.rawValue {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Surface.hover)
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? option.rawValue : (hovered == option.rawValue ? nil : hovered) }
                    .help(option.title)
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(current.title)
                    .font(Type.body)
                    .foregroundStyle(Ink.primary)
                Text(current.summary)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, 4)
            .id(current)
            .transition(.opacity)
        }
    }
}
