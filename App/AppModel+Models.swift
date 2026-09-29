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

    /// A thread moves to another agent's model between turns: a draft, or one that has begun and
    /// has nothing running, out or waiting on you. Its session doesn't move; the next send starts
    /// one on the new agent that opens with the thread so far (`Handover`).
    func canMoveAgent(_ chat: Chat?) -> Bool {
        guard let chat, let conversation = conversations[chat.id] else { return true }
        return !conversation.working && conversation.waitingAsk == nil && !conversation.waitingAfterQuit
    }

    /// The agents whose models a thread's menus list: Claude Code and every agent hello found
    /// ready, in hello's order, and the thread's own alone while it works.
    func agentsListed(for chat: Chat?) -> [ProviderInfo] {
        guard canMoveAgent(chat) else { return [agent(for: chat)] }
        let own = providerID(for: chat)
        return providers.filter { $0.id == ProviderInfo.claudeID || $0.id == own || $0.state == .ready }
    }

    /// The models as the pickers group them: favorites from every agent listed, then each agent's,
    /// only the ones shown in the model menu and always the one in use. `open` folds every agent
    /// the model page doesn't have open; nil lists them all, as the native menus do.
    func modelGroups(for chat: Chat?, open: Set<String>? = nil) -> [ModelsPage.RowGroup] {
        let current = option(for: chat).map { ModelRef(provider: providerID(for: chat), id: $0.id).stored }
        return ModelsPage.groups(agentsListed(for: chat).map { ($0, shownModels(of: $0.id, keeping: current)) }, favorites: favoriteModels, open: open)
    }

    /// An agent's models the model menu shows, and `keeping`, the one in use, whatever Settings says.
    func shownModels(of agent: String, keeping: String? = nil) -> [ModelOption] {
        let all = models(of: agent)
        let picks = ModelsPage.picks(all, on: agent)
        return all.filter { option in
            let key = ModelRef(provider: agent, id: option.id).stored
            return key == keeping || menuModels[key] ?? picks.contains(option.id)
        }
    }

    /// Whether the model menu shows a model, as Settings › Agents has it.
    func showsInMenu(_ ref: ModelRef, picks: Set<String>) -> Bool {
        menuModels[ref.stored] ?? picks.contains(ref.id)
    }

    /// Settings › Agents' toggle. A choice that matches the agent's picks is forgotten, so the
    /// model follows them again.
    func showInMenu(_ ref: ModelRef, _ shown: Bool) {
        let picked = ModelsPage.picks(models(of: ref.provider), on: ref.provider).contains(ref.id)
        menuModels[ref.stored] = shown == picked ? nil : shown
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
    /// thread is on that agent or is still a draft, or else its own agent's first, which for Claude
    /// Code is Default. Back to Defaults doesn't move a begun thread to another agent.
    func defaultModel(for chat: Chat?) -> ModelRef {
        let own = providerID(for: chat)
        if let fixed = Self.storedModel(NewThreads.model), fixed.provider == own || chat?.started != true && providers.contains(where: { $0.id == fixed.provider }) {
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
