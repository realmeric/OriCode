import Testing
@testable import OriCode

struct FuzzyTests {
    @Test func needsEveryCharacterInOrder() {
        #expect(Fuzzy.score("tst", in: "the store") != nil)
        #expect(Fuzzy.score("tts", in: "the store") == nil)
    }

    @Test func wordStartsBeatScatteredLetters() {
        let ranked = Fuzzy.rank(["alpha beta gamma", "abracadabra begins"], by: "abg") { $0 }
        #expect(ranked.first == "alpha beta gamma")
    }

    @Test func emptyQueryKeepsOrder() {
        #expect(Fuzzy.rank(["b", "a"], by: " ") { $0 } == ["b", "a"])
    }
}

struct TitleTests {
    @Test func firstLineCutAtSixty() {
        let long = String(repeating: "word ", count: 20)
        let title = Chat.title(from: long + "\nsecond line")
        #expect(title.count == 60)
        #expect(title.hasSuffix("…"))
        #expect(Chat.title(from: "  Fix the build  \nmore") == "Fix the build")
        #expect(Chat.title(from: "\n\n") == Chat.untitled)
    }
}

struct DiffTests {
    @Test func linesInOrder() {
        let lines = Diff.between("a\nb\nc", "a\nB\nc")
        #expect(lines.map(\.kind) == [.context, .deleted, .added, .context])
    }
}
