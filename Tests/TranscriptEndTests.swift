import Foundation
import SwiftData
import Testing
@testable import OriCode

struct TranscriptEndTests {
    @Test func theDistanceIsWhatLiesUnderTheView() {
        #expect(TranscriptEnd.distance(offset: 0, visible: 600, content: 9000) == 8400)
        #expect(TranscriptEnd.distance(offset: 8400, visible: 600, content: 9000) == 0)
        // A thread shorter than the window, and a bounce past the end, are at the end.
        #expect(TranscriptEnd.distance(offset: 0, visible: 600, content: 200) == 0)
        #expect(TranscriptEnd.distance(offset: 8430, visible: 600, content: 9000) == 0)
    }

    @Test func theEndIsReachedWithinItsReach() {
        #expect(TranscriptEnd.place(offset: 8400, visible: 600, content: 9000) == .end)
        #expect(TranscriptEnd.place(offset: 8352, visible: 600, content: 9000) == .end)
        #expect(TranscriptEnd.place(offset: 8351, visible: 600, content: 9000) == .near)
        // A thread that doesn't fill the window is all end.
        #expect(TranscriptEnd.place(offset: 0, visible: 600, content: 200) == .end)
    }

    @Test func nearIsWithinTwoHeightsOfTheView() {
        #expect(TranscriptEnd.place(offset: 8100, visible: 600, content: 9000) == .near)
        #expect(TranscriptEnd.place(offset: 7200, visible: 600, content: 9000) == .near)
        #expect(TranscriptEnd.place(offset: 7199, visible: 600, content: 9000) == .away)
        #expect(TranscriptEnd.place(offset: 0, visible: 600, content: 9000) == .away)
    }

    @Test func aViewWithNoHeightYetIsAtTheEndOrAway() {
        #expect(TranscriptEnd.place(offset: 0, visible: 0, content: 48) == .end)
        #expect(TranscriptEnd.place(offset: 0, visible: 0, content: 49) == .away)
    }

    @Test func theEndIsTheEndOnlyWithItsRowLaidOut() {
        #expect(TranscriptEnd.place(.end, endLaidOut: true) == .end)
        // The numbers of a stretch the lazy stack hasn't laid out: a sent message still follows.
        #expect(TranscriptEnd.place(.end, endLaidOut: false) == .near)
        #expect(TranscriptEnd.follows(from: TranscriptEnd.place(.end, endLaidOut: false)))
        // Further up, the row coming and going says nothing.
        #expect(TranscriptEnd.place(.near, endLaidOut: true) == .near)
        #expect(TranscriptEnd.place(.away, endLaidOut: true) == .away)
        #expect(TranscriptEnd.place(.away, endLaidOut: false) == .away)
    }

    @Test func aMessageSentByHandFollowsFromTheEndAndFromNearIt() {
        #expect(TranscriptEnd.follows(from: .end))
        #expect(TranscriptEnd.follows(from: .near))
    }

    @Test func sentFromFurtherUpItLeavesWhatIsBeingRead() {
        #expect(!TranscriptEnd.follows(from: .away))
        // A full screen up, and a thread's length up.
        #expect(!TranscriptEnd.follows(from: TranscriptEnd.place(offset: 7100, visible: 600, content: 9000)))
        #expect(!TranscriptEnd.follows(from: TranscriptEnd.place(offset: 0, visible: 600, content: 9000)))
    }

    @Test func thePillIsOfferedOnlyAwayFromTheEnd() {
        #expect(!TranscriptEnd.offered(pinned: true, covered: false))
        #expect(TranscriptEnd.offered(pinned: false, covered: false))
    }

    @Test func aBlockOrAFileOpenOverTheTranscriptTakesThePillAway() {
        #expect(!TranscriptEnd.offered(pinned: false, covered: true))
        #expect(!TranscriptEnd.offered(pinned: true, covered: true))
    }

    /// A transcript the hand has scrolled to a place.
    private func standing(at place: TranscriptEnd.Place) -> TranscriptEnd.Standing {
        var standing = TranscriptEnd.Standing()
        standing.moved(to: place)
        return standing
    }

    @Test func aTranscriptStartsAtItsEndWithNoPill() {
        let standing = TranscriptEnd.Standing()
        #expect(standing.pinned)
        #expect(!standing.news)
        #expect(!TranscriptEnd.offered(pinned: standing.pinned, covered: false))
    }

    @Test func aNewTranscriptThatNeverLaidOutItsEndIsAdrift() {
        #expect(TranscriptEnd.Standing().adrift(endSeen: false))
        #expect(!TranscriptEnd.Standing().adrift(endSeen: true))
        // A reveal on appear leaves the end unmade on purpose.
        var revealed = TranscriptEnd.Standing()
        revealed.revealing()
        #expect(!revealed.adrift(endSeen: false))
        // Scrolled away by hand, or already on the way, it's left alone.
        #expect(!standing(at: .near).adrift(endSeen: false))
        #expect(!standing(at: .away).adrift(endSeen: false))
        var heading = TranscriptEnd.Standing()
        _ = heading.jump()
        #expect(!heading.adrift(endSeen: false))
        // Landed at the foot by its numbers with the end's row still unmade, it is again.
        heading.landed()
        #expect(heading.adrift(endSeen: false))
    }

    @Test func scrolledFromTheEndThePillComesAndGoesWithIt() {
        var standing = standing(at: .near)
        #expect(!standing.pinned)
        standing.moved(to: .away)
        #expect(!standing.pinned)
        standing.moved(to: .end)
        #expect(standing.pinned)
    }

    @Test func growthOutOfViewIsNews() {
        var standing = standing(at: .away)
        #expect(!standing.news)
        standing.grew(laidOut: true)
        #expect(standing.news)
    }

    @Test func growthAtTheEndIsNot() {
        var standing = TranscriptEnd.Standing()
        standing.grew(laidOut: true)
        #expect(!standing.news)
    }

    @Test func growthThatIsNotLaidOutIsNot() {
        var standing = standing(at: .away)
        standing.grew(laidOut: false)
        #expect(!standing.news)
    }

    @Test func newsStaysUntilTheEndIsReached() {
        var standing = standing(at: .away)
        standing.grew(laidOut: true)
        standing.moved(to: .near)
        #expect(standing.news)
        standing.grew(laidOut: false)
        #expect(standing.news)
        standing.moved(to: .end)
        #expect(!standing.news)
        #expect(standing.pinned)
        // And it isn't back on the way up again.
        standing.moved(to: .near)
        #expect(!standing.news)
    }

    @Test func aRevealThatLandsAtTheEndLeavesNoPill() {
        // An item in the last screenful, or a thread shorter than the window: the scroll view's
        // place is the end before and after, so it says nothing.
        var standing = TranscriptEnd.Standing()
        standing.revealing()
        #expect(!standing.pinned)
        standing.settled()
        #expect(standing.pinned)
        #expect(!TranscriptEnd.offered(pinned: standing.pinned, covered: false))
    }

    @Test func aRevealThatLandsAtTheEndFromFurtherUpClearsTheNews() {
        var standing = standing(at: .away)
        standing.grew(laidOut: true)
        standing.revealing()
        standing.moved(to: .end)
        standing.settled()
        #expect(standing.pinned)
        #expect(!standing.news)
    }

    @Test func aRevealFurtherUpLeavesThePill() {
        var standing = TranscriptEnd.Standing()
        standing.revealing()
        standing.moved(to: .away)
        standing.settled()
        #expect(!standing.pinned)
        // What grows while the revealed item is read is news.
        standing.grew(laidOut: true)
        #expect(standing.news)
    }

    @Test func aJumpFromAwayKeepsTheEndThroughNear() {
        var standing = standing(at: .away)
        standing.grew(laidOut: true)
        // Further than a screen away, what's around the end isn't laid out yet.
        let laidOut = standing.jump()
        #expect(!laidOut)
        #expect(standing.pinned)
        #expect(!standing.news)
        // Past where the end was thought to be, short of where it is.
        standing.moved(to: .near)
        #expect(standing.pinned)
        // A reply growing on the way is followed, and is no news.
        standing.grew(laidOut: true)
        #expect(!standing.news)
        standing.moved(to: .end)
        standing.landed()
        #expect(standing.pinned)
        #expect(!standing.heading)
    }

    @Test func aJumpFromNearFindsTheEndLaidOut() {
        var standing = standing(at: .near)
        let fromNear = standing.jump()
        #expect(fromNear)
        var atEnd = TranscriptEnd.Standing()
        let fromEnd = atEnd.jump()
        #expect(fromEnd)
    }

    @Test func aJumpAHandTookOverBringsThePillBack() {
        var standing = standing(at: .away)
        _ = standing.jump()
        standing.moved(to: .near)
        standing.landed()
        #expect(!standing.pinned)
        // And the scroll view's word counts again.
        standing.moved(to: .end)
        standing.moved(to: .near)
        #expect(!standing.pinned)
    }

    @Test func aRevealCallsOffAJump() {
        var standing = standing(at: .away)
        _ = standing.jump()
        standing.revealing()
        #expect(!standing.pinned)
        standing.moved(to: .near)
        #expect(!standing.pinned)
    }

    @Test func aRevealSettlingDuringAJumpLeavesTheJumpItsHold() {
        var standing = standing(at: .away)
        standing.revealing()
        _ = standing.jump()
        standing.settled()
        #expect(standing.pinned)
    }

    @Test func aMessageSentByHandFollowsFromWhereTheTranscriptStands() {
        #expect(TranscriptEnd.Standing().sent())
        #expect(standing(at: .near).sent())
        // From further up it stays, and the message that arrives is news.
        var away = standing(at: .away)
        #expect(!away.sent())
        away.grew(laidOut: true)
        #expect(away.news)
    }

    @Test func theThreadGrowsWhenItsLastRowIsANewOne() {
        let first = UUID(), second = UUID()
        let tail = TranscriptEnd.Tail(count: 4, last: first)
        #expect(TranscriptEnd.Tail(count: 5, last: second).grew(from: tail))
        #expect(TranscriptEnd.Tail(count: 1, last: first).grew(from: TranscriptEnd.Tail(count: 0, last: nil)))
        // Thinking that's left out, a plan's call, or a call folded into the run above it.
        #expect(!TranscriptEnd.Tail(count: 5, last: first).grew(from: tail))
        // Earlier items shown or thinking turned on, and a waiting message handed back.
        #expect(!TranscriptEnd.Tail(count: 4, last: second).grew(from: tail))
        #expect(!TranscriptEnd.Tail(count: 3, last: second).grew(from: tail))
    }

    @Test func hiddenThinkingAndAPlansCallAddNoRow() {
        let said = Item.text(id: UUID(), text: "Done.")
        let thought = Item.thinking(id: UUID(), text: "Hm.")
        func tail(_ items: [Item], thinking: Bool) -> TranscriptEnd.Tail {
            TranscriptEnd.Tail(count: items.count, last: TranscriptEntry.fold(items, thinking: thinking).last?.id)
        }
        #expect(!tail([said, thought], thinking: false).grew(from: tail([said], thinking: false)))
        #expect(tail([said, thought], thinking: true).grew(from: tail([said], thinking: true)))
        // The stream is into a row only when its item is in one.
        #expect(!TranscriptEntry.fold([said, thought], thinking: false).contains { $0.holds(thought.id) })
        #expect(TranscriptEntry.fold([said, thought], thinking: true).contains { $0.holds(thought.id) })
    }

    @MainActor
    @Test func theCommandCenterHasTheWayToTheEnd() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: NSTemporaryDirectory())
        container.mainContext.insert(project)
        // After the model, whose launch clears threads that never started.
        let model = AppModel(container: container)
        let chat = Chat(project: project)
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        // A thread nothing was sent in has no end to go to.
        model.runPaletteCommand("thread.end")
        #expect(model.threadEnd == 0)
        chat.started = true
        model.runPaletteCommand("thread.end")
        #expect(model.threadEnd == 1)
    }
}
