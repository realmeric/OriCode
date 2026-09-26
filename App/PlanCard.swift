import SwiftUI

/// Claude's plan where it was first written, kept to its latest list: a glass that fills as items
/// get done beside how many are, then the items in order. A done one is ticked and faint, the one
/// in progress lit and saying what it's doing, and a pending one plain. An item that changes
/// fades to its new state.
struct PlanCard: View {
    let plan: Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                GlassLevel(level: Double(plan.done) / Double(plan.todos.count), side: 14, fill: Ink.secondary)
                Text("\(plan.done) of \(plan.todos.count) done")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .contentTransition(.numericText(value: Double(plan.done)))
            }
            .padding(.bottom, 2)
            ForEach(Array(plan.todos.enumerated()), id: \.offset) { _, todo in
                TodoLine(todo: todo)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
        .animation(Motion.fade, value: plan)
    }
}

private struct TodoLine: View {
    let todo: Plan.Todo

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ZStack {
                switch todo.state {
                case .completed:
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Ink.faint)
                        .transition(.opacity)
                case .inProgress:
                    Bead(state: .running).transition(.opacity)
                case .pending:
                    Bead(state: .queued).transition(.opacity)
                }
            }
            .frame(width: 14, height: 14)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            Text(todo.state == .inProgress ? todo.activeForm : todo.content)
                .font(Type.body)
                .foregroundStyle(ink)
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ink: Color {
        switch todo.state {
        case .completed: Ink.faint
        case .inProgress: Ink.primary
        case .pending: Ink.secondary
        }
    }
}
