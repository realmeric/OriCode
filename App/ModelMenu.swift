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
            Text(label)
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model and permission mode")
    }

    private var selectedModel: ModelOption? {
        let id = chat?.model ?? model.lastModel
        return model.models.first { $0.id == id } ?? model.models.first
    }

    private var label: String {
        var parts = [selectedModel.map { Self.shortName($0.name) } ?? "Model"]
        if let effort = chat?.effort ?? (chat == nil ? model.lastEffort : nil), !effort.isEmpty {
            parts.append(effort)
        }
        return parts.joined(separator: " · ")
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
