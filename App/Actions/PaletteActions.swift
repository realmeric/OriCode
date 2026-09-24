import Foundation

/// Your own actions as ⌘K rows: run as a block in the thread, or quietly by the engine with their
/// last line as the note under the composer.
extension AppModel {
    /// What the placeholders stand for in the open thread.
    var actionValues: ActionValues {
        let branch = currentBranch?.branch
        return ActionValues(
            cwd: workingFolder, project: project?.path, projectName: project?.name,
            branch: branch == "HEAD" ? nil : branch,
            thread: chat?.started == true ? chat?.title : nil,
            session: chat?.sessionId)
    }

    var customActionCommands: [PaletteItem] {
        let values = actionValues
        return customActions.actions
            .filter { $0.project == nil || $0.project == project?.id }
            .map { action in
                PaletteItem(id: "action." + action.id.uuidString, kind: .command, title: action.name,
                            subtitle: action.runs == .quietly ? "Runs quietly" : nil, keywords: ["action", action.command],
                            icon: action.runs == .quietly ? "bolt" : "apple.terminal",
                            unavailable: workingFolder == nil ? "Add a project first" : ActionLine.unavailable(action.command, with: values),
                            action: paletteAction(for: action, values: values))
            }
    }

    /// An action that takes {input} asks for it in the field and shows the whole line under it
    /// as it's typed, so Return is the look before running. One that asks first shows its line
    /// as a Run row.
    private func paletteAction(for action: CustomAction, values: ActionValues) -> PaletteAction {
        if action.wantsInput {
            return .input(PaletteInput(title: action.name, placeholder: "What goes in {input}", hint: { text in
                text.isEmpty ? .none : .info(ActionLine.expand(action.command, with: values, input: text))
            }, submit: { [weak self] text in
                guard !text.isEmpty else { throw EngineError.remote("Type what goes in {input} first.") }
                return try await self?.run(action, line: ActionLine.expand(action.command, with: values, input: text))
            }))
        }
        let line = ActionLine.expand(action.command, with: values)
        let run: PaletteAction = action.runs == .terminal
            ? .run { [weak self] in _ = self?.runInThread(line) }
            : .task("Running \(action.name)…") { [weak self] in try await self?.run(action, line: line) }
        guard action.asks else { return run }
        return .list(PaletteList(title: action.name, placeholder: "Return runs it") {
            [PaletteItem(id: "action.run", kind: .choice, title: "Run", subtitle: line, icon: "return", action: run)]
        })
    }

    private func run(_ action: CustomAction, line: String) async throws -> String? {
        guard action.runs == .quietly else {
            runInThread(line)
            return nil
        }
        guard let folder = workingFolder else { return nil }
        let reply = try await engine.request("shell.run", ["cwd": .string(folder), "command": .string(line)])
        let code = reply["code"]?.int ?? 1
        let last = reply["line"]?.string ?? ""
        // A failure stays in ⌘K, where it can be read, instead of passing as a note.
        guard code == 0 else { throw EngineError.remote(last.isEmpty ? "\(action.name) stopped with exit code \(code)." : last) }
        return last.isEmpty ? "\(action.name) is done." : last
    }
}
