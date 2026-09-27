import SwiftUI

/// A thread's head and its workers: the head is the thread's own agent, and a worker is another
/// agent the head starts on a task through OriCode's tools, lit as a ray while it works.
enum Rays {
    /// Settings › Agents' switch, on unless turned off.
    static let allowKey = "headsStartWorkers"

    static var allowed: Bool {
        UserDefaults.standard.object(forKey: allowKey) as? Bool ?? true
    }
}

extension AppModel {
    /// The agents a head's workers can run on: every one hello found ready.
    var workerAgents: [ProviderInfo] {
        providers.filter { $0.state == .ready }
    }

    /// Whether the thread's agent can be a head, with Settings letting heads start workers.
    func offersWorkers(_ chat: Chat?) -> Bool {
        Rays.allowed && agent(for: chat).capabilities.workers == true
    }

    /// Whether ⌘I has something to show: heads the thread's agent reports, or workers it may start.
    func showsHeads(_ chat: Chat?) -> Bool {
        agent(for: chat).capabilities.heads || offersWorkers(chat)
    }

    /// The agents a send lets the thread's workers use: the ones picked for its pair, or with none
    /// picked every ready agent, and none at all where it can't be a head.
    func workers(for chat: Chat) -> [String] {
        guard offersWorkers(chat) else { return [] }
        let ready = workerAgents.map(\.id)
        return chat.workers.map { $0.filter(ready.contains) } ?? ready
    }

    /// Makes the thread a pair with workers on these agents; nil goes back to every ready one.
    func setWorkers(_ ids: [String]?, for chat: Chat) {
        chat.workers = ids
        try? chat.modelContext?.save()
    }
}

/// The model page's last line: which agents the thread's workers may use, a native menu of
/// switches, "Workers may use: Codex, Cursor".
struct WorkersMenu: View {
    @Environment(AppModel.self) private var model
    let chat: Chat

    static let height: CGFloat = 34

    var body: some View {
        let ready = model.workerAgents
        let picked = model.workers(for: chat)
        Menu {
            Button("Any ready agent") { model.setWorkers(nil, for: chat) }
            Divider()
            ForEach(ready) { agent in
                Toggle(agent.name, isOn: Binding(
                    get: { picked.contains(agent.id) },
                    set: { on in
                        let next = ready.map(\.id).filter { $0 == agent.id ? on : picked.contains($0) }
                        model.setWorkers(next, for: chat)
                    }))
            }
            Divider()
            Button("None") { model.setWorkers([], for: chat) }
        } label: {
            Text(Self.line(picked: picked, chosen: chat.workers != nil, agents: ready))
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        .help("The agents this thread's head may send out as workers")
    }

    /// "Workers may use: Codex, Cursor", "any ready agent" until some are picked, or "none".
    static func line(picked: [String], chosen: Bool, agents: [ProviderInfo]) -> String {
        if picked.isEmpty { return "Workers: none" }
        if !chosen { return "Workers may use any ready agent" }
        return "Workers may use: " + agents.filter { picked.contains($0.id) }.map(\.name).joined(separator: ", ")
    }
}
