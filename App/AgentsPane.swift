import AppKit
import SwiftUI

/// Settings › Agents: a card for each agent, whether it's on and, while it is, its CLI, its key and
/// the logins its maker forbids for third-party apps.
struct AgentsPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Rays.allowKey) private var workers = true
    @AppStorage(Rays.chooseKey) private var choose = false
    @AppStorage(Rays.budgetKey) private var budget = 0.0
    @AppStorage(AppModel.ceilingKey) private var ceiling = AppModel.defaultCeiling
    @AppStorage(AppModel.openersAnswerKey) private var openersAnswer = false

    var body: some View {
        PaneTitle(text: "Agents")
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
        MenuModels()
        SectionHeading("Workers")
        SettingsCard {
            SettingsRow(
                title: "Heads may start workers",
                detail: "A thread's head can send workers out on other models, any agent's, each a ray on the mark while it works."
            ) {
                Toggle("Heads may start workers", isOn: $workers).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(
                title: "Heads choose",
                detail: choose ? "Picks models and effort for itself and its workers." : nil
            ) {
                Toggle("Heads choose", isOn: $choose).labelsHidden().toggleStyle(.switch)
            }
            .disabled(!workers)
            SettingsRow(
                title: "Spend per thread",
                detail: "Everything in the thread stops at the limit."
            ) {
                Picker("Spend per thread", selection: $budget) {
                    ForEach(Rays.budgets, id: \.self) { amount in
                        Text(Rays.budgetName(amount)).tag(amount)
                    }
                }
                .menuRow()
                .help("With a limit set, no worker starts on an agent that doesn't say what it spends, such as Codex.")
            }
            .disabled(!workers || !choose)
            SettingsRow(title: "Models heads keep off") {
                KeepOffMenu()
            }
            .disabled(!workers || !choose)
        }
        SectionHeading("Threads")
        SettingsCard {
            SettingsRow(
                title: "Threads working at once",
                detail: "What you send yourself always goes."
            ) {
                Stepper(value: $ceiling, in: 1...20) {
                    Text("\(ceiling)").monospacedDigit().foregroundStyle(Ink.primary)
                }
            }
            SettingsRow(
                title: "Threads answer first",
                detail: openersAnswer ? "Asks go to the thread that opened it first." : nil
            ) {
                Toggle("Threads answer first", isOn: $openersAnswer).labelsHidden().toggleStyle(.switch)
                    .onChange(of: openersAnswer) { _, on in
                        if !on { model.handAsksToUser() }
                    }
            }
        }
        MacAccessCard()
        SSHAgentCard()
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

/// The models heads keep off, picked from each ready agent's models the model menu shows.
private struct KeepOffMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let kept = Set(model.headsKeepOff)
        let title = kept.isEmpty ? "None" : kept.count == 1 ? "1 model" : "\(kept.count) models"
        Menu(title) {
            ForEach(model.providers.filter { $0.state == .ready }, id: \.id) { agent in
                let listed = model.shownModels(of: agent.id).filter(\.pickable)
                if !listed.isEmpty {
                    Section(agent.name) {
                        ForEach(listed) { option in
                            let ref = ModelRef(provider: agent.id, id: option.id)
                            Toggle(option.name, isOn: Binding(get: { kept.contains("\(agent.id)/\(option.id)") }, set: { model.keepHeadsOff(ref, $0) }))
                        }
                    }
                }
            }
        }
        .menuRow()
        .fixedSize()
        .accessibilityLabel("Models heads keep off")
        .accessibilityValue(title)
        .onAppear { model.readAgentModels() }
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
            row(agent.name, mark: agent.id, detail: agent.status(entry, on: on, checking: model.checkingAgents.contains(agent.id))) {
                // Claude Code's threads and hello's models are its own, so it has no switch.
                if !isClaude {
                    Toggle(agent.name, isOn: Binding(get: { on }, set: { model.turnAgent(agent.id, on: $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            // A CLI found on its own has nothing to say: where it is and its version are the
            // agent's help, and Choose… its menu. One chosen here, or not found, keeps its row.
            .help(on && agent.binary && !cliShown ? cliFound ?? "" : "")
            .contextMenu {
                if on, agent.binary, !cliShown {
                    Button("Choose CLI…") { choose(from: entry?.cli) }
                }
            }
            if on, agent.binary, cliShown { cliRow }
            if on, agent.key { keyRow }
            if on {
                ForEach(agent.forbidden) { login in forbiddenRow(login) }
            }
        }
        .animation(Motion.fade, value: on)
    }

    /// A settings row whose line, when it has one, may carry a Terminal command in backticks; a path
    /// is read verbatim.
    /// The agent's own row has its mark before its name.
    private func row<Control: View>(_ title: String, mark: String? = nil, detail: String, verbatim: Bool = false,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    if let mark {
                        AgentMark(agent: mark).frame(width: 14, height: 14)
                    }
                    Text(title).font(.system(size: 14)).foregroundStyle(Ink.primary)
                }
                if !detail.isEmpty {
                    Group {
                        if verbatim { Text(verbatim: detail) } else { Text(LocalizedStringKey(detail)) }
                    }
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        // As tall as a row with a switch, which Claude Code's hasn't, so the list keeps one rhythm.
        .frame(minHeight: 24)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var cliShown: Bool {
        model.agentSettings.path(agent.id) != nil || entry?.cli == nil
    }

    private var cliFound: String? {
        entry?.cli.map { $0 + (entry?.version.map { " · \($0)" } ?? "") }
    }

    private var cliRow: some View {
        let chosen = model.agentSettings.path(agent.id)
        let path = chosen ?? entry?.cli
        let found = path.map { $0 + (entry?.version.map { " · \($0)" } ?? "") }
        // Found on its own, where it is and its version are the row's help; a CLI chosen here
        // says which.
        return row("CLI", detail: chosen != nil ? found ?? "" : path == nil ? "Not found on its own. Choose it if it's installed." : "", verbatim: path != nil) {
            HStack(spacing: 8) {
                if chosen != nil {
                    Button("Automatic") { model.chooseAgentPath(nil, for: agent.id) }
                }
                Button("Choose…") { choose(from: path) }
            }
            .buttonStyle(.action)
        }
        .help(found ?? "")
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

/// Which models the model menu lists: every agent's that has said which it has, under its mark and
/// name, found by a search and each turned on or off with its own switch. A List, since OpenCode
/// alone lists hundreds and only the rows in view are drawn.
struct MenuModels: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    struct Listing: Identifiable {
        let agent: ProviderInfo
        let picks: Set<String>
        let shown: Int
        let total: Int
        let models: [ModelOption]

        var id: String { agent.id }
    }

    private var sections: [Listing] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return model.providers.compactMap { agent in
            let all = model.models(of: agent.id)
            guard !all.isEmpty else { return nil }
            let picks = ModelsPage.picks(all, on: agent.id)
            let shown = all.count { model.showsInMenu(ModelRef(provider: agent.id, id: $0.id), picks: picks) }
            let found = query.isEmpty || agent.name.localizedStandardContains(query) ? all
                : all.filter { [$0.name, $0.id, $0.description].contains { $0.localizedStandardContains(query) } }
            return found.isEmpty ? nil : Listing(agent: agent, picks: picks, shown: shown, total: all.count, models: found)
        }
    }

    var body: some View {
        let sections = sections
        SectionHeading("Model menu")
        VStack(alignment: .leading, spacing: 0) {
            Text("The model menu lists the models turned on here, and a thread's own model whatever this says.")
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.top, 14)
            search
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            if sections.isEmpty {
                Text(query.isEmpty ? "The models are listed once each agent has said which it has." : "No model matches “\(query)”.")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.faint)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
            } else {
                list(sections)
            }
        }
        .background(Surface.card, in: .rect(cornerRadius: 16, style: .continuous))
        .onAppear { model.readAgentModels() }
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.secondary)
            TextField("Search models", text: $query, prompt: Text("Search models"))
                .textFieldStyle(.plain)
                .font(Type.body)
                .foregroundStyle(Ink.primary)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.faint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Surface.card, in: .rect(cornerRadius: 10, style: .continuous))
    }

    private func list(_ sections: [Listing]) -> some View {
        let rows = sections.reduce(0) { $0 + $1.models.count }
        // Each agent's name is a row of its own rather than a section's header, which a plain
        // List pins with a rule under it.
        return List {
            ForEach(sections) { section in
                HStack(spacing: 7) {
                    AgentMark(agent: section.agent.id).frame(width: 14, height: 14)
                    Text(section.agent.name).font(.system(size: 14)).foregroundStyle(Ink.primary)
                    Spacer(minLength: 12)
                    Text("\(section.shown) of \(section.total) shown")
                        .font(Type.secondary)
                        .foregroundStyle(Ink.faint)
                        .contentTransition(.numericText())
                }
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
                ForEach(section.models) { option in
                    row(option, in: section)
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(height: min(CGFloat(rows) * 44 + CGFloat(sections.count) * 38 + 8, 440))
        .padding(.bottom, 6)
    }

    private func row(_ option: ModelOption, in section: Listing) -> some View {
        let ref = ModelRef(provider: section.agent.id, id: option.id)
        let shown = Binding(get: { model.showsInMenu(ref, picks: section.picks) }, set: { model.showInMenu(ref, $0) })
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.name).font(.system(size: 13.5)).foregroundStyle(Ink.primary)
                if !option.description.isEmpty {
                    Text(option.description)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Toggle("Show \(option.name) in the model menu", isOn: shown)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Show in the model menu")
        }
        .padding(.leading, 21)
        .padding(.vertical, 3)
    }
}
