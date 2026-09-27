import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import OriCode

/// Each agent's colour and logo: its maker's own, on a thread's mark, the dot while
/// the head works on it and a ray for each worker, as drawn, still and turning, and on the effort
/// rail of a thread on that agent.
@MainActor
struct MarkPaletteTests {
    private let context: ModelContext
    private let project: Project

    init() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        project = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(project)
    }

    private static let agents = ["codex", "cursor", "copilot", "opencode", "grok", "devin", "pi", "antigravity", "zai", "deepseek",
                                 "openrouter", "meta", "commandcode"]

    private func thread(on agent: String?) -> Conversation {
        let chat = Chat(project: project)
        chat.provider = agent
        context.insert(chat)
        return Conversation(chat: chat, context: context)
    }

    private func receive(_ name: String, _ body: [String: JSON], in conversation: Conversation) {
        var body = body
        body["event"] = .string(name)
        conversation.receive(EngineEvent(name: name, threadId: conversation.chat.id.uuidString, body: .object(body)))
    }

    private func head(_ id: String, agent: String? = nil) -> JSON {
        var body: [String: JSON] = ["id": .string(id), "kind": "agent", "toolUseId": .string("call-" + id), "label": .string(id)]
        if let agent { body["agent"] = .string(agent) }
        return .object(body)
    }

    private func components(_ color: Color) -> [Double] {
        let color = NSColor(color).usingColorSpace(.sRGB)!
        return [color.redComponent, color.greenComponent, color.blueComponent]
    }

    /// Where a colour sits in OKLab.
    private func oklab(_ color: Color) -> (l: Double, a: Double, b: Double) {
        let linear = components(color).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let (r, g, b) = (linear[0], linear[1], linear[2])
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s)
    }

    private func hueApart(_ p: (l: Double, a: Double, b: Double), _ q: (l: Double, a: Double, b: Double)) -> Double {
        let turn = abs(atan2(p.b, p.a) - atan2(q.b, q.a)) * 180 / .pi
        return min(turn, 360 - turn)
    }

    @Test func claudeKeepsItsOrangeAndAnUnknownAgentIsWhite() {
        #expect(components(MarkPalette.color(for: ProviderInfo.claudeID)).map { ($0 * 255).rounded() } == [0xD9, 0x77, 0x57])
        #expect(MarkPalette.ink(for: ProviderInfo.claudeID) == .claude)
        #expect(components(MarkPalette.color(for: "someone-new")) == [1, 1, 1])
    }

    /// Each maker's colour as its brand page or its own site's logo draws it, white where the mark
    /// is black or white.
    private static let makers: [String: UInt32] = [
        "claude": 0xD97757, "codex": 0xFFFFFF, "cursor": 0xFFFFFF, "copilot": 0x8534F3, "opencode": 0xFFFFFF, "grok": 0xFFFFFF,
        "devin": 0xFFFFFF, "pi": 0xF09082, "antigravity": 0x3186FF, "zai": 0xFFFFFF, "deepseek": 0x4D6BFE, "openrouter": 0xC8FF00,
        "meta": 0x0064E0, "commandcode": 0xFFFFFF,
    ]

    private static var coloured: [String] {
        agents.filter { makers[$0] != 0xFFFFFF }
    }

    @Test func eachAgentIsInItsMakersColour() {
        for agent in [ProviderInfo.claudeID] + Self.agents {
            let hex = Self.makers[agent, default: 0]
            #expect(components(MarkPalette.color(for: agent)).map { ($0 * 255).rounded() } == [16, 8, 0].map { Double(hex >> $0 & 0xFF) },
                    "\(agent)")
        }
    }

    /// An agent's ember and white-hot are its own hue, paler, as Claude's are its orange.
    @Test func eachAgentsHeatPalesTowardItsOwnHue() {
        for agent in Self.coloured {
            let ink = MarkPalette.ink(for: agent)
            let (base, ember, hot) = (oklab(ink.color), oklab(ink.emberColor), oklab(ink.whiteHotColor))
            #expect(ember.l > base.l && hot.l > ember.l, "\(agent)")
            #expect(hueApart(base, ember) < 6, "\(agent)'s ember turns \(hueApart(base, ember))°")
        }
    }

    /// A white agent's heat can't pale toward white, so it climbs from silver, not a flat white bar.
    @Test func aWhiteAgentsHeatRunsFromSilverToWhite() {
        for agent in Self.agents where !Self.coloured.contains(agent) {
            let ink = MarkPalette.ink(for: agent)
            #expect(ink == .silver, "\(agent)")
        }
        let (base, ember, hot) = (oklab(AgentInk.silver.color), oklab(AgentInk.silver.emberColor), oklab(AgentInk.silver.whiteHotColor))
        #expect(base.l < 0.75 && ember.l > base.l + 0.15 && hot.l > ember.l)
        #expect(AgentInk.silver.whiteHot == [1, 1, 1])
    }

    /// Each agent's maker's logo is in the asset catalog under the agent's id, as a template the
    /// mark tints.
    @Test func everyAgentHasItsMakersLogo() {
        for agent in [ProviderInfo.claudeID] + Self.agents {
            let image = NSImage(named: agent)
            #expect(image != nil, "\(agent) has no logo")
            #expect(image?.isTemplate == true, "\(agent)'s logo isn't a template")
            #expect(AgentMark.hasLogo(agent))
        }
        #expect(!AgentMark.hasLogo("someone-new"))
    }

    @Test func aHeadIsOnTheThreadsAgentUnlessTheEngineNamesAnother() {
        let codex = thread(on: "codex")
        receive("heads", ["heads": [head("a"), head("b", agent: "cursor")]], in: codex)
        #expect(codex.heads.list.map(\.agent) == ["codex", "cursor"])
        #expect(codex.heads.rayAgents == [0: "codex", 1: "cursor"])

        // A thread from before there were other agents is Claude Code's.
        let claude = thread(on: nil)
        receive("heads", ["heads": [head("a")]], in: claude)
        #expect(claude.heads.rayAgents == [0: ProviderInfo.claudeID])
    }

    @Test func anEndedHeadTakesItsAgentOffItsRay() {
        let conversation = thread(on: nil)
        receive("heads", ["heads": [head("a", agent: "codex"), head("b", agent: "cursor")]], in: conversation)
        receive("heads", ["heads": [head("b", agent: "cursor")]], in: conversation)
        #expect(conversation.heads.rayAgents == [1: "cursor"])
        #expect(conversation.heads.lit == [1])
    }

    // MARK: Drawn

    private static let side: CGFloat = 40

    /// Drawn after `steps` layouts 20ms apart: enough for a mark, and fifty for the rail to pour in.
    private func render(_ view: some View, size: CGSize = CGSize(width: side, height: side), steps: Int = 4) async throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<steps {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        // Gone with its window, so the picker's timers can't draw it again once its store is gone.
        window.contentView = nil
        window.close()
        return rep
    }

    private func pixel(_ rep: NSBitmapImageRep, at point: CGPoint, side: CGFloat = side) -> [Double] {
        let scale = CGFloat(rep.pixelsWide) / side
        let color = rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))!
        return [color.redComponent, color.greenComponent, color.blueComponent]
    }

    /// Whether the middle of ray `index`, or the dot with nil, has the colour of a disc of `expected`
    /// rendered the same way, so both pass through the same colour spaces. Read unpremultiplied,
    /// so a ray at rest compares by colour alone.
    private func drawn(_ rep: NSBitmapImageRep, ray index: Int?, in expected: Color) async throws -> Bool {
        let middle = Self.side / 2
        var point = CGPoint(x: middle, y: middle)
        if let index {
            let angle = (-90 + Double(index) * 60) * .pi / 180
            let radius = middle - max(1.2, Self.side * 0.085) / 2
            point = CGPoint(x: middle + radius * cos(angle), y: middle + radius * sin(angle))
        }
        let reference = try await render(Circle().fill(expected).opacity(0.92))
        return zip(pixel(rep, at: point), pixel(reference, at: CGPoint(x: middle, y: middle))).allSatisfy { abs($0 - $1) < 0.02 }
    }

    /// REA-149's thread, with workers on agents whose makers have a colour: a Claude head at work
    /// with two workers on DeepSeek and one on Copilot.
    @Test func theDotIsTheHeadsAgentAndEachRayItsWorkers() async throws {
        let conversation = thread(on: nil)
        receive("turn.started", ["sessionId": "s"], in: conversation)
        receive("heads", ["heads": [head("a", agent: "deepseek"), head("b", agent: "deepseek"), head("c", agent: "copilot")]], in: conversation)
        let rep = try await render(ThreadMark(conversation: conversation))
        let deepseek = MarkPalette.color(for: "deepseek")
        #expect(try await drawn(rep, ray: nil, in: MarkPalette.color(for: ProviderInfo.claudeID)))
        #expect(try await drawn(rep, ray: 0, in: deepseek))
        #expect(try await drawn(rep, ray: 1, in: deepseek))
        #expect(try await drawn(rep, ray: 2, in: MarkPalette.color(for: "copilot")))
        // At rest, white.
        #expect(try await drawn(rep, ray: 4, in: .white))
    }

    @Test func aDeepSeekThreadIsDeepSeeksColourAndWhiteOnceItsTurnEnds() async throws {
        let conversation = thread(on: "deepseek")
        receive("turn.started", ["sessionId": "s"], in: conversation)
        // The dot alone, which the still mark draws.
        let deepseek = MarkPalette.color(for: "deepseek")
        var rep = try await render(ThreadMark(conversation: conversation))
        #expect(try await drawn(rep, ray: nil, in: deepseek))

        receive("heads", ["heads": [head("a")]], in: conversation)
        rep = try await render(ThreadMark(conversation: conversation))
        #expect(try await drawn(rep, ray: 0, in: deepseek))

        receive("turn.done", [:], in: conversation)
        rep = try await render(ThreadMark(conversation: conversation))
        #expect(try await drawn(rep, ray: nil, in: .white))
        #expect(try await drawn(rep, ray: 0, in: deepseek))
    }

    /// Every mark that isn't a thread's, the effort thumb's, the About pane's, a workflow's with no
    /// agent named, draws exactly as it did: no colour given is the mark's own.
    @Test func aMarkGivenNoColoursDrawsAsBefore() async throws {
        let white: [Int: Color] = [0: .white, 2: .white, 3: .white]
        for turning in [false, true] {
            let plain = try await render(RaysMark(slots: [0, 2, 3], turning: turning))
            let given = try await render(RaysMark(slots: [0, 2, 3], turning: turning, colors: white, dotColor: .white))
            #expect(plain.tiffRepresentation == given.tiffRepresentation)
        }
    }

    /// The picker's rail burns in the thread's agent's ink: silver in a Codex thread, whose maker
    /// draws in white, and Claude's orange in a Claude one.
    @Test func theRailIsInTheThreadsAgentsInk() async throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        let model = AppModel(container: container)
        let levels = ["low", "medium", "high"]
        model.models = [ModelOption(id: "default", name: "Default", description: "", efforts: levels, fast: false, defaultEffort: "high",
                                    ultra: false, ultraBlocked: nil, more: nil, needs: nil)]
        model.modelsByAgent["codex"] = [ModelOption(id: "gpt-6-luna", name: "GPT-6 Luna", description: "", efforts: levels, fast: false,
                                                    defaultEffort: "high", ultra: false, ultraBlocked: nil, more: nil, needs: nil)]
        model.providers = [.claude, ProviderInfo(id: "codex", name: "Codex", agent: "Codex", state: .ready, hint: nil, cli: "/usr/local/bin/codex",
                                                 version: "0.130.0", capabilities: .none, levels: levels, modes: ["default"])]
        model.selectedProjectID = project.id
        let size = CGSize(width: 320, height: MarkPicker.effortHeight)
        for agent in [ProviderInfo.claudeID, "codex"] {
            let chat = Chat(project: project)
            chat.provider = agent
            chat.model = agent == "codex" ? "gpt-6-luna" : "default"
            chat.effort = "high"
            container.mainContext.insert(chat)
            let rep = try await render(MarkPicker(chat: chat).environment(model), size: size, steps: 50)
            let reference = try await render(Rectangle().fill(MarkPalette.ink(for: agent).color))
            // The fill's start, left of the thumb, halfway down the rail.
            let fill = pixel(rep, at: CGPoint(x: 26, y: 208), side: size.width)
            let expected = pixel(reference, at: CGPoint(x: 20, y: 20))
            #expect(zip(fill, expected).allSatisfy { abs($0 - $1) < 0.04 }, "\(agent): \(fill) against \(expected)")
        }
    }
}
