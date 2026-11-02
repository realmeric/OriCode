import AppKit
import SwiftUI

/// All of a character, as `character.read` gives it.
struct CharacterDetail: Codable, Sendable {
    var id: String?
    var name: String
    var symbol: String
    var colour: String
    var voice: String
    var work: String
    var memory: String
    var about: String
    var proposals: [CharacterProposal]
    var projects: [ProjectNotes]

    static func new(about: String) -> CharacterDetail {
        CharacterDetail(name: "", symbol: "person.fill", colour: "#6F9CF6", voice: "", work: "", memory: "", about: about, proposals: [], projects: [])
    }
}

/// What a character keeps on one project, in a file named after its folder.
struct ProjectNotes: Codable, Sendable, Identifiable, Equatable {
    let file: String
    var notes: String

    var id: String { file }
    /// The folder's name, without the hash that keeps two of one name apart.
    var name: String { file.replacing(/-[0-9a-f]{6}\.md$/, with: "") }
}

/// A change to a character's way of working it has asked for, which waits for the user.
struct CharacterProposal: Codable, Sendable, Identifiable {
    let id: String
    let thread: String
    let why: String
    let old: String
    let new: String
}

extension AppModel {
    func readCharacter(_ id: String) async -> CharacterDetail? {
        let reply = try? await engine.request("character.read", ["id": .string(id)])
        return reply?["character"].flatMap { try? $0.decode(CharacterDetail.self) }
    }

    /// The user's edit: the core and the way of working, then the notes that changed. Says when
    /// a line of them was held back as a secret.
    func saveCharacter(_ edited: CharacterDetail, was: CharacterDetail) async -> String? {
        var params: [String: JSON] = ["name": .string(edited.name), "symbol": .string(edited.symbol), "colour": .string(edited.colour), "voice": .string(edited.voice), "work": .string(edited.work)]
        if let id = edited.id { params["id"] = .string(id) }
        guard let reply = try? await engine.request("character.save", .object(params)), let id = reply["character"]?["id"]?.string else { return nil }
        var held = 0
        if edited.memory != was.memory { held += await saveNotes(["id": .string(id), "notes": .string(edited.memory)]) }
        if edited.about != was.about { held += await saveNotes(["notes": .string(edited.about)]) }
        for notes in edited.projects where !was.projects.contains(notes) {
            held += await saveNotes(["id": .string(id), "project": .string(notes.file), "notes": .string(notes.notes)])
        }
        await loadCharacters()
        if held > 0 { say("\(held) \(held == 1 ? "line" : "lines") held back: looked like a secret") }
        return id
    }

    /// How many lines the engine held back.
    private func saveNotes(_ params: [String: JSON]) async -> Int {
        let reply = try? await engine.request("character.notes", .object(params))
        return reply?["held"]?.int ?? 0
    }

    func deleteCharacter(_ id: String) async {
        _ = try? await engine.request("character.delete", ["id": .string(id)])
        await loadCharacters()
    }

    func wipeMemory(of id: String) async {
        _ = try? await engine.request("character.wipe", ["id": .string(id)])
    }

    /// Returns the way of working a taken proposal left.
    func settle(_ proposal: CharacterProposal, of id: String, take: Bool) async -> String? {
        let reply = try? await engine.request("character.proposal", ["id": .string(id), "proposal": .string(proposal.id), "take": .bool(take)])
        await loadCharacters()
        return reply?["work"]?.string
    }
}

/// Settings › Characters: who there is, and each one's files as the user can read and change them.
struct CharactersPane: View {
    @Environment(AppModel.self) private var model
    @State private var editing: CharacterDetail?
    @State private var hovered: String?

    var body: some View {
        PaneTitle(text: "Characters")
        SettingsCard {
            ForEach(model.characters) { character in
                Button {
                    Task { editing = await model.readCharacter(character.id) }
                } label: {
                    HStack(spacing: 12) {
                        CharacterMark(character: character, side: 24)
                        Text(character.name).font(.system(size: 14)).foregroundStyle(Ink.primary)
                        Spacer()
                        if character.waiting != nil {
                            Circle().fill(character.color).frame(width: 7, height: 7).help("A proposal waits")
                        }
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Ink.faint)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .background(hovered == character.id ? Surface.hover : .clear)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? character.id : nil }
            }
            Button("New character…") {
                Task {
                    var about = ""
                    if let first = model.characters.first { about = await model.readCharacter(first.id)?.about ?? "" }
                    editing = .new(about: about)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, 18)
            .frame(height: 44)
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing { CharacterEditor(character: editing) }
        }
    }
}

private struct CharacterEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var character: CharacterDetail
    private let was: CharacterDetail
    @State private var colour: Color
    @State private var askingWipe = false
    @State private var askingDelete = false

    private static let symbols = [
        "person.fill", "suit.spade.fill", "suit.heart.fill", "suit.diamond.fill", "suit.club.fill", "star.fill", "bolt.fill", "flame.fill", "leaf.fill", "moon.fill",
        "sun.max.fill", "sparkles", "crown.fill", "shield.fill", "hammer.fill", "wrench.fill", "paintbrush.fill", "pencil", "book.fill", "graduationcap.fill",
        "lightbulb.fill", "eye.fill", "hare.fill", "tortoise.fill", "ladybug.fill", "ant.fill", "pawprint.fill", "bird.fill", "fish.fill", "cat.fill", "dog.fill",
    ]

    init(character: CharacterDetail) {
        _character = State(initialValue: character)
        was = character
        _colour = State(initialValue: CharacterInfo(id: "", name: "", symbol: "", colour: character.colour).color)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        CharacterMark(character: info, side: 40)
                        TextField("Name", text: $character.name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 20, weight: .semibold))
                        Picker("Icon", selection: $character.symbol) {
                            ForEach(Self.symbols, id: \.self) { Image(systemName: $0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        ColorPicker("Colour", selection: $colour, supportsOpacity: false)
                            .labelsHidden()
                    }
                    field("Personality and voice", text: $character.voice, height: 110)
                    field("Way of working", text: $character.work, height: 160)
                    ForEach(character.proposals) { proposal in
                        ProposalCard(proposal: proposal) { take in
                            Task {
                                guard let id = character.id else { return }
                                let work = await model.settle(proposal, of: id, take: take)
                                if let work { character.work = work }
                                character.proposals.removeAll { $0.id == proposal.id }
                            }
                        }
                    }
                    field("Memory", text: $character.memory, height: 180)
                    ForEach($character.projects) { $notes in
                        field("Memory on \(notes.name)", text: $notes.notes, height: 90)
                    }
                    field("Shared by all characters", text: $character.about, height: 90)
                }
                .padding(20)
            }
            HStack {
                if let id = character.id {
                    Button("Delete…", role: .destructive) { askingDelete = true }
                    Button("Wipe memory…") { askingWipe = true }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Build.support.appending(path: "Characters/\(id)/memory.md")])
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    character.colour = hex(colour)
                    Task {
                        _ = await model.saveCharacter(character, was: was)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(character.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 620, height: 680)
        .confirmationDialog("Wipe \(character.name)'s memory?", isPresented: $askingWipe) {
            Button("Wipe Memory", role: .destructive) {
                guard let id = character.id else { return }
                Task {
                    await model.wipeMemory(of: id)
                    dismiss()
                }
            }
        } message: {
            Text("Its notes and their earlier versions are removed. This can't be undone.")
        }
        .confirmationDialog("Delete \(character.name)?", isPresented: $askingDelete) {
            Button("Delete Character", role: .destructive) {
                guard let id = character.id else { return }
                Task {
                    await model.deleteCharacter(id)
                    dismiss()
                }
            }
        } message: {
            Text("Its files are removed, and its threads go on as plain threads.")
        }
    }

    private var info: CharacterInfo {
        CharacterInfo(id: character.id ?? "", name: character.name, symbol: character.symbol, colour: hex(colour))
    }

    private func field(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Type.secondary).foregroundStyle(Ink.secondary)
            TextEditor(text: text)
                .font(Type.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: height)
                .background(Surface.card, in: .rect(cornerRadius: 10, style: .continuous))
        }
    }

    private func hex(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return character.colour }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}

/// A way-of-working change as it would read, with why the character asks for it.
private struct ProposalCard: View {
    let proposal: CharacterProposal
    let settle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(proposal.why).font(Type.body).foregroundStyle(Ink.primary)
            Text(proposal.thread).font(Type.secondary).foregroundStyle(Ink.faint)
            if !proposal.old.isEmpty {
                Text(proposal.old).font(Type.mono).foregroundStyle(Ink.deleted).textSelection(.enabled)
            }
            Text(proposal.new).font(Type.mono).foregroundStyle(Ink.added).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Leave It") { settle(false) }
                Button("Take It") { settle(true) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: .rect(cornerRadius: 10, style: .continuous))
    }
}
