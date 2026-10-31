import AppKit
import SwiftUI

/// A project's two letters on its colour, beside its name over its threads in the drawer and at
/// the start of each capsule on home. No folder has no colour and no letters: a laptop, in the ink
/// the rest of the row is in.
struct ProjectBadge: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let color = project.isNoFolder ? Ink.secondary : ProjectColor.of(project)
        Group {
            if project.isNoFolder {
                Image(systemName: "laptopcomputer")
            } else {
                Text(model.initials[project.id] ?? project.initials)
            }
        }
        .font(.system(size: 9.5, weight: .bold, design: .rounded))
        .foregroundStyle(color)
        .frame(width: 22, height: 16)
        .background(color.opacity(0.18), in: .rect(cornerRadius: 5, style: .continuous))
        .accessibilityLabel(project.name)
    }
}

extension Project {
    /// The first and last letters of the name: OriCode is OE.
    var initials: String {
        Self.choices(for: name).first ?? "?"
    }

    /// Every project's letters, the first added keeping its own and each after it taking the
    /// next of its choices no project before it has: oricode-deneme beside OriCode is OD.
    static func initials(of projects: [Project]) -> [UUID: String] {
        var taken: Set<String> = []
        var letters: [UUID: String] = [:]
        for project in projects.sorted(by: { $0.createdAt < $1.createdAt }) where !project.isNoFolder {
            let choices = choices(for: project.name)
            let pick = choices.first { !taken.contains($0) } ?? choices.first ?? "?"
            taken.insert(pick)
            letters[project.id] = pick
        }
        return letters
    }

    /// The letters a name can go by, best first: its first and last, its first and the start of
    /// each later word, then its first and each later letter.
    static func choices(for name: String) -> [String] {
        let characters = Array(name)
        let letters = characters.filter { $0.isLetter || $0.isNumber }
        guard let first = letters.first.map({ String($0).uppercased() }) else { return ["?"] }
        guard letters.count > 1, let last = letters.last else { return [first] }
        var words: [Character] = []
        for (index, character) in characters.enumerated() where index > 0 && (character.isLetter || character.isNumber) {
            let before = characters[index - 1]
            if !(before.isLetter || before.isNumber) || (character.isUppercase && before.isLowercase) { words.append(character) }
        }
        var seen: Set<String> = []
        return ([last] + words + letters.dropFirst()).map { first + String($0).uppercased() }.filter { seen.insert($0).inserted }
    }
}

/// The colours a project can get. They read on the glass and stay clear of the ones that already
/// mean something: Claude's orange, the usage bands, the diff's green and red.
enum ProjectColor {
    static let palette: [Color] = [
        Color(red: 0x6F / 255, green: 0x9C / 255, blue: 0xF6 / 255),
        Color(red: 0xA7 / 255, green: 0x8B / 255, blue: 0xFA / 255),
        Color(red: 0xF0 / 255, green: 0x7A / 255, blue: 0xB6 / 255),
        Color(red: 0x3F / 255, green: 0xC4 / 255, blue: 0xBE / 255),
        Color(red: 0xA6 / 255, green: 0xCF / 255, blue: 0x5B / 255),
        Color(red: 0xD8 / 255, green: 0xB2 / 255, blue: 0x6E / 255),
        Color(red: 0xD5 / 255, green: 0x7F / 255, blue: 0xEA / 255),
        Color(red: 0x9A / 255, green: 0xA8 / 255, blue: 0xC7 / 255),
    ]

    static func of(_ project: Project) -> Color {
        palette[(project.colorIndex ?? 0) % palette.count]
    }

    /// A colour from those the fewest projects have, so no two share one until all eight are
    /// taken, and of those the hue furthest from every one taken, so two violets don't sit side
    /// by side; at random among those as far.
    static func pick(taken: [Int]) -> Int {
        let uses = palette.indices.map { index in taken.filter { $0 == index }.count }
        let fewest = uses.min() ?? 0
        let free = palette.indices.filter { uses[$0] == fewest }
        let hues = Set(taken).map(hue)
        func apart(_ index: Int) -> Double {
            hues.map { abs(hue(index) - $0) }.map { min($0, 1 - $0) }.min() ?? 1
        }
        let furthest = free.map(apart).max() ?? 0
        return free.filter { apart($0) >= furthest - 0.0001 }.randomElement() ?? 0
    }

    /// Where a palette colour sits around the wheel, 0 to 1.
    private static func hue(_ index: Int) -> Double {
        Double(NSColor(palette[index % palette.count]).usingColorSpace(.sRGB)?.hueComponent ?? 0)
    }
}
