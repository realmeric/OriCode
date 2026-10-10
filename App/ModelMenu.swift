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
        case .auto: "checkmark.shield"
        case .plan: "list.bullet.clipboard"
        case .dontAsk: "lock.open"
        }
    }

    var summary: String {
        switch self {
        case .ask: "Edits and commands wait for you"
        case .acceptEdits: "Edits go through, commands ask"
        case .auto: "The model decides what is safe"
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
    let state: ComposerState
    /// How much of itself the button says, which its composer's width decides.
    var says = Says.all
    @State private var hovering = false
    /// Where the button is in the window, kept for the next thread this composer shows, which
    /// comes without the button moving.
    @State private var frame = CGRect.zero

    /// The picker is one for the window and opens over the composer with the keyboard.
    private var selected: Bool { chat == nil || chat?.id == model.selectedChatID }

    var body: some View {
        Button {
            // From the composer without the keyboard it opens over this one, wherever it was.
            if let chat, !selected {
                model.select(chat)
                model.modelPickerShown = true
            } else {
                model.modelPickerShown.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                AgentMark(agent: model.providerID(for: chat))
                    .frame(width: 14, height: 14)
                if says > .mark {
                    Text(name)
                        .foregroundStyle(Ink.primary)
                        .id(name)
                        .transition(.blurReplace)
                }
                // The head's rays beside it, each its agent's mark.
                if !rays.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(rays, id: \.self) { ray in
                            AgentMark(agent: ray.provider)
                                .frame(width: 10, height: 10)
                        }
                    }
                    .help(raysLine)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                if fast {
                    // On the way the user turned it on; the tooltip says so when Claude Code
                    // runs the thread at standard speed anyway.
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Ink.primary)
                        .help(PickerState(model: model, chat: chat).fastProblem ?? "Fast mode")
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                if workflows {
                    WorkflowsGlyph(on: true, color: MarkPalette.color(for: model.providerID(for: chat)), side: 11)
                        .help(PickerState(model: model, chat: chat).workflowsMissing ?? "Workflows")
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                // The level in effect: faint when it's Default's, brighter when picked, and at
                // full strength while workflows are on, so a thread can't stay on them unnoticed.
                if says == .all, let level {
                    Text(Self.effortName(level))
                        .foregroundStyle(workflows ? Ink.primary : shownEffort == nil ? Ink.faint : Ink.secondary)
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
            .animation(Motion.move, value: [selectedModel?.id, shownEffort, fast ? "fast" : nil, workflows ? "workflows" : nil] + rays.map(\.stored))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(hovering || model.modelPickerShown && selected ? Surface.hover : .clear, in: .capsule)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            frame = $0
            state.modelButtonFrame = $0
        }
        .onChange(of: ObjectIdentifier(state)) { state.modelButtonFrame = frame }
        // The words a narrow composer's button leaves out are here.
        .help(says == .all ? "Model and permission mode" : ([name] + (level.map { [Self.effortName($0)] } ?? [])).joined(separator: ", ") + ". Model and permission mode")
        .accessibilityLabel("Model: \(selectedModel?.name ?? "none")")
        .accessibilityValue([accessibilityEffort, workflows ? "workflows on" : nil, rays.isEmpty ? nil : raysLine].compactMap { $0 }.joined(separator: ", "))
        .task(id: "\(model.providerID(for: chat)) \(model.engineState == .ready)") { model.readModels(for: chat) }
    }

    private var name: String { selectedModel.map { Self.shortName($0.name) } ?? "Model" }

    /// The level in effect, the thread's or Default's.
    private var level: String? { shownEffort ?? model.defaultLevel(for: chat) }

    private var fast: Bool {
        PickerState(model: model, chat: chat).fastAsked
    }

    private var workflows: Bool { model.workflows(of: chat) }

    private var rays: [ModelRef] { model.rays(for: chat) }

    private var raysLine: String {
        "Rays: " + model.rayNames(for: chat).joined(separator: ", ")
    }

    private var selectedModel: ModelOption? { model.option(for: chat) }

    /// The thread's level, or with no thread the one the next starts with, if its model has it.
    private var shownEffort: String? {
        guard let effort = chat == nil ? model.startingEffort : chat?.effort,
              selectedModel?.efforts.contains(effort) == true
        else { return nil }
        return effort
    }

    private var accessibilityEffort: String {
        if let effort = shownEffort { return "Effort \(Self.effortName(effort))" }
        return model.defaultLevel(for: chat).map { "Effort \(Self.effortName($0)), the default" } ?? ""
    }

    /// What the button says: all of it, or in a narrow composer less, so the field keeps its room.
    /// The level's word goes first and the model's name after it, which leaves the agent's mark,
    /// the rays, the bolt, the workflows glyph and the chevron.
    enum Says: Comparable {
        case mark
        case name
        case all
    }

    /// A paired composer's widths under which the level's word goes, and the name with it. Measured
    /// with the widest button Claude Code's list makes, three rays, the bolt, the workflows glyph
    /// and Extra high beside its longest names: the field is 150pt or wider while a word shows.
    nonisolated static let levelFrom: CGFloat = 540
    nonisolated static let nameFrom: CGFloat = 470

    nonisolated static func says(in composer: CGFloat) -> Says {
        composer < nameFrom ? .mark : composer < levelFrom ? .name : .all
    }

    static func effortName(_ effort: String) -> String {
        switch effort {
        case "xhigh": "Extra high"
        default: effort.capitalized
        }
    }

    static func shortName(_ name: String) -> String {
        String(name.split(separator: " (").first ?? Substring(name))
    }
}

/// Why Claude Code runs a thread with fast mode on at standard speed, in the app's words.
enum FastCopy {
    static func why(_ reason: String) -> String {
        switch reason {
        case "free": "Standard speed: fast needs a paid plan"
        case "extra_usage_disabled": "Standard speed until usage credits are on"
        case "preference": "Standard speed: turned off by your organization"
        case "model_not_allowed": "Standard speed: not allowed on this model"
        case "not_first_party": "Standard speed: fast needs Anthropic's API"
        case "disabled_by_env": "Standard speed: fast is turned off on this Mac"
        case "network_error": "Couldn't check fast mode just now"
        case "pending": "Checking fast mode…"
        default: "Standard speed for now"
        }
    }
}
