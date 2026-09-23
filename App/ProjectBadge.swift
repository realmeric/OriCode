import SwiftUI

/// A project's two letters on its colour, at the start of each of its threads, so threads from
/// different projects can share one list.
struct ProjectBadge: View {
    let project: Project

    var body: some View {
        let color = ProjectColor.of(project)
        Text(project.initials)
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
        let letters = name.filter { $0.isLetter || $0.isNumber }
        guard let first = letters.first else { return "?" }
        guard letters.count > 1, let last = letters.last else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
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

    /// A colour at random from those the fewest projects have, so no two share one until all
    /// eight are taken.
    static func pick(taken: [Int]) -> Int {
        let uses = palette.indices.map { index in taken.filter { $0 == index }.count }
        let fewest = uses.min() ?? 0
        return palette.indices.filter { uses[$0] == fewest }.randomElement() ?? 0
    }
}
