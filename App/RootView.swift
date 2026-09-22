import SwiftUI

struct RootView: View {
    @AppStorage(Glass.key) private var glass = Glass.defaultTint

    var body: some View {
        ZStack {
            Color.black.opacity(glass)
                .ignoresSafeArea()
            EmptyStateView(line: "Add a project to start.")
        }
    }
}

struct EmptyStateView: View {
    let line: String

    var body: some View {
        VStack(spacing: 14) {
            Mark()
            Text(line)
                .font(Type.body)
                .foregroundStyle(Ink.secondary)
        }
    }
}

/// Stand-in for the mark Meriç supplies: a plain ring.
struct Mark: View {
    var body: some View {
        Circle()
            .stroke(Ink.secondary, lineWidth: 2.5)
            .frame(width: 40, height: 40)
            .frame(width: 44, height: 44)
    }
}
