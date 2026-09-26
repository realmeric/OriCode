import Foundation

/// An agent as hello gives it: whether it can run here, and what a thread on it can do.
struct ProviderInfo: Codable, Hashable, Sendable, Identifiable {
    enum State: String, Codable, Sendable {
        case ready, missing, signedOut, outdated
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

    /// What hello said of that agent; nil for one it didn't list.
    func provider(for chat: Chat?) -> ProviderInfo? {
        let id = providerID(for: chat)
        return providers.first { $0.id == id }
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
        pickUpAfterQuit()
        scheduleResumes()
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
