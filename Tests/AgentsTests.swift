import Foundation
import SwiftData
import Testing
@testable import OriCode

/// Settings › Agents: keys in the Keychain, what each row says, and the logins makers forbid.
@MainActor
struct AgentsTests {
    private let container: ModelContainer
    private let chat: Chat
    private let suite = "OriCodeTests.agents.\(UUID().uuidString)"

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project)
        container.mainContext.insert(chat)
    }

    private static let codex = AgentInfo(id: "codex", name: "Codex", agent: "Codex", route: "its app-server", binary: true, key: false, forbidden: [])
    private static let zai = AgentInfo(id: "zai", name: "Z.ai", agent: "Z.ai", route: "Claude Code", binary: false, key: true, forbidden: [])

    private static func entry(_ id: String, _ state: ProviderInfo.State, version: String? = nil, hint: String? = nil) -> ProviderInfo {
        let off = ProviderInfo.off(id == "zai" ? zai : codex)
        return ProviderInfo(
            id: id, name: off.name, agent: off.agent, state: state, hint: hint, cli: nil, version: version, capabilities: off.capabilities,
            levels: [], modes: [])
    }

    /// What `security` says the item holds, which only a test reads back.
    private static func stored(_ keychain: Keychain, _ agent: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychain.service(agent), "-a", agent, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return process.terminationStatus == 0 ? text.trimmingCharacters(in: .newlines) : nil
    }

    @Test func aKeyIsKeptInTheKeychainUpdatedAndRemoved() async throws {
        let keychain = Keychain(prefix: "OriCodeTests.\(UUID().uuidString)")
        defer { Task { try? await keychain.remove("zai") } }
        #expect(!keychain.has("zai"))
        try await keychain.save("  zai-key-one\n", for: "zai")
        #expect(keychain.has("zai"))
        #expect(try Self.stored(keychain, "zai") == "zai-key-one")
        try await keychain.save("zai-key-two", for: "zai")
        #expect(try Self.stored(keychain, "zai") == "zai-key-two")
        // Another prefix, as the installed OriCode's is to a test's, doesn't see it.
        #expect(!Keychain(prefix: "OriCodeTests.other").has("zai"))
        try await keychain.remove("zai")
        #expect(!keychain.has("zai"))
        #expect(try Self.stored(keychain, "zai") == nil)
        await #expect(throws: Keychain.Refused.self) { try await keychain.save(" \n", for: "zai") }
    }

    @Test func eachRowSaysWhereItsAgentStands() {
        let codex = Self.codex
        #expect(codex.status(nil, on: false, checking: false) == "Off, and never looked for.")
        #expect(codex.status(nil, on: true, checking: false) == "Looked for once the engine is running.")
        #expect(codex.status(Self.entry("codex", .unknown), on: true, checking: true) == "Looking…")
        #expect(codex.status(Self.entry("codex", .unknown), on: true, checking: false) == "Found.")
        #expect(codex.status(Self.entry("codex", .unknown, version: "1.0"), on: true, checking: false) == "Found. Whether it's signed in shows once a thread runs on it.")
        #expect(codex.status(Self.entry("codex", .soon, version: "1.0"), on: true, checking: false) == "Signed in. Threads on it come with a later update.")
        #expect(codex.status(Self.entry("codex", .ready), on: true, checking: false) == "Signed in.")
        let login = "Run `codex login` in Terminal and log in."
        #expect(codex.status(Self.entry("codex", .signedOut, hint: login), on: true, checking: false) == login)
        let install = "Codex isn't installed. Install it with `npm install -g @openai/codex`, then run `codex login`."
        #expect(codex.status(Self.entry("codex", .missing, hint: install), on: true, checking: false) == install)
        #expect(Self.zai.status(Self.entry("zai", .soon), on: true, checking: false) == "Its key is kept. Threads on it come with a later update.")
        let add = "Add your Z.ai key in Settings › Agents."
        #expect(Self.zai.status(Self.entry("zai", .signedOut, hint: add), on: true, checking: false) == "No key kept yet.")    }

    @Test func forbiddenLoginsStartOffAndOnlyTheAgentsTurnedOnReachHello() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AgentSettings(defaults: defaults)
        #expect(settings.isOn("claude"))
        #expect(!settings.isOn("pi"))
        #expect(!settings.allows("pi", "anthropic"))
        #expect(!settings.allows("antigravity", "google"))
        #expect(settings.setting("pi", keyKept: false) == ["key": .bool(false), "allow": .array([])])

        let model = AppModel(container: container)
        model.agentSettings = settings
        model.keychain = Keychain(prefix: "OriCodeTests.\(UUID().uuidString)")
        #expect(model.agentsForHello == .object([:]))

        settings.turn("pi", on: true)
        settings.allow("anthropic", for: "pi", true)
        settings.choose("/opt/pi/bin/pi", for: "pi")
        #expect(model.agentsForHello == .object(["pi": .object(["key": .bool(false), "allow": .array([.string("anthropic")]), "path": .string("/opt/pi/bin/pi")])]))

        // Kept across launches, and off again when turned off.
        let again = AgentSettings(defaults: defaults)
        #expect(again.isOn("pi"))
        #expect(again.allows("pi", "anthropic"))
        #expect(!again.allows("pi", "xai"))
        #expect(again.path("pi") == "/opt/pi/bin/pi")
        again.allow("anthropic", for: "pi", false)
        again.turn("pi", on: false)
        let last = AgentSettings(defaults: defaults)
        #expect(!last.allows("pi", "anthropic"))
        #expect(!last.isOn("pi"))
    }

    @Test func aThreadOnAnAgentTurnedOffKeepsItsAgentAndSaysHowToTurnItOn() {
        // Started, or the model would clear it as a draft.
        chat.started = true
        let model = AppModel(container: container)
        model.agents = [Self.codex]
        model.engineState = .ready
        chat.provider = "codex"
        model.selectedProjectID = chat.project?.id
        model.selectedChatID = chat.id
        let off = model.provider(for: chat)
        #expect(off?.state == .off)
        #expect(off?.hint == "Turn on Codex in Settings › Agents.")
        #expect(off?.capabilities.steer == false)
        #expect(!model.agentReady(for: chat))
        #expect(model.agentDown?.id == "codex")
        // One the engine doesn't know stays unknown.
        chat.provider = "nobody"
        #expect(model.provider(for: chat) == nil)
    }
}
