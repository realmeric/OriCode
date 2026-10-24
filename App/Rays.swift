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

    /// Settings › Agents' Heads choose, on unless turned off: the head picks the models its workers
    /// run on and its own, rather than working on the rays picked for it.
    static let chooseKey = "headsChoose"
    /// What a thread may spend in all, in dollars, while heads choose; 0 for no limit.
    static let budgetKey = "threadBudget"
    /// The models heads never pick, as `agent/model`.
    static let keepOffKey = "headsKeepOff"
    /// The budgets Settings offers, 0 being none.
    static let budgets: [Double] = [0, 0.5, 1, 2, 5, 10, 20]

    static var choose: Bool {
        allowed && UserDefaults.standard.object(forKey: chooseKey) as? Bool ?? true
    }

    static var budget: Double {
        UserDefaults.standard.double(forKey: budgetKey)
    }

    static var keepOff: [String] {
        UserDefaults.standard.stringArray(forKey: keepOffKey) ?? []
    }

    /// A budget as Settings writes it: "$0.50", "$5", or No limit.
    static func budgetName(_ amount: Double) -> String {
        amount == 0 ? "No limit" : amount.formatted(.currency(code: "USD").precision(.fractionLength(amount == amount.rounded() ? 0 : 2)))
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

    /// What a send tells the engine of a head that chooses: every model the model menu shows on a
    /// ready agent, as `agent/model`, less the ones heads keep off; the agents whose models haven't
    /// been read yet, which the engine lists itself if the head asks; the budget and what
    /// the thread has spent since it had one, its workers' share in it. Nil when the head works on
    /// its rays, and with workflows on, which hand the parts out at the level picked, as the model
    /// button says.
    func choice(for chat: Chat) -> JSON? {
        guard Rays.choose, offersWorkers(chat), !workflows(of: chat) else { return nil }
        let keepOff = headsKeepOff
        var models: [JSON] = []
        var unread: [JSON] = []
        // An agent found and not yet asked whether it's signed in, as most are until a menu opens,
        // is asked now, and offered meanwhile as one whose models the engine lists if the head asks.
        askUnasked()
        for agent in providers where agent.state == .ready || agent.state == .unknown {
            let listed = agent.state == .ready ? shownModels(of: agent.id) : []
            if listed.isEmpty, agent.id != ProviderInfo.claudeID {
                unread.append(.string(agent.id))
                continue
            }
            for option in listed where option.pickable {
                let ref = "\(agent.id)/\(option.id)"
                if !keepOff.contains(ref) { models.append(.string(ref)) }
            }
        }
        var choice: [String: JSON] = [
            "models": .array(models),
            "unread": .array(unread),
            "keepOff": .array(keepOff.map(JSON.string)),
            // All it has spent, so a thread already past a budget set or lowered since stops there.
            "spent": .number(chat.costUSD),
        ]
        if Rays.budget > 0 { choice["budget"] = .number(Rays.budget) }
        return .object(choice)
    }

    /// Settings › Agents' list of what heads keep off: a model on or off it.
    func keepHeadsOff(_ ref: ModelRef, _ off: Bool) {
        let key = "\(ref.provider)/\(ref.id)"
        var kept = headsKeepOff.filter { $0 != key }
        if off { kept.append(key) }
        headsKeepOff = kept
    }

    /// Picks a model as one of the thread's rays, after the others, or lets it go. The mark has
    /// six arcs, so a seventh waits for one to go.
    func setRay(_ ref: ModelRef, _ on: Bool, for chat: Chat?) {
        var rays = (chat?.rays ?? []).filter { $0 != ref.stored }
        if on {
            guard rays.count < RaysMark.rays else { return }
            rays.append(ref.stored)
        }
        setRays(rays, for: chat)
    }

    /// The arc each ray stands on, clockwise from twelve in the order they were picked.
    func raySlots(for chat: Chat?) -> [ModelRef: Int] {
        Dictionary(uniqueKeysWithValues: rays(for: chat).prefix(RaysMark.rays).enumerated().map { ($1, $0) })
    }

    /// Each picked ray's arc in its agent's colour, for the mark.
    func rayColors(for chat: Chat?) -> [Int: Color] {
        Dictionary(uniqueKeysWithValues: raySlots(for: chat).map { ($1, MarkPalette.color(for: $0.provider)) })
    }

    /// Turns the effort page to the rays' page and back. It opens with the agents the rays are on,
    /// or with none every agent but the head's, which is where rays most often go.
    func showRays(_ shown: Bool, for chat: Chat?) {
        guard !shown || offersWorkers(chat) else { return }
        if shown { openRays(for: chat) }
        raysShown = shown
    }

    /// Opens the agents the rays' page starts on, before the page is built.
    func openRays(for chat: Chat?) {
        let picked = Set(rays(for: chat).map(\.provider))
        let open = picked.isEmpty ? Set(rayChoices(for: chat).map(\.agent.id)).subtracting([providerID(for: chat)]) : picked
        if open != raysOpen { raysOpen = open }
    }

    /// The rays by their short names, "GPT-6-Luna".
    func rayNames(for chat: Chat?) -> [String] {
        rays(for: chat).map { ray in option(ray).map { ModelMenu.shortName($0.name) } ?? ray.id }
    }

    /// The pair as VoiceOver says it: "Opus, 2 rays: GPT-6-Luna, GPT-6", or "Opus, no rays".
    func pairLine(for chat: Chat?) -> String {
        let head = ModelMenu.shortName(option(for: chat)?.name ?? "The head")
        let names = rayNames(for: chat)
        return switch names.count {
        case 0: "\(head), no rays"
        case 1: "\(head), 1 ray: \(names[0])"
        default: "\(head), \(names.count) rays: " + names.joined(separator: ", ")
        }
    }

    func setRays(_ rays: [String], for chat: Chat?) {
        guard let chat = chat ?? (rays.isEmpty ? nil : newChat()) else { return }
        chat.rays = rays.isEmpty ? nil : rays
        try? chat.modelContext?.save()
    }
}
