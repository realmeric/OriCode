import Foundation

extension AppModel {
    /// An agent's models: Claude Code's from hello, another's once its CLI has listed them.
    func models(of agent: String) -> [ModelOption] {
        modelsByAgent[agent] ?? []
    }

    /// The model a ref names, while its agent lists it.
    func option(_ ref: ModelRef) -> ModelOption? {
        models(of: ref.provider).first { $0.id == ref.id }
    }

    /// What hello said of an agent, or one that offers nothing when it said nothing.
    func providerInfo(_ id: String) -> ProviderInfo {
        providers.first { $0.id == id } ?? .unlisted(id)
    }

    /// A thread moves to another agent's model only while it's a draft: a session doesn't move
    /// between agents, and its first message starts one.
    func canMoveAgent(_ chat: Chat?) -> Bool {
        chat?.started != true
    }

    /// The agents whose models a thread's menus list: its own alone once it has begun, and
    /// before that Claude Code and every agent hello found ready, in hello's order.
    func agentsListed(for chat: Chat?) -> [ProviderInfo] {
        guard canMoveAgent(chat) else { return [agent(for: chat)] }
        let own = providerID(for: chat)
        return providers.filter { $0.id == ProviderInfo.claudeID || $0.id == own || $0.state == .ready }
    }

    /// The models as the pickers group them: favorites from every agent listed, then each agent's.
    func modelGroups(for chat: Chat?) -> [ModelsPage.RowGroup] {
        ModelsPage.groups(agentsListed(for: chat).map { ($0, models(of: $0.id)) }, favorites: favoriteModels)
    }

    /// What a forbidden model's row says: the Settings › Agents toggle that would let it run.
    func forbiddenHelp(_ option: ModelOption, on agent: String) -> String? {
        guard let maker = option.forbidden else { return nil }
        guard let toggle = agents.first(where: { $0.id == agent })?.forbidden.first(where: { $0.id == maker })?.title else {
            return "Turn on \(providerInfo(agent).agent)'s login in Settings › Agents to use \(option.name)"
        }
        return "Turn on “\(toggle)” in Settings › Agents to use \(option.name)"
    }

    /// The model Back to Defaults takes a thread to: the one Settings › New threads fixes when the
    /// thread can be on its agent, or else its own agent's first, which for Claude Code is Default.
    func defaultModel(for chat: Chat?) -> ModelRef {
        let own = providerID(for: chat)
        if let fixed = Self.storedModel(NewThreads.model), fixed.provider == own || canMoveAgent(chat) && providers.contains(where: { $0.id == fixed.provider }) {
            return fixed
        }
        let first = own == ProviderInfo.claudeID ? nil : models(of: own).first?.id
        return ModelRef(provider: own, id: first ?? ModelOption.claudeDefault)
    }

    /// A thread on another agent names its model from that agent's list, so a composer showing one
    /// reads the list, and a launch with a Claude thread open still asks no agent anything.
    func readModels(for chat: Chat?) {
        let agent = providerID(for: chat)
        guard agent != ProviderInfo.claudeID, models(of: agent).isEmpty else { return }
        readAgentModels([agent])
    }

    /// Asks each ready agent but Claude Code for its models the first time a menu needs them,
    /// rather than at launch, so opening OriCode starts no agent's CLI. One with a session in the
    /// engine that hello found and didn't ask is asked first whether it's signed in, and its
    /// models follow the check.
    func readAgentModels(_ only: Set<String>? = nil) {
        guard engineState == .ready else { return }
        askUnasked(Set(providers.filter { $0.capabilities != ProviderInfo.Capabilities.none && only?.contains($0.id) != false }.map(\.id)))
        for agent in providers where agent.id != ProviderInfo.claudeID && agent.state == .ready && !modelsAsked.contains(agent.id) && only?.contains(agent.id) != false {
            modelsAsked.insert(agent.id)
            Task {
                guard let reply = try? await engine.request("models.list", ["provider": .string(agent.id)]),
                      let list = try? reply["models"]?.decode([ModelOption].self)
                else {
                    // Asked again the next time a menu opens, which is no poll.
                    modelsAsked.remove(agent.id)
                    return
                }
                modelsByAgent[agent.id] = list
            }
        }
    }
}
