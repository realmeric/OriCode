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
                if fast {
                    // On the way the user turned it on; the tooltip says so when Claude Code
                    // runs the thread at standard speed anyway.
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Ink.primary)
                        .help(PickerState(model: model, chat: chat).fastProblem ?? "Fast mode")
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                // The level in effect: faint when it's Default's, brighter when picked, and at
                // full strength while Ultracode is on, so a thread can't stay on it unnoticed.
                if let level = shownEffort ?? model.defaultLevel(for: chat) {
                    Text(Self.effortName(level))
                        .foregroundStyle(level == Effort.ultracode ? Ink.primary : shownEffort == nil ? Ink.faint : Ink.secondary)
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
            .animation(Motion.move, value: [selectedModel?.id, shownEffort, fast ? "fast" : nil])
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(hovering || model.modelPickerShown ? Surface.hover : .clear, in: .capsule)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.modelButtonFrame = $0 }
        .help("Model and permission mode")
        .accessibilityLabel("Model: \(selectedModel?.name ?? "none")")
        .accessibilityValue(accessibilityEffort)
    }

    private var fast: Bool {
        PickerState(model: model, chat: chat).fastAsked
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
