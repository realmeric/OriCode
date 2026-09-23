import Testing
@testable import OriCode

@MainActor
struct PaletteTests {
    private func item(_ id: String, _ title: String, _ kind: PaletteItem.Kind = .command, keywords: [String] = []) -> PaletteItem {
        PaletteItem(id: id, kind: kind, title: title, keywords: keywords, action: .run {})
    }

    @Test func blankQueryKeepsTheOrderGiven() {
        let items = [item("b", "Beta"), item("a", "Alpha")]
        #expect(Palette.rank(items, by: "  ").map(\.id) == ["b", "a"])
    }

    @Test func keywordsAreSearchedButTheTitleLeads() {
        let items = [item("changes", "Changes", keywords: ["commit", "diff"]), item("copy", "Copy last reply")]
        #expect(Palette.rank(items, by: "commit").map(\.id) == ["changes"])
    }

    @Test func aRowUsedLatelyComesFirst() {
        let items = [item("new", "New thread"), item("next", "Next thread")]
        #expect(Palette.rank(items, by: "ne").first?.id == "new")
        #expect(Palette.rank(items, by: "ne", recents: ["next"]).first?.id == "next")
    }

    @Test func choicesFromInsideListsComeAfterCommands() {
        let items = [item("mode.plan", "Permissions: Plan", .choice), item("plan.command", "Plan", .command)]
        #expect(Palette.rank(items, by: "plan").map(\.id) == ["plan.command", "mode.plan"])
    }

    @Test func aTieGoesToTheCommand() {
        let items = [item("thread", "Stop", .thread), item("command", "Stop", .command)]
        #expect(Palette.rank(items, by: "stop").map(\.id) == ["command", "thread"])
    }

    @Test func levelsStackAndComeBack() {
        let state = PaletteState()
        state.push(.input(PaletteInput(title: "Branch", placeholder: "Name", submit: { _ in nil })), query: "x")
        #expect(state.stack.count == 2)
        #expect(state.level.query == "x")
        #expect(state.pop())
        #expect(!state.pop())
        #expect(state.stack.count == 1)
    }
}
