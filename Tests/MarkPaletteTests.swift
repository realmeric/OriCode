import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import OriCode

/// Each agent's colour on a thread's mark: the dot while the head works on it, and a ray for each
/// worker, as drawn, still and turning. One at a time, since two set the palette's default.
@MainActor
@Suite(.serialized)
struct MarkPaletteTests {
    private let context: ModelContext
    private let project: Project

    init() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        project = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(project)
        UserDefaults.standard.removeObject(forKey: MarkPalette.key)
    }

    private static let agents = ["codex", "cursor", "copilot", "opencode", "grok", "devin", "pi", "antigravity", "zai", "deepseek",
                                 "openrouter", "meta", "commandcode"]
    /// Makers whose own mark is black or white.
    private static let white = ["cursor", "opencode", "grok", "pi"]

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

    @Test func claudeIsClaudesOrangeInEveryPalette() {
        for palette in MarkPalette.allCases {
            #expect(components(palette.color(for: ProviderInfo.claudeID)) == components(Ink.claude))
        }
        #expect(MarkPalette.standard == .soft)
    }

    @Test func everyOtherAgentHasAColourOfItsOwnAndAnUnknownOneIsWhite() {
        for palette in MarkPalette.allCases {
            for agent in Self.agents {
                let color = components(palette.color(for: agent))
                if Self.white.contains(agent) {
                    #expect(color == [1, 1, 1], "\(agent) in \(palette)")
                } else {
                    #expect(color != [1, 1, 1], "\(agent) in \(palette)")
                    #expect(color != components(Ink.claude), "\(agent) in \(palette)")
                }
            }
            #expect(components(palette.color(for: "someone-new")) == [1, 1, 1])
        }
        // Brand is each maker's own; soft and quiet move it.
        #expect(components(MarkPalette.brand.color(for: "deepseek")).map { ($0 * 255).rounded() } == [0x4D, 0x6B, 0xFE])
        #expect(components(MarkPalette.soft.color(for: "deepseek")) != components(MarkPalette.brand.color(for: "deepseek")))
        #expect(components(MarkPalette.quiet.color(for: "deepseek")) != components(MarkPalette.soft.color(for: "deepseek")))
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

    private func render(_ view: some View) async throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: Self.side, height: Self.side).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.close()
        return rep
    }

    private func pixel(_ rep: NSBitmapImageRep, at point: CGPoint) -> [Double] {
        let scale = CGFloat(rep.pixelsWide) / Self.side
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

    /// REA-149's thread: a Claude head at work with two workers on Codex and one on Cursor.
    @Test func theDotIsTheHeadsAgentAndEachRayItsWorkers() async throws {
        let conversation = thread(on: nil)
        receive("turn.started", ["sessionId": "s"], in: conversation)
        receive("heads", ["heads": [head("a", agent: "codex"), head("b", agent: "codex"), head("c", agent: "cursor")]], in: conversation)
        let rep = try await render(ThreadMark(conversation: conversation))
        let codex = MarkPalette.standard.color(for: "codex")
        #expect(try await drawn(rep, ray: nil, in: Ink.claude))
        #expect(try await drawn(rep, ray: 0, in: codex))
        #expect(try await drawn(rep, ray: 1, in: codex))
        #expect(try await drawn(rep, ray: 2, in: .white))
        // At rest, white.
        #expect(try await drawn(rep, ray: 4, in: .white))
    }

    @Test func aCodexThreadIsCodexsColourAndWhiteOnceItsTurnEnds() async throws {
        UserDefaults.standard.set(MarkPalette.brand.rawValue, forKey: MarkPalette.key)
        defer { UserDefaults.standard.removeObject(forKey: MarkPalette.key) }
        let conversation = thread(on: "codex")
        receive("turn.started", ["sessionId": "s"], in: conversation)
        // The dot alone, which the still mark draws.
        let codex = MarkPalette.brand.color(for: "codex")
        var rep = try await render(ThreadMark(conversation: conversation))
        #expect(try await drawn(rep, ray: nil, in: codex))

        receive("heads", ["heads": [head("a")]], in: conversation)
        rep = try await render(ThreadMark(conversation: conversation))
        #expect(try await drawn(rep, ray: 0, in: codex))

        receive("turn.done", [:], in: conversation)
        rep = try await render(ThreadMark(conversation: conversation))
        #expect(try await drawn(rep, ray: nil, in: .white))
        #expect(try await drawn(rep, ray: 0, in: codex))
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
}
