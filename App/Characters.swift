import SwiftUI

/// A character as the engine lists it. Its files are the engine's to read and write.
struct CharacterInfo: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    /// An SF Symbol's name.
    let symbol: String
    /// `#RRGGBB`.
    let colour: String
    /// How many proposals wait, when any do.
    var waiting: Int?

    var color: Color {
        let value = UInt32(colour.dropFirst(), radix: 16) ?? 0x9AA8C7
        return Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

extension AppModel {
    func loadCharacters() async {
        guard let reply = try? await engine.request("characters.list"), let listed = reply["characters"].flatMap({ try? $0.decode([CharacterInfo].self) }) else { return }
        characters = listed
    }

    func character(of chat: Chat) -> CharacterInfo? {
        guard let id = chat.character else { return nil }
        return characters.first { $0.id == id }
    }

    /// How long a thread stays quiet before a memory pass reads it: long enough to outlast a CLI
    /// kept idle, so the notes it changes reopen no running session.
    static let quietBeforeRemembering: Duration = .seconds(120)

    /// A memory pass once the thread has been quiet a while. One timer and no polling; a new turn's
    /// end starts it again, so a long back and forth is one pass.
    func rememberSoon(_ chat: Chat) {
        guard chat.character != nil, chat.agentID == nil else { return }
        rememberings[chat.id]?.cancel()
        let id = chat.id
        rememberings[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.quietBeforeRemembering)
            guard !Task.isCancelled, let self else { return }
            rememberings[id] = nil
            if let chat = self.chat(withID: id) { remember(chat) }
        }
    }

    /// What the thread said since the last pass goes to the engine's small model. Off every path
    /// the user feels, and a failure only means the next pass reads this too.
    func remember(_ chat: Chat) {
        guard let character = chat.character, let conversation = conversations[chat.id], !conversation.running else { return }
        let (thread, last) = CharacterMemory.new(in: conversation.items, after: chat.remembered)
        guard !thread.isEmpty, let last else { return }
        var params: [String: JSON] = ["character": .string(character), "thread": .string(thread), "title": .string(chat.title), "cwd": .string(chat.cwd)]
        if let project = chat.project, !project.isNoFolder { params["project"] = .string(project.path) }
        Task {
            guard let reply = try? await engine.request("character.remember", .object(params.naming(chat.providerID))) else { return }
            chat.remembered = last
            save()
            if reply["proposed"]?.bool == true, let name = self.character(of: chat)?.name {
                conversation.note("\(name) has a proposal: Settings › Characters")
            }
        }
    }

    /// ⌘K's New thread as Hans.
    func openThread(as character: String) {
        openNewThread()
        if let chat, !chat.started { setCharacter(character, of: chat, state: composer(for: chat)) }
    }

    func setCharacter(_ id: String?, of chat: Chat?, state: ComposerState) {
        state.character = id
        guard let chat else { return }
        chat.character = id
        save()
    }
}

/// What a memory pass reads of a thread: what was said and answered and no tool's call or output,
/// so what a command printed, a secret out of OriPass among it, never comes near a character's
/// memory. Empty when the user has said nothing since the last pass.
enum CharacterMemory {
    static func new(in items: [Item], after remembered: UUID?) -> (thread: String, last: UUID?) {
        let start = remembered.flatMap { id in items.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        let unread = items[start...]
        var lines: [String] = []
        var said = false
        for item in unread {
            switch item {
            case .user(_, let text, _, _):
                lines.append("User: \(text)")
                said = true
            case .text(_, let text) where !text.isEmpty:
                lines.append("Assistant: \(text)")
            default:
                break
            }
        }
        return said ? (lines.joined(separator: "\n"), unread.last?.id) : ("", nil)
    }
}

/// A character's icon on its colour, as a project's badge is its letters on its own.
struct CharacterMark: View {
    let character: CharacterInfo
    var side: CGFloat = 16

    var body: some View {
        Image(systemName: character.symbol)
            .font(.system(size: side * 0.56, weight: .semibold))
            .foregroundStyle(character.color)
            .frame(width: side, height: side)
            .background(character.color.opacity(0.18), in: .circle)
            .accessibilityLabel(character.name)
    }
}

/// Who answers, over the first thing a turn shows.
struct CharacterHead: View {
    let character: CharacterInfo

    var body: some View {
        HStack(spacing: 6) {
            CharacterMark(character: character, side: 18)
            Text(character.name)
                .font(Type.secondary.weight(.medium))
                .foregroundStyle(character.color)
        }
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Who a thread runs as, picked while it's a draft, as its agent is.
struct CharacterMenu: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    let state: ComposerState
    @State private var hovered = false

    var body: some View {
        let id = chat == nil ? state.character : chat?.character
        let chosen = model.characters.first { $0.id == id }
        Menu {
            Picker("Character", selection: Binding(get: { id }, set: { model.setCharacter($0, of: chat, state: state) })) {
                Text("No character").tag(String?.none)
                ForEach(model.characters) { character in
                    Label(character.name, systemImage: character.symbol).tag(String?.some(character.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Group {
                if let chosen {
                    CharacterMark(character: chosen, side: 20)
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(hovered ? Ink.primary : Ink.secondary)
                }
            }
            .frame(width: 30, height: 30)
            .background(hovered ? Surface.hover : .clear, in: .circle)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help(chosen?.name ?? "Character")
        .accessibilityLabel(chosen?.name ?? "Character")
    }
}
