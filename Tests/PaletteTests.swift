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

    @Test func messagesAreSearchedFromTwoCharacters() {
        #expect(MessageSearch.words(" a ").isEmpty)
        #expect(MessageSearch.words("ab") == ["ab"])
        #expect(MessageSearch.words(" dynamic  island ") == ["dynamic", "island"])
    }

    @Test func aMessageHoldsEveryWordInAnyOrder() {
        let text = "The capsule grows the way the Dynamic Island does."
        #expect(MessageSearch.match(["island", "capsule"], in: text) != nil)
        #expect(MessageSearch.match(["island", "notch"], in: text) == nil)
    }

    @Test func caseAndAccentsDontMatter() {
        #expect(MessageSearch.snippet(["cafe"], in: "Meet at the Café") == "Meet at the Café")
        #expect(MessageSearch.snippet(["SISE"], in: "Şişe kırıldı") == "Şişe kırıldı")
        #expect(MessageSearch.snippet(["kirildi"], in: "Şişe kırıldı") == "Şişe kırıldı")
        #expect(MessageSearch.match(["istanbul"], in: "İstanbul'da") != nil)
    }

    @Test func aSnippetIsOneLineAroundTheFirstWordFound() {
        let text = "The capsule sits in the toolbar's row,\nlevel with the traffic lights, and each surface drops from the top edge today."
        #expect(MessageSearch.snippet(["lights", "traffic"], in: text) == "…with the traffic lights, and each…")
        #expect(MessageSearch.snippet(["traffic", "notch"], in: text) == nil)
        #expect(MessageSearch.snippet(["capsule"], in: text) == "The capsule sits in the toolbar's row,…")
        #expect(MessageSearch.snippet(["island"], in: "Make the review grow out of the capsule, the way the Dynamic Island grows.")
            == "…the way the Dynamic Island grows.")
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
