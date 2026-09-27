import Foundation
import Security

/// An agent OriCode knows, as the engine's registry lists it, whether or not it's turned on.
struct AgentInfo: Codable, Hashable, Sendable, Identifiable {
    /// A login the agent offers that its maker keeps to its own apps. It stays off until it's
    /// turned on under the maker's sentence.
    struct ForbiddenLogin: Codable, Hashable, Sendable, Identifiable {
        let id: String
        let title: String
        let maker: String
        /// The maker's own words, or nil where they couldn't be read to quote.
        let sentence: String?
        let url: String
    }

    let id: String
    let name: String
    let agent: String
    let route: String
    /// It has a CLI of its own, found the way Node is or chosen in Settings.
    let binary: Bool
    /// It takes a model API's key, kept in the Keychain.
    let key: Bool
    /// What the key is called where it isn't the agent's own, as Antigravity takes a Gemini API key.
    var keyName: String? = nil
    let forbidden: [ForbiddenLogin]

    /// What its row in Settings › Agents says of it: off, being asked, or its state as the engine
    /// found it, with the one line that fixes it when there is one.
    func status(_ entry: ProviderInfo?, on: Bool, checking: Bool) -> String {
        guard on else { return "Off, and never looked for." }
        if checking { return "Looking…" }
        guard let entry else { return "Looked for once the engine is running." }
        let found = binary ? "Signed in." : "Its key is kept."
        switch entry.state {
        case .ready: return found
        case .soon: return found + " Threads on it come with a later update."
        case .unknown: return entry.version == nil ? "Found." : "Found. Whether it's signed in shows once a thread runs on it."
        // Its hint points here, where the field is right under it.
        case .signedOut where key && !binary: return "No key kept yet."
        case .missing, .signedOut, .outdated, .off: return entry.hint ?? "Not found."
        }
    }
}

extension ProviderInfo {
    /// A thread's agent turned off in Settings › Agents: it offers nothing, and says how to turn
    /// it back on.
    static func off(_ agent: AgentInfo) -> ProviderInfo {
        ProviderInfo(
            id: agent.id, name: agent.name, agent: agent.agent, state: .off, hint: "Turn on \(agent.name) in Settings › Agents.", cli: nil,
            version: nil, capabilities: .none, levels: [], modes: [])
    }
}

/// What Settings › Agents keeps in the defaults: which agents are on, the CLI chosen for each, and
/// the logins their makers forbid that the user turned on, every one off until then. Claude Code
/// is always on. Keys live in the Keychain.
@MainActor
@Observable
final class AgentSettings {
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var on: Set<String>
    private(set) var paths: [String: String]
    private(set) var logins: [String: Set<String>]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        on = Set(defaults.stringArray(forKey: "agentsOn") ?? [])
        paths = defaults.dictionary(forKey: "agentPaths") as? [String: String] ?? [:]
        logins = (defaults.dictionary(forKey: "agentLogins") as? [String: [String]] ?? [:]).mapValues(Set.init)
    }

    func isOn(_ id: String) -> Bool {
        id == ProviderInfo.claudeID || on.contains(id)
    }

    func turn(_ id: String, on value: Bool) {
        if value { on.insert(id) } else { on.remove(id) }
        defaults.set(on.sorted(), forKey: "agentsOn")
    }

    func path(_ id: String) -> String? {
        paths[id]
    }

    /// A CLI chosen in Settings, or nil to look for it again.
    func choose(_ path: String?, for id: String) {
        paths[id] = path
        defaults.set(paths, forKey: "agentPaths")
    }

    func allows(_ id: String, _ login: String) -> Bool {
        logins[id]?.contains(login) ?? false
    }

    func allow(_ login: String, for id: String, _ allowed: Bool) {
        if allowed { logins[id, default: []].insert(login) } else { logins[id]?.remove(login) }
        defaults.set(logins.mapValues { $0.sorted() }, forKey: "agentLogins")
    }

    /// What the engine is told of an agent turned on.
    func setting(_ id: String, keyKept: Bool) -> [String: JSON] {
        var setting: [String: JSON] = ["key": .bool(keyKept), "allow": .array((logins[id] ?? []).sorted().map(JSON.string))]
        if let path = paths[id] { setting["path"] = .string(path) }
        return setting
    }
}

/// Model APIs' keys in the login Keychain, a generic password each under the service
/// `OriCode.<agent>`. The app writes and removes a key and asks only whether one is kept, never
/// reading it back; the engine reads it with `security` for the one process it starts.
///
/// The item is made by `/usr/bin/security`, the key on its stdin, rather than by SecItemAdd. An item
/// the app made would belong to the app's code signature, and `security` reading it from the
/// engine would ask for the login keychain's password; one `security` made it reads without
/// asking. The key never goes on a command line, where `ps` would show it.
struct Keychain: Sendable {
    /// `OriCode`, or a test's own.
    let prefix: String

    struct Refused: LocalizedError {
        var errorDescription: String? { "The Keychain didn't take the key." }
    }

    func service(_ agent: String) -> String {
        "\(prefix).\(agent)"
    }

    /// Whether a key is kept, asked of its attributes alone.
    func has(_ agent: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service(agent),
            kSecAttrAccount: agent,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func save(_ key: String, for agent: String) async throws {
        let bytes = key.trimmingCharacters(in: .whitespacesAndNewlines).utf8.map { String(format: "%02x", $0) }.joined()
        guard !bytes.isEmpty else { throw Refused() }
        try await security(["-i"], input: "add-generic-password -U -s \(service(agent)) -a \(agent) -X \(bytes)\n")
        // Interactive, `security` exits 0 whether or not the command in it worked.
        guard has(agent) else { throw Refused() }
    }

    func remove(_ agent: String) async throws {
        try await security(["delete-generic-password", "-s", service(agent), "-a", agent])
    }

    /// Runs `security`, whose output is never read: it could only echo what it was given.
    private func security(_ arguments: [String], input: String? = nil) async throws {
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/security")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let stdin = Pipe()
            process.standardInput = stdin
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
            try? stdin.fileHandleForWriting.close()
        }
        guard status == 0 else { throw Refused() }
    }
}

extension AppModel {
    /// The agents turned on beside Claude Code, as hello tells the engine. The Keychain is asked
    /// only about these, so a launch with Claude Code alone asks it nothing.
    var agentsForHello: JSON {
        var on: [String: JSON] = [:]
        for id in agentSettings.on {
            on[id] = .object(agentSettings.setting(id, keyKept: keychain.has(id)))
        }
        if agentSettings.path(ProviderInfo.claudeID) != nil {
            on[ProviderInfo.claudeID] = .object(agentSettings.setting(ProviderInfo.claudeID, keyKept: false))
        }
        return .object(on)
    }

    /// The registry, for Settings › Agents and for the name of a thread's agent turned off.
    func loadAgents() async {
        guard let reply = try? await engine.request("agents"), let listed = reply["agents"].flatMap({ try? $0.decode([AgentInfo].self) }) else { return }
        agents = listed
        refreshKeys()
    }

    /// Which model APIs have a key kept, asked when Settings › Agents opens.
    func refreshKeys() {
        keysKept = Set(agents.filter(\.key).map(\.id).filter(keychain.has))
    }

    func turnAgent(_ id: String, on: Bool) {
        agentSettings.turn(id, on: on)
        Task { await tellAgent(id) }
    }

    func chooseAgentPath(_ path: String?, for id: String) {
        agentSettings.choose(path, for: id)
        Task { await tellAgent(id) }
    }

    func allowLogin(_ login: String, for id: String, _ allowed: Bool) {
        agentSettings.allow(login, for: id, allowed)
        Task { await tellAgent(id) }
    }

    /// Keeps a key as it's saved. The field it was typed in is emptied, and it's never shown again.
    func saveKey(_ key: String, for id: String) async throws {
        try await keychain.save(key, for: id)
        keysKept.insert(id)
        await tellAgent(id)
    }

    func removeKey(for id: String) async {
        try? await keychain.remove(id)
        if !keychain.has(id) { keysKept.remove(id) }
        await tellAgent(id)
    }

    /// Asks the agents turned on that hello found and didn't ask, once Settings › Agents or a menu
    /// shows them, or a thread cut off by a quit waits on one: their versions, and whether
    /// they're signed in.
    func askUnasked(_ only: Set<String>? = nil) {
        for entry in providers where entry.state == .unknown && entry.version == nil && !checkingAgents.contains(entry.id) && only?.contains(entry.id) != false {
            checkingAgents.insert(entry.id)
            Task {
                await checkProvider(entry.id)
                checkingAgents.remove(entry.id)
            }
        }
    }

    /// Tells the engine what Settings › Agents now says of an agent. Turned on, it's looked for
    /// and checked, and its entry joins hello's; turned off, it's forgotten, and a thread on it
    /// shows how to turn it back on.
    private func tellAgent(_ id: String) async {
        guard engineState == .ready else { return }
        let on = agentSettings.isOn(id)
        var params = agentSettings.setting(id, keyKept: on && keysKept.contains(id))
        params["provider"] = .string(id)
        params["on"] = .bool(on)
        checkingAgents.insert(id)
        defer { checkingAgents.remove(id) }
        guard let reply = try? await engine.request("agent.set", .object(params)) else { return }
        let found = reply["provider"].flatMap { try? $0.decode(ProviderInfo.self) }
        let was = providers.first { $0.id == id }?.state
        var listed = providers.filter { $0.id != id }
        if let found { listed.append(found) }
        let order = agents.map(\.id)
        providers = listed.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        // A login turned on or off changes which of its models can be picked, so the menu asks again.
        modelsAsked.remove(id)
        // Claude Code on a CLI chosen now may run where the last one couldn't.
        if was != .ready, found?.state == .ready {
            pickUpAfterQuit()
            scheduleResumes()
        }
    }
}
