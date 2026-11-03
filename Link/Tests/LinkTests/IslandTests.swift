import Foundation
import Testing
@testable import Link

@Suite struct IslandTests {
    private let project = ProjectInfo(id: UUID(), name: "OriCode", initials: "OE", color: 1, starts: true, order: 0)

    private func thread(_ title: String = "A thread", status: ThreadStatus = .working, step: String? = nil, rays: [Int: String] = [:], agent: String = "claude", at: Date = .now) -> ThreadInfo {
        ThreadInfo(id: UUID(), project: project.id, title: title, agent: agent, status: status, step: step, rays: rays, reply: nil, pinned: false, updated: at)
    }

    private func ask(_ thread: ThreadInfo, asked: Date = .now) -> AskInfo {
        AskInfo(id: UUID().uuidString, thread: thread.id, kind: "permission", title: "Run a command?", detail: "swift test", code: true, choices: [], questions: [], worker: nil, asked: asked)
    }

    private func state(_ threads: [ThreadInfo], asks: [AskInfo] = [], mac: MacState = .awake) -> IslandState? {
        IslandState(mac: MacInfo(name: "Mac", version: "1", state: mac), projects: [project.id: project],
                    threads: Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) }), asks: Dictionary(uniqueKeysWithValues: asks.map { ($0.id, $0) }))
    }

    @Test func restsWithNothingAtWorkAndWithTheMacGone() {
        #expect(state([thread(status: .idle), thread(status: .failed)]) == nil)
        #expect(state([thread()], mac: .asleep) == nil)
        #expect(state([thread()], mac: .closed) == nil)
    }

    @Test func whatWaitsComesFirstAndIsWhereATapLands() throws {
        let busy = thread(step: "Writing", at: .now)
        let older = thread(status: .asking, at: .now - 600)
        let state = try #require(state([busy, older], asks: [ask(older)]))
        #expect(state.rows.map(\.id) == [older.id, busy.id])
        #expect(state.rows[0].asking && state.rows[0].step == "swift test")
        #expect(state.working == 2)
        #expect(state.asks == 1)
        #expect(IslandLink.thread(in: state.link) == older.id)
    }

    @Test func nothingWaitingLandsHome() throws {
        #expect(try #require(state([thread()])).link == IslandLink.home)
    }

    @Test func raysAreTheAgentsAtWork() throws {
        let state = try #require(state([thread(rays: [3: "codex", 1: "claude"], at: .now), thread(agent: "pi", at: .now - 1)]))
        #expect(state.rays == [0: "claude", 1: "codex", 2: "pi"])
        let many = try #require(self.state((0..<9).map { _ in thread() }))
        #expect(many.rays.count == 6)
    }

    /// The system refuses a Live Activity's content past 4 KB, with its attributes.
    @Test func worstCaseFitsInALiveActivity() throws {
        let long = String(repeating: "🦊", count: 400)
        var threads = (0..<8).map { _ in thread(long, step: long, rays: [0: "copilot", 1: "antigravity", 2: "openrouter", 3: "deepseek", 4: "copilot", 5: "claude"]) }
        threads[0].status = .asking
        var worst = project
        worst.name = String(repeating: "é", count: 60)
        let state = try #require(IslandState(mac: nil, projects: [worst.id: worst], threads: Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) }), asks: [:]))
        #expect(try JSONEncoder().encode(state).count < 3_000)
    }

    @Test func linksRoundTripAndRefuseOthers() throws {
        let id = UUID()
        #expect(IslandLink.thread(in: IslandLink.thread(id)) == id)
        #expect(IslandLink.thread(in: IslandLink.home) == nil)
        #expect(IslandLink.thread(in: try #require(URL(string: "https://realmeric.com/thread/\(id.uuidString)"))) == nil)
        #expect(IslandLink.thread(in: try #require(URL(string: "oricode://thread/nope"))) == nil)
    }
}
