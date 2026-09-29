import Foundation
import SwiftData
import Testing
@testable import OriCode

/// The model menu by agent: Claude Code and two stand-ins, a Codex and a Pi, whose models come
/// as the engine's `models.list` gives them.
@MainActor
struct ModelMenuTests {
    private let container: ModelContainer
    private let project: Project
    private let model: AppModel

    static let claudeModels = [
        ModelOption(id: "default", name: "Default (recommended)", description: "", efforts: ["low", "medium", "high", "xhigh", "max"],
                    fast: true, defaultEffort: "high", ultra: true, ultraBlocked: nil, more: nil, needs: nil),
        ModelOption(id: "haiku", name: "Haiku 5", description: "", efforts: [],
                    fast: false, defaultEffort: nil, ultra: false, ultraBlocked: nil, more: nil, needs: nil),
        ModelOption(id: "claude-opus-4-1", name: "Opus 4.1", description: "", efforts: ["low", "medium", "high"],
                    fast: false, defaultEffort: nil, ultra: false, ultraBlocked: nil, more: true, needs: nil),
    ]

    static let codex = ProviderInfo(
        id: "codex", name: "Codex", agent: "Codex", state: .ready, hint: nil, cli: "/usr/local/bin/codex", version: "0.130.0",
        capabilities: .none, levels: ["low", "medium", "high"], modes: ["default", "plan"])

    static let pi = ProviderInfo(
        id: "pi", name: "Pi", agent: "Pi", state: .ready, hint: nil, cli: "/usr/local/bin/pi", version: "0.87.1",
        capabilities: .none, levels: ["low", "medium", "high"], modes: [])

    static let codexModels = [
        ModelOption(id: "gpt-6-luna", name: "GPT-6 Luna", description: "", efforts: ["low", "medium", "high"],
                    fast: false, defaultEffort: "medium", ultra: false, ultraBlocked: nil, more: nil, needs: nil),
        ModelOption(id: "haiku", name: "Haiku, Codex's", description: "", efforts: [],
                    fast: false, defaultEffort: nil, ultra: false, ultraBlocked: nil, more: nil, needs: nil),
    ]

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        try container.mainContext.save()
        model = AppModel(container: container)
        model.models = Self.claudeModels
        model.modelsByAgent[Self.codex.id] = Self.codexModels
        model.providers = [.claude, Self.codex, Self.pi]
        model.selectedProjectID = project.id
    }

    /// A pick writes the last picks, a star the favorites, and Settings' keys are read from the
    /// host's defaults, so each test that touches them puts them back as they were.
    static func keepingDefaults() -> () -> Void {
        let defaults = UserDefaults.standard
        let keys = [NewThreads.model, NewThreads.provider, "lastModel", "lastProvider", "lastEffort", "lastPermissionMode", "favoriteModels", "menuModels"]
        let kept = keys.map { defaults.object(forKey: $0) }
        for key in keys { defaults.removeObject(forKey: key) }
        return { for (key, value) in zip(keys, kept) { defaults.set(value, forKey: key) } }
    }

    private func thread(on agent: String?, started: Bool) throws -> Chat {
        let chat = Chat(project: project)
        chat.provider = agent
        chat.started = started
        container.mainContext.insert(chat)
        try container.mainContext.save()
        return chat
    }

    private static func piModels(forbidden: String?) throws -> [ModelOption] {
        let reply: JSON = ["models": [
            ["id": "zai/glm-5.3", "name": "GLM-5.3", "description": "", "efforts": ["low"], "fast": false, "defaultEffort": .null,
             "ultra": false, "ultraBlocked": .null],
            ["id": "anthropic/claude-opus-5", "name": "Claude Opus 5", "description": "", "efforts": ["low"], "fast": false,
             "defaultEffort": .null, "ultra": false, "ultraBlocked": .null, "forbidden": forbidden.map(JSON.string) ?? .null],
        ]]
        return try #require(reply["models"]).decode([ModelOption].self)
    }

    @Test func claudeAloneGroupsAsItAlwaysHas() {
        let claude = [(agent: ProviderInfo.claude, models: Self.claudeModels)]
        let plain = ModelsPage.groups(claude, favorites: [])
        #expect(plain.map(\.id) == ["", "More models"])
        #expect(plain.map(\.title) == [nil, "More models"])
        #expect(plain.flatMap(\.rows).map(\.id) == ["default", "haiku", "claude-opus-4-1"])
        let starred = ModelsPage.groups(claude, favorites: ["haiku"])
        #expect(starred.map(\.title) == ["Favorites", "Models", "More models"])
        #expect(starred.allSatisfy { $0.agent == nil })
        // An agent turned on whose models haven't come yet adds nothing.
        #expect(ModelsPage.groups(claude + [(Self.codex, [])], favorites: ["haiku"]).map(\.id) == starred.map(\.id))
    }

    @Test func thePageScrollsOnlyToARowPastWhatItShows() {
        let many = (1...392).map {
            ModelOption(id: "opencode/m\($0)", name: "Model \($0)", description: "", efforts: [], fast: false, defaultEffort: nil,
                        ultra: false, ultraBlocked: nil, more: nil, needs: nil)
        }
        let opencode = ProviderInfo(id: "opencode", name: "OpenCode", agent: "OpenCode", state: .ready, hint: nil, cli: "/opt/homebrew/bin/opencode",
                                    version: "1.18.32", capabilities: .none, levels: [], modes: ["default"])
        let groups = ModelsPage.groups([(.claude, Self.claudeModels), (opencode, many)], favorites: [])
        #expect(ModelsPage.height(for: groups) == MarkPicker.effortHeight)
        #expect(!ModelsPage.below("haiku", in: groups))
        #expect(!ModelsPage.below("opencode/opencode/m1", in: groups))
        #expect(ModelsPage.below("opencode/opencode/m5", in: groups))
        #expect(ModelsPage.below("opencode/opencode/m392", in: groups))
        #expect(!ModelsPage.below(nil, in: groups))
        // Claude Code alone fits, whichever row is chosen.
        let claude = ModelsPage.groups([(.claude, Self.claudeModels)], favorites: ["haiku"])
        #expect(!claude.flatMap(\.rows).contains { ModelsPage.below($0.id, in: claude) })
    }

    @Test func severalAgentsListUnderTheirNamesWithFavoritesFromAllFirst() throws {
        let restore = Self.keepingDefaults()
        defer { restore() }
        model.modelsByAgent[Self.pi.id] = try Self.piModels(forbidden: nil)
        model.favoriteModels = ["codex/gpt-6-luna", "haiku", "pi/zai/glm-5.3"]
        model.showInMenu(ModelRef(provider: "claude", id: "claude-opus-4-1"), true)
        let groups = model.modelGroups(for: nil)
        #expect(groups.map(\.title) == ["Favorites", "Claude Code", "More models", "Codex", "Pi"])
        #expect(groups.map(\.agent) == [nil, "claude", nil, "codex", "pi"])
        #expect(groups[0].rows.map(\.id) == ["codex/gpt-6-luna", "haiku", "pi/zai/glm-5.3"])
        #expect(groups[3].rows.map(\.id) == ["codex/haiku"])
        #expect(groups[4].rows.map(\.ref) == [ModelRef(provider: "pi", id: "anthropic/claude-opus-5")])
        // An agent that can't run isn't listed.
        let signedOut = ProviderInfo(id: "pi", name: "Pi", agent: "Pi", state: .signedOut, hint: "Run `pi` in Terminal, then /login.",
                                     cli: nil, version: nil, capabilities: .none, levels: [], modes: [])
        model.providers = [.claude, Self.codex, signedOut]
        #expect(model.agentsListed(for: nil).map(\.id) == ["claude", "codex"])
        #expect(!model.modelGroups(for: nil).flatMap(\.rows).contains { $0.agent == "pi" })
    }

    @Test func twoAgentsModelsWithOneIdNeverCollide() throws {
        let restore = Self.keepingDefaults()
        defer { restore() }
        model.favoriteModels = []
        let draft = try thread(on: nil, started: false)
        let rows = model.modelGroups(for: draft).flatMap(\.rows).filter { $0.option.id == "haiku" }
        #expect(rows.map(\.id) == ["haiku", "codex/haiku"])
        model.toggleFavorite(rows[1].id)
        let favorites = try #require(model.modelGroups(for: draft).first)
        #expect(favorites.title == "Favorites")
        #expect(favorites.rows.map(\.ref) == [ModelRef(provider: "codex", id: "haiku")])
        // Picked, each is its own agent's.
        model.setModel(rows[1].ref, for: draft)
        #expect(draft.providerID == "codex" && draft.model == "haiku")
        #expect(model.option(for: draft)?.name == "Haiku, Codex's")
        model.setModel(rows[0].ref, for: draft)
        #expect(draft.providerID == "claude" && draft.model == "haiku")
        #expect(model.option(for: draft)?.name == "Haiku 5")
    }

    @Test func aForbiddenModelIsListedDimAndNotPicked() throws {
        model.modelsByAgent[Self.pi.id] = try Self.piModels(forbidden: "anthropic")
        let forbidden = try #require(model.option(ModelRef(provider: "pi", id: "anthropic/claude-opus-5")))
        #expect(forbidden.forbidden == "anthropic")
        #expect(!forbidden.pickable)
        #expect(model.option(ModelRef(provider: "pi", id: "zai/glm-5.3"))?.pickable == true)
        #expect(model.forbiddenHelp(forbidden, on: "pi") == "Turn on Pi's login in Settings › Agents to use Claude Opus 5")
        // With Settings › Agents' registry read, the help names the toggle as the pane does.
        let registry: JSON = ["id": "pi", "name": "Pi", "agent": "Pi", "route": "its RPC mode", "binary": true, "key": false, "forbidden": [
            ["id": "anthropic", "title": "Pi signed into claude.ai", "maker": "Anthropic", "sentence": .null, "url": "https://code.claude.com/docs/en/legal-and-compliance"],
        ]]
        model.agents = [try registry.decode(AgentInfo.self)]
        let help = "Turn on “Pi signed into claude.ai” in Settings › Agents to use Claude Opus 5"
        #expect(model.forbiddenHelp(forbidden, on: "pi") == help)
        // ⌘K lists it and says why it can't be picked.
        model.engineState = .ready
        let row = model.paletteSearchable().first { $0.id == "model.pi/anthropic/claude-opus-5" }
        #expect(row?.unavailable == help)
        #expect(model.paletteSearchable().first { $0.id == "model.pi/zai/glm-5.3" }?.unavailable == nil)
    }

    @Test func aDraftMovesToAnotherAgentsModelAndSoDoesABegunThreadBetweenTurns() throws {
        let restore = Self.keepingDefaults()
        defer { restore() }
        let draft = try thread(on: nil, started: false)
        draft.permissionMode = "auto"
        draft.effort = "max"
        #expect(model.agentsListed(for: draft).map(\.id) == ["claude", "codex", "pi"])
        model.setModel(ModelRef(provider: "codex", id: "gpt-6-luna"), for: draft)
        #expect(draft.providerID == "codex")
        #expect(draft.model == "gpt-6-luna")
        // Codex has neither Auto nor Max, so the draft asks and runs at Default.
        #expect(draft.permissionMode == "default")
        #expect(draft.effort == nil)
        #expect(model.lastModel == ModelRef(provider: "codex", id: "gpt-6-luna"))
        #expect(model.startingProvider == "codex")

        // Begun, it's still offered every agent (K-214, HandoverTests), and Claude's model moves it back.
        draft.started = true
        #expect(model.agentsListed(for: draft).map(\.id) == ["claude", "codex", "pi"])
        model.setModel(ModelRef(provider: "claude", id: "default"), for: draft)
        #expect(draft.providerID == "claude" && draft.model == "default")
        model.setModel(ModelRef(provider: "codex", id: "haiku"), for: draft)
        #expect(draft.providerID == "codex" && draft.model == "haiku")

        // An older Claude thread is offered a codex favorite as well.
        let older = try thread(on: nil, started: true)
        model.favoriteModels = ["codex/gpt-6-luna", "haiku"]
        let groups = model.modelGroups(for: older)
        #expect(groups.first?.title == "Favorites")
        #expect(groups.first?.rows.map(\.id) == ["codex/gpt-6-luna", "haiku"])
    }

    @Test func settingsPicksTheAgentAndModelNewThreadsStartOn() throws {
        let restore = Self.keepingDefaults()
        defer { restore() }
        let defaults = UserDefaults.standard
        defaults.set("codex/gpt-6-luna", forKey: NewThreads.model)
        defaults.set("codex", forKey: NewThreads.provider)
        #expect(model.startingProvider == "codex")
        #expect(model.startingModel == "gpt-6-luna")
        #expect(model.option(for: nil)?.id == "gpt-6-luna")
        #expect(model.defaultModel(for: nil) == ModelRef(provider: "codex", id: "gpt-6-luna"))
        let chat = try #require(model.newChat())
        #expect(chat.providerID == "codex" && chat.model == "gpt-6-luna")
        // A begun Claude thread goes back to Claude's Default, not to Codex's model.
        let older = try thread(on: nil, started: true)
        #expect(model.defaultModel(for: older) == ModelRef(provider: "claude", id: ModelOption.claudeDefault))
    }

    @Test func anotherAgentsModelsArriveUnderItsName() throws {
        let list: JSON = [["id": "gpt-6-mini", "name": "GPT-6 Mini", "description": "", "efforts": [], "fast": false,
                           "defaultEffort": .null, "ultra": false, "ultraBlocked": .null]]
        model.route(EngineEvent(name: "models", threadId: nil, body: ["event": "models", "models": list, "settingsEffort": .null,
                                                                      "ultraKnown": false, "provider": "codex"]))
        #expect(model.models(of: "codex").map(\.id) == ["gpt-6-mini"])
        #expect(model.models == Self.claudeModels)
    }

    private static func many(_ count: Int, _ prefix: String, more: Bool? = nil) -> [ModelOption] {
        (1...count).map {
            ModelOption(id: "\(prefix)\($0)", name: "Model \($0)", description: "", efforts: [], fast: false, defaultEffort: nil,
                        ultra: false, ultraBlocked: nil, more: more, needs: nil)
        }
    }

    @Test func eachAgentShowsItsDefaultAndItsOwnShortListOutOfTheBox() throws {
        let restore = Self.keepingDefaults()
        defer { restore() }
        // Claude Code's own list without its older models, five at most.
        #expect(ModelsPage.picks(Self.claudeModels, on: "claude") == ["default", "haiku"])
        #expect(ModelsPage.picks(Self.many(7, "c") + Self.many(2, "old", more: true), on: "claude") == ["c1", "c2", "c3", "c4", "c5"])
        // Another agent's list of five or fewer is its own; past that only its default, which comes first.
        #expect(ModelsPage.picks(Self.many(5, "m"), on: "codex") == ["m1", "m2", "m3", "m4", "m5"])
        #expect(ModelsPage.picks(Self.many(392, "vendor/m"), on: "opencode") == ["vendor/m1"])
        #expect(ModelsPage.picks([], on: "opencode").isEmpty)

        model.modelsByAgent["pi"] = Self.many(392, "vendor/m")
        let rows = model.modelGroups(for: nil).flatMap(\.rows).map(\.id)
        #expect(rows == ["default", "haiku", "codex/gpt-6-luna", "codex/haiku", "pi/vendor/m1"])
        #expect(model.menuModels.isEmpty)
    }

    @Test func turningAModelOffTakesItOutOfTheMenuAndTheOneInUseStays() throws {
        let restore = Self.keepingDefaults()
        defer { restore() }
        let luna = ModelRef(provider: "codex", id: "gpt-6-luna")
        model.showInMenu(luna, false)
        #expect(model.menuModels == ["codex/gpt-6-luna": false])
        #expect(!model.modelGroups(for: nil).flatMap(\.rows).contains { $0.id == "codex/gpt-6-luna" })
        model.engineState = .ready
        #expect(model.paletteSearchable().contains { $0.id == "model.codex/haiku" })
        #expect(!model.paletteSearchable().contains { $0.id == "model.codex/gpt-6-luna" })
        // One of OpenCode's hundreds turned on joins the menu.
        model.modelsByAgent["pi"] = Self.many(392, "vendor/m")
        model.showInMenu(ModelRef(provider: "pi", id: "vendor/m200"), true)
        #expect(model.modelGroups(for: nil).flatMap(\.rows).map(\.id).contains("pi/vendor/m200"))

        // A thread on the model turned off keeps it in its menu, checked.
        let draft = try thread(on: "codex", started: false)
        draft.model = "gpt-6-luna"
        #expect(model.modelGroups(for: draft).flatMap(\.rows).contains { $0.id == "codex/gpt-6-luna" })
        let begun = try thread(on: "codex", started: true)
        begun.model = "gpt-6-luna"
        #expect(model.modelGroups(for: begun).flatMap(\.rows).map(\.id).filter { $0.hasPrefix("codex/") } == ["codex/gpt-6-luna", "codex/haiku"])
        // Turned back on, the choice is forgotten and the model follows its agent's picks again.
        model.showInMenu(luna, true)
        #expect(model.menuModels == ["pi/vendor/m200": true])
    }

    @Test func theChoiceSurvivesARelaunch() throws {
        let restore = Self.keepingDefaults()
        defer { restore() }
        model.showInMenu(ModelRef(provider: "codex", id: "haiku"), false)
        model.showInMenu(ModelRef(provider: "claude", id: "claude-opus-4-1"), true)
        let relaunched = AppModel(container: container)
        #expect(relaunched.menuModels == ["codex/haiku": false, "claude-opus-4-1": true])
        relaunched.models = Self.claudeModels
        relaunched.modelsByAgent["codex"] = Self.codexModels
        relaunched.providers = [.claude, Self.codex]
        #expect(relaunched.shownModels(of: "codex").map(\.id) == ["gpt-6-luna"])
        #expect(relaunched.shownModels(of: "claude").map(\.id) == ["default", "haiku", "claude-opus-4-1"])
    }

    @Test func severalAgentsFoldToTheirNamesAndTheOneInUseIsOpen() throws {
        let restore = Self.keepingDefaults()
        defer { restore() }
        model.modelsByAgent[Self.pi.id] = try Self.piModels(forbidden: nil)
        let groups = model.modelGroups(for: nil, open: ["claude"])
        #expect(groups.map(\.id) == ["agent:claude", "agent:codex", "agent:pi"])
        #expect(groups.map(\.open) == [true, false, false])
        #expect(groups.flatMap(\.rows).map(\.id) == ["default", "haiku"])
        // Three agents' rows of 36pt, Claude's two models of 42 and the page's padding.
        #expect(ModelsPage.height(for: groups) == 208)
        // Opened, an agent lists its models; without `open` the native menus list them all.
        #expect(model.modelGroups(for: nil, open: ["claude", "codex"]).flatMap(\.rows).count == 4)
        #expect(model.modelGroups(for: nil).allSatisfy { $0.open == nil })
        // One agent alone, as a thread with a turn running has, doesn't fold.
        let begun = try thread(on: "codex", started: true)
        model.conversation(for: begun).userSent("go")
        #expect(model.modelGroups(for: begun, open: []).map(\.open) == [nil])
        #expect(model.modelGroups(for: begun, open: []).flatMap(\.rows).count == 2)
    }
}
