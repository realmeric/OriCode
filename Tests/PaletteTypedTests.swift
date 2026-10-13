import Foundation
import SwiftData
import Testing
@testable import OriCode

/// ⌘K keeps what it can reach from one letter to the next and reads a message's line from the
/// text near its match. Neither may change a row.
@MainActor
struct PaletteTypedTests {
    private let container: ModelContainer
    private let model: AppModel
    private let project: Project
    private let chats: [Chat]
    private let suite = "PaletteTypedTests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        container = try TestStore.memory()
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        var made: [Chat] = []
        for title in ["The review's git read", "Şişe kırıldı", "Second thoughts"] {
            let chat = Chat(project: project, title: title)
            chat.started = true
            chat.position = Double(made.count)
            made.append(chat)
        }
        chats = made
        chats.forEach(container.mainContext.insert)
        try container.mainContext.save()
        model = AppModel(container: container, drafts: defaults)
        model.select(chats[0])
        let long = String(repeating: "The capsule sits in the toolbar's row, level with the traffic lights.\n\n", count: 40)
        for (index, chat) in chats.enumerated() {
            model.said.add(UUID(), in: chat.id, user: true, text: "Read the review again, git says thread \(index) moved")
            model.said.add(UUID(), in: chat.id, user: false, text: long + "The review of the git read is done, şişe kırıldı.\n" + long)
        }
    }

    private func forget() {
        defaults.removePersistentDomain(forName: suite)
        try? container.mainContext.save()
    }

    /// Everything a row draws, and its place.
    private func read(_ lines: [PaletteLine]) -> [String] {
        lines.map { line in
            switch line {
            case .heading(let title):
                "# " + title
            case .item(let item, let index):
                [String(index), item.id, item.title, item.subtitle ?? "-", item.unavailable ?? "-", item.shortcut ?? "-", String(item.checked)].joined(separator: " | ")
            }
        }
    }

    /// The turn after whatever the main queue already holds, which is when a change is heard of.
    private func hop() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    @Test func everyLetterGivesTheRowsAListMadeFreshWould() async throws {
        defer { forget() }
        model.said.read(from: container)
        while !model.said.ready { await hop() }
        for query in ["review git", "Pin thread", "sise kir", "second  th", "settings: "] {
            var typed = ""
            for letter in query {
                typed.append(letter)
                let level = PaletteState.Level(kind: .root, query: typed)
                let kept = read(model.paletteLines(for: level, of: model.paletteReachKept()))
                model.paletteFound = nil
                #expect(kept == read(model.paletteLines(for: level, of: model.paletteReach())), "\(typed)")
                #expect(!kept.isEmpty, "\(typed)")
            }
        }
        let found = read(model.paletteLines(for: PaletteState.Level(kind: .root, query: "review git"), of: model.paletteReachKept()))
        #expect(found.contains("# Messages"))
        // Nothing typed lists from the same kept rows.
        let top = PaletteState.Level(kind: .root)
        #expect(read(model.paletteLines(for: top, of: model.paletteReachKept())) == read(model.paletteLines(for: top, of: model.paletteReach())))
    }

    @Test func aRowThatChangesWhileItsUpIsRightOnTheNextLetter() async throws {
        defer { forget() }
        let titles = { (query: String) in
            self.model.paletteLines(for: PaletteState.Level(kind: .root, query: query), of: self.model.paletteReachKept()).compactMap { line -> String? in
                if case .item(let item, _) = line { return item.title }
                return nil
            }
        }
        #expect(titles("pin").contains("Pin thread"))
        model.togglePin(chats[0])
        await hop()
        #expect(titles("pin ").contains("Unpin thread"))
        #expect(!titles("pin t").contains("Pin thread"))
        chats[1].title = "Renamed since"
        await hop()
        #expect(titles("renamed").first == "Renamed since")
        // A second change is heard of as the first was.
        chats[1].title = "Renamed twice"
        await hop()
        #expect(titles("renamed").first == "Renamed twice")
    }

    /// A turn ending behind it, and a model starred from the models page beside it.
    @Test func stopGivesWayAndAStarIsSeenWithNoLetter() async throws {
        let stars = model.favoriteModels
        defer {
            model.favoriteModels = stars
            forget()
        }
        let row = { (id: String) in
            self.model.paletteLines(for: PaletteState.Level(kind: .root, query: id == "thread.stop" ? "stop" : "star"), of: self.model.paletteReachKept())
                .compactMap { line -> PaletteItem? in
                    if case .item(let item, _) = line, item.id == id { return item }
                    return nil
                }.first
        }
        #expect(row("thread.stop")?.unavailable == "Nothing is running")
        let conversation = model.conversation(for: chats[0])
        conversation.userSent("Read the review")
        await hop()
        #expect(row("thread.stop") != nil)
        #expect(row("thread.stop")?.unavailable == nil)
        let body: JSON = ["event": "turn.done", "threadId": .string(chats[0].id.uuidString), "stopReason": "end_turn", "durationMs": 1000, "costUSD": 0, "waiting": 0]
        conversation.receive(EngineEvent(name: "turn.done", threadId: chats[0].id.uuidString, body: body))
        #expect(!conversation.running)
        await hop()
        #expect(row("thread.stop")?.unavailable == "Nothing is running")

        model.models = [ModelOption(id: "opus", name: "Opus", description: "", efforts: [], fast: true, defaultEffort: nil, ultra: false, ultraBlocked: nil, more: nil, needs: nil)]
        model.favoriteModels = []
        await hop()
        let name = try #require(row("model.star")?.title.dropFirst("Star ".count))
        #expect(row("model.star")?.title == "Star \(name)")
        let option = try #require(model.option(for: chats[0]))
        model.toggleFavorite(option.id)
        await hop()
        #expect(row("model.star")?.title == "Unstar \(name)")
    }

    /// Settings writes what seven rows read to UserDefaults, which Observation doesn't tell of.
    @Test func aSettingChangedBesideItIsRightOnTheNextLetter() async throws {
        let standard = UserDefaults.standard
        let keys = [TranscriptSettings.showTime, TranscriptSettings.showCost, "notify", NewThreads.workspace]
        let before = keys.map { standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, before) { standard.set(value, forKey: key) }
            forget()
        }
        let titles = { (query: String) in
            self.model.paletteLines(for: PaletteState.Level(kind: .root, query: query), of: self.model.paletteReachKept()).compactMap { line -> String? in
                if case .item(let item, _) = line { return item.title }
                return nil
            }
        }
        standard.set(false, forKey: TranscriptSettings.showTime)
        standard.set(false, forKey: TranscriptSettings.showCost)
        standard.set(true, forKey: "notify")
        standard.removeObject(forKey: NewThreads.workspace)
        #expect(titles("turn times").contains("Show turn times"))
        let turn = model.paletteTurn
        standard.set(true, forKey: TranscriptSettings.showTime)
        await hop()
        #expect(model.paletteTurn == turn + 1)
        #expect(titles("turn times").contains("Hide turn times"))
        standard.set(true, forKey: TranscriptSettings.showCost)
        standard.set(false, forKey: "notify")
        standard.set(NewThreads.worktree, forKey: NewThreads.workspace)
        await hop()
        #expect(titles("turn cost").contains("Hide turn cost"))
        #expect(titles("notifications").contains("Notifications on"))
        #expect(titles("thread in the project").contains("New thread in the project's folder"))
        // A key the list doesn't read leaves it as it was.
        let kept = model.paletteTurn
        standard.set(UUID().uuidString, forKey: "PaletteTypedTests.other")
        await hop()
        standard.removeObject(forKey: "PaletteTypedTests.other")
        #expect(model.paletteTurn == kept)
    }

    @Test func theKeptRowsGoWhenItCloses() {
        defer { forget() }
        model.toggleCommandCenter()
        _ = model.paletteReachKept()
        #expect(model.paletteKept != nil)
        model.closeCommandCenter()
        #expect(model.paletteKept == nil)
    }

    @Test func aLevelDownRanksItsOwnRows() {
        defer { forget() }
        let list = PaletteList(title: "Branch", placeholder: "Search branches", items: { [] },
                               typed: { name in PaletteItem(id: "new", kind: .choice, title: "Create branch “\(name)”", action: .run {}) })
        var level = PaletteState.Level(kind: .list(list), query: "ma")
        level.items = ["main", "release", "next"].map { PaletteItem(id: $0, kind: .choice, title: $0, action: .run {}) }
        let rows = read(model.paletteLines(for: level, of: model.paletteReachKept()))
        #expect(rows.map { $0.split(separator: " | ")[1] } == ["main", "new"])
        #expect(model.paletteKept == nil)
        let input = PaletteState.Level(kind: .input(PaletteInput(title: "Rename", placeholder: "Name", submit: { _ in nil })), query: "x")
        #expect(model.paletteLines(for: input, of: model.paletteReachKept()).isEmpty)
    }

    @Test func theDrawersThreadsAreTheSameInNoOrder() {
        defer { forget() }
        #expect(Set(model.listedChats.map(\.id)) == Set(model.chats.map(\.id)))
        chats[2].archived = true
        model.drawerFilter = .archived
        #expect(model.listedChats.map(\.id) == model.chats.map(\.id))
        model.drawerFilter = .project(project.id)
        #expect(Set(model.listedChats.map(\.id)) == Set(model.chats.map(\.id)))
        #expect(model.chats.map(\.id) == [chats[0].id, chats[1].id])
    }

    @Test func aMessagesLineIsTheSameReadNearItsMatch() {
        defer { forget() }
        let filler = String(repeating: "The capsule sits in the toolbar's row, level with the traffic lights. ", count: 30)
        let gap = String(repeating: " \n\t", count: 150)
        let texts = [
            "Short and whole, the review fits.",
            filler + "Then the review of the git read begins, and İstanbul'da şişe kırıldı." + filler,
            "The review opens it. " + filler,
            filler + "It ends on the review",
            filler + gap + "the review after a long gap" + gap + filler,
            "review" + gap + filler,
            filler + "a café by the révìew, naïve and 👩‍👩‍👧 glad" + filler + " git",
            filler + "I\u{307}stanbul'da bir review" + filler,
            String(repeating: "x", count: 300) + "review" + String(repeating: "y", count: 300),
            filler.replacingOccurrences(of: " ", with: "\n") + "review git review" + filler,
        ]
        let queries = [["review"], ["git", "review"], ["review", "git"], ["rev", "review"], ["istanbul"], ["kirildi", "sise"], ["capsule"], ["lights."],
                       ["cafe"], ["naive", "glad"], ["notch"], ["review", "notch"], ["x"], ["y", "review"], ["the"]]
        // A piece is read alone only while its line stays clear of where it was cut.
        #expect(MessageSearch.snippet(["review"], in: "and then the review of the git read begins once more for all of us here", piece: (true, true))
            == "…then the review of the git read…")
        #expect(MessageSearch.snippet(["review"], in: "the review is near the cut and a long way from the other end of it", piece: (true, false)) == nil)
        #expect(MessageSearch.snippet(["review"], in: "a long way from the one end of it and near the cut is the review", piece: (false, true)) == nil)
        for text in texts {
            let said = MessageIndex.Said(id: UUID(), chat: UUID(), user: false, text: text)
            for words in queries {
                #expect(MessageSearch.snippet(words, in: said.text, folded: said.folded) == MessageSearch.snippet(words, in: text), "\(words) in \(text.prefix(40))")
            }
        }
    }
}
