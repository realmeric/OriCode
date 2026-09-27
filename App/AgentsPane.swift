import AppKit
import SwiftUI

/// Settings › Agents: a card for each agent, whether it's on and, while it is, its CLI, its key and
/// the logins its maker forbids for third-party apps.
struct AgentsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneTitle(text: "Agents")
        Text("Each runs through its own CLI and the login you made in Terminal. Only the ones turned on are looked for.")
            .font(Type.secondary)
            .foregroundStyle(Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        if model.agents.isEmpty {
            Text("The agents are listed once the engine is running.")
                .font(Type.secondary)
                .foregroundStyle(Ink.faint)
                .padding(.top, 22)
        } else {
            SectionHeading("With a CLI of their own")
            cards(model.agents.filter(\.binary))
            SectionHeading("Model APIs")
            cards(model.agents.filter { !$0.binary })
        }
    }

    private func cards(_ agents: [AgentInfo]) -> some View {
        VStack(spacing: 12) {
            ForEach(agents) { AgentCard(agent: $0) }
        }
        .onAppear {
            model.refreshKeys()
            model.askUnasked()
        }
    }
}

private struct AgentCard: View {
    @Environment(AppModel.self) private var model
    let agent: AgentInfo
    @State private var key = ""
    @State private var refused: String?

    private var on: Bool { model.agentSettings.isOn(agent.id) }
    private var entry: ProviderInfo? { model.providers.first { $0.id == agent.id } }
    private var isClaude: Bool { agent.id == ProviderInfo.claudeID }

    var body: some View {
        SettingsCard {
            row(agent.name, detail: agent.status(entry, on: on, checking: model.checkingAgents.contains(agent.id))) {
                // Claude Code's threads and hello's models are its own, so it has no switch.
                if !isClaude {
                    Toggle(agent.name, isOn: Binding(get: { on }, set: { model.turnAgent(agent.id, on: $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            if on, agent.binary { cliRow }
            if on, agent.key { keyRow }
            if on {
                ForEach(agent.forbidden) { login in forbiddenRow(login) }
            }
        }
        .animation(Motion.fade, value: on)
    }

    /// A settings row whose line may carry a Terminal command in backticks; a path is read verbatim.
    private func row<Control: View>(_ title: String, detail: String, verbatim: Bool = false, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14)).foregroundStyle(Ink.primary)
                Group {
                    if verbatim { Text(verbatim: detail) } else { Text(LocalizedStringKey(detail)) }
                }
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var cliRow: some View {
        let chosen = model.agentSettings.path(agent.id)
        let path = chosen ?? entry?.cli
        let version = entry?.version.map { " · \($0)" } ?? ""
        return row("CLI", detail: path.map { $0 + version } ?? "Not found on its own. Choose it if it's installed.", verbatim: path != nil) {
            HStack(spacing: 8) {
                if chosen != nil {
                    Button("Automatic") { model.chooseAgentPath(nil, for: agent.id) }
                }
                Button("Choose…") { choose(from: path) }
            }
            .buttonStyle(.action)
        }
    }

    @ViewBuilder
    private var keyRow: some View {
        if model.keysKept.contains(agent.id) {
            row("API key", detail: "Kept in your Keychain, and handed only to the process that calls \(agent.name).") {
                Button("Remove") { Task { await model.removeKey(for: agent.id) } }
                    .buttonStyle(.action)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SecureField("API key", text: $key, prompt: Text("Paste your \(agent.keyName ?? "\(agent.name) key")"))
                        .textFieldStyle(.plain)
                        .font(Type.body)
                        .foregroundStyle(Ink.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Surface.card, in: .rect(cornerRadius: 10, style: .continuous))
                        .onSubmit(save)
                    Button("Save", action: save)
                        .buttonStyle(.action)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text(refused ?? "Kept in your Keychain as it's saved, and never shown again.")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private func forbiddenRow(_ login: AgentInfo.ForbiddenLogin) -> some View {
        let allowed = Binding(get: { model.agentSettings.allows(agent.id, login.id) }, set: { model.allowLogin(login.id, for: agent.id, $0) })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                Text(login.title).font(.system(size: 14)).foregroundStyle(Ink.primary)
                Spacer(minLength: 12)
                Toggle(login.title, isOn: allowed)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Group {
                if let sentence = login.sentence {
                    Text("\(login.maker): “\(sentence)”")
                } else {
                    Text("\(login.maker)'s terms couldn't be read here to quote. Read them before you turn this on.")
                }
            }
            .font(Type.secondary)
            .foregroundStyle(Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: login.url) {
                Link(url.host() ?? login.url, destination: url)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.primary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func save() {
        let typed = key
        key = ""
        refused = nil
        Task {
            do {
                try await model.saveKey(typed, for: agent.id)
            } catch {
                refused = error.localizedDescription
            }
        }
    }

    private func choose(from path: String?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = path.map { URL(filePath: $0).deletingLastPathComponent() } ?? URL(filePath: NSHomeDirectory() + "/.local/bin")
        panel.prompt = "Use This CLI"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.chooseAgentPath(url.path, for: agent.id)
    }
}
