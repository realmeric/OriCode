import SwiftUI

/// A thread's head and its rays: the head is the thread's own model, and its rays are the models
/// picked for it, on any agent, that it sends workers out on through OriCode's tools, each lit as
/// a ray while it works.
enum Rays {
    /// Settings › Agents' switch, on unless turned off.
    static let allowKey = "headsStartWorkers"

    static var allowed: Bool {
        UserDefaults.standard.object(forKey: allowKey) as? Bool ?? true
    }
}

extension AppModel {
    /// Whether the thread's agent can be a head, with Settings letting heads start workers.
    func offersWorkers(_ chat: Chat?) -> Bool {
        Rays.allowed && agent(for: chat).capabilities.workers == true
    }

    /// Whether ⌘I has something to show: heads the thread's agent reports, or workers it may start.
    func showsHeads(_ chat: Chat?) -> Bool {
        agent(for: chat).capabilities.heads || offersWorkers(chat)
    }

    /// The models a thread's rays can be, by agent: each ready agent's that the model menu shows,
    /// and the ones already picked.
    func rayChoices(for chat: Chat?) -> [(agent: ProviderInfo, models: [ModelOption])] {
        let picked = chat?.rays ?? []
        return providers.filter { $0.state == .ready }.compactMap { agent in
            let listed = models(of: agent.id)
            let picks = ModelsPage.picks(listed, on: agent.id)
            let shown = listed.filter { option in
                let ref = ModelRef(provider: agent.id, id: option.id)
                return option.pickable && (picked.contains(ref.stored) || showsInMenu(ref, picks: picks))
            }
            return shown.isEmpty ? nil : (agent, shown)
        }
    }

    /// The thread's rays as a send names them: the ones picked whose agent is ready, and none where
    /// the thread's agent can't be a head. With none the head works alone.
    func rays(for chat: Chat?) -> [ModelRef] {
        guard let chat, offersWorkers(chat) else { return [] }
        let ready = Set(providers.filter { $0.state == .ready }.map(\.id))
        return (chat.rays ?? []).map(ModelRef.init(stored:)).filter { ready.contains($0.provider) }
    }

    /// Picks a model as one of the thread's rays, after the others, or lets it go.
    func setRay(_ ref: ModelRef, _ on: Bool, for chat: Chat?) {
        var rays = (chat?.rays ?? []).filter { $0 != ref.stored }
        if on { rays.append(ref.stored) }
        setRays(rays, for: chat)
    }

    func setRays(_ rays: [String], for chat: Chat?) {
        guard let chat = chat ?? (rays.isEmpty ? nil : newChat()) else { return }
        chat.rays = rays.isEmpty ? nil : rays
        try? chat.modelContext?.save()
    }
}

/// The model page's last line: the thread's rays, each with its agent's mark in its colour, and a
/// native menu of switches that picks them from every ready agent's models, "Rays: GPT-6-Luna".
struct RaysMenu: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?

    static let height: CGFloat = 34

    var body: some View {
        let picked = model.rays(for: chat)
        Menu {
            ForEach(model.rayChoices(for: chat), id: \.agent.id) { entry in
                Section(entry.agent.name) {
                    ForEach(entry.models) { option in
                        let ref = ModelRef(provider: entry.agent.id, id: option.id)
                        Toggle(option.name, isOn: Binding(get: { picked.contains(ref) }, set: { model.setRay(ref, $0, for: chat) }))
                    }
                }
            }
            Divider()
            Button("No Rays") { model.setRays([], for: chat) }
                .disabled(picked.isEmpty)
        } label: {
            HStack(spacing: 6) {
                Text("Rays")
                    .foregroundStyle(Ink.secondary)
                ForEach(picked, id: \.self) { ray in
                    AgentMark(agent: ray.provider)
                        .frame(width: 12, height: 12)
                }
                Text(Self.line(picked.map(name)))
                    .foregroundStyle(picked.isEmpty ? Ink.faint : Ink.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.faint)
            }
            .font(Type.secondary)
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        .help("The models this thread's head sends workers out on")
        .accessibilityLabel("Rays")
        .accessibilityValue(Self.line(picked.map(name)))
    }

    private func name(_ ray: ModelRef) -> String {
        model.option(ray).map { ModelMenu.shortName($0.name) } ?? ray.id
    }

    /// "GPT-6-Luna, Sonnet", or with none what that means.
    static func line(_ names: [String]) -> String {
        names.isEmpty ? "None · the head works alone" : names.joined(separator: ", ")
    }
}
