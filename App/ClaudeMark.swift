import SwiftUI

/// Claude's logo, as simple-icons takes it from claude.ai: the mark other Claude clients put
/// beside a model's name, in Claude's orange.
struct ClaudeMark: View {
    var body: some View {
        Image("Claude")
            .resizable()
            .scaledToFit()
            .foregroundStyle(Ink.claude)
            .accessibilityHidden(true)
    }
}
