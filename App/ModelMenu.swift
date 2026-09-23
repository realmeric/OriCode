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
                Text(selectedModel.map { Self.shortName($0.name) } ?? "Model")
                    .foregroundStyle(Ink.primary)
                if let effort = shownEffort {
                    Text(Self.effortName(effort))
                        .foregroundStyle(Ink.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
            }
            .font(Type.secondary)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(hovering || model.modelPickerShown ? Surface.hover : .clear, in: .capsule)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .popover(isPresented: Binding(get: { model.modelPickerShown }, set: { model.modelPickerShown = $0 }), arrowEdge: .top) {
            ModelPanel(chat: chat, selectedModel: selectedModel, effort: effortBinding, mode: modeBinding)
        }
        .help("Model and permission mode")
        .accessibilityLabel("Model: \(selectedModel?.name ?? "none")")
    }

    private var selectedModel: ModelOption? {
        let id = chat?.model ?? model.lastModel
        return model.models.first { $0.id == id } ?? model.models.first
    }

    private var shownEffort: String? {
        guard let effort = chat?.effort ?? (chat == nil ? model.lastEffort : nil), !effort.isEmpty else { return nil }
        return effort
    }

    static func effortName(_ effort: String) -> String {
        effort == "xhigh" ? "Extra high" : effort.capitalized
    }

    static func shortName(_ name: String) -> String {
        String(name.split(separator: " (").first ?? Substring(name))
    }

    private var effortBinding: Binding<String> {
        Binding {
            chat?.effort ?? ""
        } set: { effort in
            model.setEffort(effort.isEmpty ? nil : effort, for: chat)
        }
    }

    private var modeBinding: Binding<String> {
        Binding {
            chat?.permissionMode ?? model.lastPermissionMode
        } set: { mode in
            model.setPermissionMode(mode, for: chat)
        }
    }
}

/// What the model button opens.
private struct ModelPanel: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    let selectedModel: ModelOption?
    @Binding var effort: String
    @Binding var mode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            heading("Model")
            ForEach(model.models) { option in
                PickerRow(title: option.name, detail: option.description, chosen: option.id == selectedModel?.id) {
                    model.setModel(option.id, for: chat)
                }
            }
            if let efforts = selectedModel?.efforts, !efforts.isEmpty {
                heading("Effort")
                Picker("Effort", selection: $effort) {
                    Text("Default").tag("")
                    ForEach(efforts, id: \.self) { Text(ModelMenu.effortName($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
            heading("Permissions")
            ForEach(PermissionModeOption.allCases) { option in
                PickerRow(icon: option.icon, title: option.title, detail: option.summary, chosen: option.rawValue == mode) {
                    mode = option.rawValue
                }
            }
        }
        .padding(8)
        // Wide enough for six effort levels side by side.
        .frame(width: 380)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Ink.faint)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

/// One choice in the picker: lit on hover like the drawer's rows, checked when it's the one.
private struct PickerRow: View {
    var icon: String?
    let title: String
    let detail: String
    let chosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Type.body)
                        .foregroundStyle(Ink.primary)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(Type.secondary)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovering ? Surface.hover : .clear, in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
