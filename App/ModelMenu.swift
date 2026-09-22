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

/// The small menu at the capsule's left end: model, effort and permission mode.
struct ModelMenu: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    @State private var hovering = false

    var body: some View {
        Menu {
            Picker("Model", selection: modelBinding) {
                ForEach(model.models) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .pickerStyle(.inline)
            if let efforts = selectedModel?.efforts, !efforts.isEmpty {
                Picker("Effort", selection: effortBinding) {
                    Text("Default").tag("")
                    ForEach(efforts, id: \.self) { effort in
                        Text(Self.effortName(effort)).tag(effort)
                    }
                }
                .pickerStyle(.inline)
            }
            Picker("Permission mode", selection: modeBinding) {
                ForEach(PermissionModeOption.allCases) { option in
                    Button {} label: {
                        Text(option.title)
                        Text(option.summary)
                    }
                    .tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Burst()
                    .fill(Ink.claude)
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
            .background(hovering ? Surface.hover : .clear, in: .capsule)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Model and permission mode")
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

    private var modelBinding: Binding<String> {
        Binding {
            selectedModel?.id ?? ""
        } set: { id in
            model.setModel(id, for: chat)
        }
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
