import Foundation

/// An agent as hello gives it: whether it can run here, and what a thread on it can do.
struct ProviderInfo: Codable, Hashable, Sendable, Identifiable {
    /// `unknown` is found and not yet asked whether it's signed in, or with no way to ask short of
    /// a thread; `soon` is found and signed in, with no session in the engine yet; `noPlan` is
    /// signed in to an account with no plan for it, a GitHub account without Copilot; `off` is the
    /// app's own, for a thread's agent turned off in Settings › Agents.
    enum State: String, Codable, Sendable {
        case ready, missing, signedOut, noPlan, outdated, unknown, soon, off
    }

    struct Capabilities: Codable, Hashable, Sendable {
        /// A message sent during a turn joins it.
        let steer: Bool
        /// A thread picks up its session after a quit or a release.
        let resume: Bool
        /// A new permission mode reaches the running turn.
        let modeLive: Bool
        let attachments: Bool
        let heads: Bool
        let stopTask: Bool
        /// The plan's limits come with a turn.
        let limits: Bool
        let usage: Bool
        let commands: Bool
        let compact: Bool
        let commitMessage: Bool
        /// The Terminal line that opens a thread's session in the agent's own CLI, `{session}`
        /// standing for its id.
        let handoff: String?
        /// It asks before nothing, so a thread on it has no permission modes. Only an agent that
        /// runs that way sends it.
        var unsupervised: Bool? = nil

        /// What an agent hello doesn't list can do: nothing.
        static let none = Capabilities(
            steer: false, resume: false, modeLive: false, attachments: false, heads: false, stopTask: false, limits: false,
            usage: false, commands: false, compact: false, commitMessage: false, handoff: nil)
    }

    let id: String
    /// Its maker's name for it, "Claude Code".
    let name: String
    /// What a thread's lines call it, "Claude".
    let agent: String
    let state: State
    /// The one Terminal line that would let it run, when it can't.
    let hint: String?
    let cli: String?
    let version: String?
    let capabilities: Capabilities
    let levels: [String]
    let modes: [String]

    static let claudeID = "claude"

    /// Claude Code as the app takes it until hello says, so nothing that asks what a thread can
    /// do changes its answer as the engine starts.
    static let claude = ProviderInfo(
        id: claudeID, name: "Claude Code", agent: "Claude", state: .ready, hint: nil, cli: nil, version: nil,
        capabilities: Capabilities(
            steer: true, resume: true, modeLive: true, attachments: true, heads: true, stopTask: true, limits: true,
            usage: true, commands: true, compact: true, commitMessage: true, handoff: "claude --resume {session}"),
        levels: ["low", "medium", "high", "xhigh", "max", Effort.ultracode],
        modes: ["default", "acceptEdits", "plan", "auto", "bypassPermissions"])
}

extension ProviderInfo {
    /// A thread's agent that hello doesn't list, one turned off or gone: it offers nothing.
    static func unlisted(_ id: String) -> ProviderInfo {
        ProviderInfo(id: id, name: id, agent: id, state: .missing, hint: nil, cli: nil, version: nil,
                     capabilities: .none, levels: [], modes: [])
    }

    var unsupervised: Bool { capabilities.unsupervised == true }

    /// The modes a thread on it picks from, in the tiles' order. One that asks before nothing may
    /// still have some, which say what it's allowed: Command Code's, where Pi has none.
    var permissionModes: [PermissionModeOption] {
        PermissionModeOption.allCases.filter { modes.contains($0.rawValue) }
    }

    /// A model as a thread on this agent runs it: only the levels the agent takes, and Ultracode
    /// only when it's one of them. Claude Code's come back as they are.
    func narrowing(_ option: ModelOption) -> ModelOption {
        let efforts = option.efforts.filter(levels.contains)
        let ultracode = levels.contains(Effort.ultracode)
        guard efforts != option.efforts || !ultracode && (option.ultra || option.ultraBlocked != nil) else { return option }
        return ModelOption(
            id: option.id, name: option.name, description: option.description, efforts: efforts, fast: option.fast,
            defaultEffort: option.defaultEffort.flatMap { efforts.contains($0) ? $0 : nil },
            ultra: option.ultra && ultracode, ultraBlocked: ultracode ? option.ultraBlocked : nil, more: option.more, needs: option.needs,
            forbidden: option.forbidden)
    }
}

/// A model as the defaults name it. Claude Code's keep the bare id they had before there were
/// other agents, and another agent's is `agent/id`, `codex/gpt-6-luna`.
struct ModelRef: Hashable {
    let provider: String
    let id: String

    init(provider: String, id: String) {
        self.provider = provider
        self.id = id
    }

    /// An OpenRouter id has a slash of its own, so only the first one parts the agent from the
    /// model, and only after a plain agent id: a Bedrock ARN a Claude Code setting names stays
    /// Claude's.
    init(stored: String) {
        if let slash = stored.firstIndex(of: "/"), slash > stored.startIndex,
           stored[..<slash].allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) {
            provider = String(stored[..<slash])
            id = String(stored[stored.index(after: slash)...])
        } else {
            provider = ProviderInfo.claudeID
            id = stored
        }
    }

    var stored: String {
        provider == ProviderInfo.claudeID ? id : "\(provider)/\(id)"
    }
}

extension Chat {
    /// The agent the thread is on. A thread from before there were others is Claude Code's.
    var providerID: String {
        provider ?? ProviderInfo.claudeID
    }
}

extension [String: JSON] {
    /// A request for an agent. Claude Code's goes unnamed, since the engine takes a request
    /// that names none as its, so a Claude thread's requests read as they always have.
    func naming(_ provider: String) -> Self {
        provider == ProviderInfo.claudeID ? self : merging(["provider": .string(provider)]) { $1 }
    }
}

extension AppModel {
    /// The agent a thread is on, or with no thread the one the next starts on.
    func providerID(for chat: Chat?) -> String {
        chat?.providerID ?? startingProvider
    }

    /// What hello said of that agent, or for one turned off in Settings › Agents, that it's off;
    /// nil for one the engine doesn't know.
    func provider(for chat: Chat?) -> ProviderInfo? {
        let id = providerID(for: chat)
        return providers.first { $0.id == id } ?? agents.first { $0.id == id }.map(ProviderInfo.off)
    }

    /// Whether a turn can start on the thread's agent without the user: hello listed it and found
    /// it signed in. Pick-up after a quit and a limit's reset wait on it; what the user sends doesn't.
    func agentReady(for chat: Chat?) -> Bool {
        provider(for: chat)?.state == .ready
    }

    /// The open thread's agent while the engine is up and the agent can't run, whose hint is the
    /// line under the composer.
    var agentDown: ProviderInfo? {
        guard engineState == .ready, let agent = provider(for: chat), agent.state != .ready, agent.hint != nil else { return nil }
        return agent
    }

    /// Asks the engine about one agent again, after a login in Terminal, instead of restarting it
    /// and ending every thread's turn.
    func checkProvider(_ id: String) async {
        guard engineState == .ready,
              let reply = try? await engine.request("provider.check", ["provider": .string(id)]),
              let found = try? reply.decode(ProviderInfo.self)
        else { return }
        checked(found)
    }

    /// What a check said of an agent. One that has just become ready takes up what waited
    /// on it: threads a quit cut off, and limits that have reset.
    func checked(_ found: ProviderInfo) {
        guard let at = providers.firstIndex(where: { $0.id == found.id }) else { return }
        let was = providers[at].state
        providers[at] = found
        guard was != .ready, found.state == .ready else { return }
        modelsAsked.remove(found.id)
        pickUpAfterQuit()
        scheduleResumes()
    }

    /// What a thread's agent offers, or with no thread the next one's.
    func agent(for chat: Chat?) -> ProviderInfo {
        provider(for: chat) ?? .unlisted(providerID(for: chat))
    }

    /// The agent a new thread starts on: the one Settings fixes, or the last one picked, as long
    /// as hello lists it.
    var startingProvider: String {
        _ = defaultsRevision
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: NewThreads.provider)?.nonEmpty ?? defaults.string(forKey: "lastProvider")
        return providers.first { $0.id == id }?.id ?? ProviderInfo.claudeID
    }

    var lastProvider: String? {
        get { UserDefaults.standard.string(forKey: "lastProvider") }
        set { UserDefaults.standard.set(newValue, forKey: "lastProvider") }
    }

    /// A model a defaults key names, read with its agent.
    static func storedModel(_ key: String) -> ModelRef? {
        UserDefaults.standard.string(forKey: key)?.nonEmpty.map(ModelRef.init(stored:))
    }
}
