import Foundation

/// Claude's plan as a TodoWrite call wrote it: its items in order, each pending, in progress or
/// done. Read from the call's input, so another agent's plan tool with the same shape fills it too.
struct Plan: Hashable {
    struct Todo: Hashable {
        enum State: String {
            case pending
            case inProgress = "in_progress"
            case completed
        }

        let content: String
        /// What it says while in progress: "Running the tests".
        let activeForm: String
        let state: State
    }

    let todos: [Todo]
    let done: Int

    /// Nil for an input with no list, which is how Claude clears its plan.
    init?(_ input: JSON) {
        guard let todos = input["todos"]?.array, !todos.isEmpty else { return nil }
        self.todos = todos.map { todo in
            let content = todo["content"]?.string ?? ""
            return Todo(
                content: content,
                activeForm: todo["activeForm"]?.string ?? content,
                state: Todo.State(rawValue: todo["status"]?.string ?? "") ?? .pending)
        }
        done = self.todos.count { $0.state == .completed }
    }

    var finished: Bool {
        done == todos.count
    }

    /// The item in progress, which the heads' main loop row says.
    var current: Todo? {
        todos.first { $0.state == .inProgress }
    }

    /// Whether a later list carries this plan on, on its card, rather than starting a card of its
    /// own: this one isn't finished, and at least half of the later list's items are in it.
    func continues(into next: Plan) -> Bool {
        guard !finished else { return false }
        let known = Set(todos.map(\.content))
        return next.todos.count { known.contains($0.content) } * 2 >= next.todos.count
    }
}
