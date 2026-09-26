import SwiftUI

struct SlashCommandInfo: Codable, Hashable, Sendable, Identifiable {
    let name: String
    let description: String
    /// Missing for commands that take no arguments.
    let hint: String?

    var id: String { name }
}

extension AppModel {
    func loadCommands(for chat: Chat) {
        let cwd = chat.cwd
        guard slashCommands[cwd] == nil else { return }
        slashCommands[cwd] = []
        Task {
            let reply = try? await engine.request("commands", ["threadId": .string(chat.id.uuidString), "cwd": .string(cwd)])
            let commands: [SlashCommandInfo]
            do {
                commands = try reply?["commands"]?.decode([SlashCommandInfo].self) ?? []
            } catch {
                Engine.logger.error("commands didn't decode: \(String(describing: error), privacy: .public)")
                commands = []
            }
            if commands.isEmpty { slashCommands[cwd] = nil } else { slashCommands[cwd] = commands }
        }
    }
}

/// The list above the capsule while the message starts with "/".
struct SlashMenu: View {
    let commands: [SlashCommandInfo]
    let selected: Int
    let pick: (SlashCommandInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                Button {
                    pick(command)
                } label: {
                    HStack(spacing: 10) {
                        Text("/" + command.name)
                            .font(Type.mono)
                            .foregroundStyle(Ink.primary)
                        if let hint = command.hint, !hint.isEmpty {
                            Text(hint).font(Type.mono).foregroundStyle(Ink.faint)
                        }
                        Text(command.description)
                            .font(Type.secondary)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(index == selected ? Surface.selected : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .background(Surface.drawer, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// Tab's matches when there's more than one, above the capsule the way the slash menu is: the
/// first twelve, each with what zsh says of it, and how many more.
struct CompletionMenu: View {
    let candidates: [String]
    let descriptions: [String: String]
    let selected: Int?
    let pick: (Int) -> Void

    private static let shown = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let start = max(0, min((selected ?? 0) - Self.shown / 2, candidates.count - Self.shown))
            ForEach(Array(candidates.enumerated().dropFirst(start).prefix(Self.shown)), id: \.offset) { index, candidate in
                Button {
                    pick(index)
                } label: {
                    HStack(spacing: 10) {
                        Text(candidate)
                            .font(Type.mono)
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .layoutPriority(1)
                        if let description = descriptions[candidate] {
                            Text(description)
                                .font(Type.secondary)
                                .foregroundStyle(Ink.faint)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                    .background(index == selected ? Surface.selected : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            if candidates.count > Self.shown {
                Text("\(candidates.count) matches")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.faint)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .background(Surface.drawer, in: .rect(cornerRadius: 14, style: .continuous))
    }
}
