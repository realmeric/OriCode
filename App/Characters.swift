import SwiftUI

/// A character as the engine lists it. Its files are the engine's to read and write.
struct CharacterInfo: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    /// An SF Symbol's name.
    let symbol: String
    /// `#RRGGBB`.
    let colour: String

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

    func setCharacter(_ id: String?, of chat: Chat?, state: ComposerState) {
        state.character = id
        guard let chat else { return }
        chat.character = id
        save()
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
