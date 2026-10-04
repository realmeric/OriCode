import SwiftUI

/// An MCP server Claude Code loads for a folder, as the engine lists it.
struct MCPServer: Decodable, Identifiable, Equatable {
    let name: String
    let status: String
    let scope: String?
    let error: String?
    let tools: Int
    let target: String?

    var id: String { name }

    var on: Bool { status != "disabled" }

    /// Where it has got, in a line.
    var line: String {
        let state: String
        switch status {
        case "connected": state = tools == 1 ? "Connected, 1 tool" : "Connected, \(tools) tools"
        case "failed": state = "Couldn't start" + (error.map { ": \($0)" } ?? "")
        case "needs-auth": state = "Needs a sign-in: run claude in Terminal, type /mcp and choose it"
        case "pending": state = "Connecting…"
        case "disabled": state = "Off for this project"
        default: state = status
        }
        return [state, whose, target].compactMap { $0 }.joined(separator: " · ")
    }

    private var whose: String? {
        switch scope {
        case "user": "every project's"
        case "project": "this project's, in .mcp.json"
        case "local": "this project's, yours alone"
        default: scope
        }
    }

    /// The scopes `claude mcp remove` takes one out of.
    var removable: Bool { ["user", "project", "local"].contains(scope ?? "") }
}

/// Settings › MCP: the servers Claude Code loads for a project, each with where it has got and a
/// switch, and a server added by its URL or its command. All of it goes through the user's own
/// CLI, which keeps its own configuration.
struct MCPPane: View {
    @Environment(AppModel.self) private var model
    @State private var projectID: UUID?
    @State private var servers: [MCPServer] = []
    @State private var loading = false
    @State private var problem: String?
    @State private var name = ""
    @State private var target = ""
    @State private var scope = "local"

    private var project: Project? {
        model.projects.first { $0.id == projectID } ?? model.project ?? model.projects.first
    }

    var body: some View {
        PaneTitle(text: "MCP")
        if model.projects.isEmpty {
            Text("Add a project first: Claude Code loads its MCP servers for a folder.")
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .padding(.top, 12)
        } else {
            SectionHeading("Claude Code's servers")
            SettingsCard {
                SettingsRow(title: "Project", detail: "Its servers, and the ones every project has.") {
                    HStack(spacing: 8) {
                        if loading { ProgressView().controlSize(.small) }
                        Picker("Project", selection: Binding(get: { project?.id }, set: { projectID = $0 })) {
                            ForEach(model.projects) { project in
                                Text(project.name).tag(Optional(project.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                ForEach(servers) { server in
                    SettingsRow(title: server.name, detail: server.line) {
                        HStack(spacing: 10) {
                            if server.removable {
                                Button("Remove") { call("mcp.remove", ["name": .string(server.name), "scope": .string(server.scope ?? "local")]) }
                                    .buttonStyle(.action(small: true))
                            }
                            Toggle(server.name, isOn: Binding(get: { server.on }, set: { on in
                                call("mcp.toggle", ["name": .string(server.name), "on": .bool(on)])
                            }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                        .disabled(loading)
                    }
                }
                if servers.isEmpty, !loading, problem == nil {
                    SettingsRow(title: "No servers", detail: "Claude Code loads none for this project.")
                }
            }
            if let problem {
                Text(problem)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .padding(.top, 8)
            }
            SectionHeading("Add a server")
            SettingsCard {
                SettingsRow(title: "Name", detail: "Letters, digits, dashes and underscores.") {
                    TextField("Name", text: $name, prompt: Text("linear"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .autocorrectionDisabled()
                }
                SettingsRow(title: "URL or command", detail: "A URL is an HTTP server; anything else is the command that starts one.") {
                    TextField("URL or command", text: $target, prompt: Text(verbatim: "https://mcp.linear.app/mcp"))
                        .textFieldStyle(.roundedBorder)
                        .font(Type.mono)
                        .frame(width: 260)
                        .autocorrectionDisabled()
                }
                SettingsRow(title: "For", detail: "A server that asks for a sign-in gets it in Terminal: run claude, type /mcp and choose it.") {
                    HStack(spacing: 10) {
                        Picker("For", selection: $scope) {
                            Text("This project").tag("local")
                            Text("Every project").tag("user")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        Button("Add") {
                            call("mcp.add", ["name": .string(name.trimmingCharacters(in: .whitespaces)), "target": .string(target), "scope": .string(scope)]) {
                                name = ""
                                target = ""
                            }
                        }
                        .buttonStyle(.action(small: true))
                        .disabled(loading || name.trimmingCharacters(in: .whitespaces).isEmpty || target.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            Text("These are Claude Code's own, kept in its configuration and loaded by every thread on it from its next session. Other agents keep their servers in their own settings.")
                .font(Type.secondary)
                .foregroundStyle(Ink.faint)
                .padding(.top, 10)
                .task(id: project?.id) { call("mcp.list", [:]) }
        }
    }

    /// One of the engine's MCP calls for the chosen project, each of which answers with the list.
    private func call(_ method: String, _ params: [String: JSON], then: @escaping () -> Void = {}) {
        guard let project else { return }
        let asked = project.id
        var params = params
        params["cwd"] = .string(project.path)
        loading = true
        problem = nil
        Task {
            do {
                let reply = try await model.engine.request(method, .object(params))
                guard asked == self.project?.id else { return }
                servers = try reply["servers"]?.decode([MCPServer].self) ?? []
                then()
            } catch {
                guard asked == self.project?.id else { return }
                problem = error.localizedDescription
            }
            loading = false
        }
    }
}
