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
    /// The button's frame in the window, for how much room the picker has above it.
    @State private var frame = CGRect.zero

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
                    // Lit once the CLI serves it, faint while it checks or cools down, and
                    // struck through when it won't, so that shows without opening the picker.
                    Image(systemName: fastState.map { $0 != "on" && $0 != "cooldown" } ?? false ? "bolt.slash" : "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(fastState == "on" ? Ink.primary : Ink.faint)
                        .help(fastState == "on" ? "Fast mode" : "Fast mode isn't running right now")
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        // From the button's right end, which stays put while its label grows leftwards with
        // the effort and the bolt, so the picker doesn't drift as choices change.
        .popover(isPresented: Binding(get: { model.modelPickerShown }, set: { model.modelPickerShown = $0 }),
                 attachmentAnchor: .point(.trailing), arrowEdge: .top) {
            // The whole picker, its arrow and a little margin, or the compact one.
            ModelPicker(chat: chat, compact: roomAbove < ModelPicker.height + 13 + 8)
        }
        .help("Model and permission mode")
        .accessibilityLabel("Model: \(selectedModel?.name ?? "none")")
        .accessibilityValue(accessibilityEffort)
    }

    private var fast: Bool {
        chat.map(model.fastMode(of:)) ?? false
    }

    /// Between the button's top and the top of the screen: a popover taller than that opens off
    /// to the side, clipped.
    private var roomAbove: CGFloat {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }),
              let screen = window.screen
        else { return .infinity }
        return screen.visibleFrame.maxY - (window.frame.maxY - frame.minY)
    }

    /// What the CLI last said about fast mode for the thread.
    private var fastState: String? {
        chat.flatMap { model.conversations[$0.id]?.fastState }
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

/// The CLI's reasons fast mode can't run, in the app's words.
enum FastCopy {
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
