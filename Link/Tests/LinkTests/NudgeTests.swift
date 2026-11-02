import Foundation
import Testing
@testable import Link

struct NudgeTests {
    let thread = UUID()
    let project = ProjectInfo(id: UUID(), name: "OriCode", initials: "OE", color: 1, starts: true, order: 0)

    @Test func aBoxFromAnOlderMacStillOpens() throws {
        let box = Data(#"{"kind":"permission","title":"Fix it","body":"swift test","thread":"\#(thread.uuidString)","options":[]}"#.utf8)
        let nudge = try JSONDecoder().decode(NudgeInfo.self, from: box)
        #expect(nudge.kind == .permission)
        #expect(nudge.project == nil)
        #expect(nudge.subtitle == "Needs your permission")
    }

    @Test func theWordsSayTheProjectAndWhatItWants() {
        let run = NudgeInfo(kind: .run, title: "Fix it", body: "swift test", thread: thread, ask: "a", options: [], project: project)
        #expect(run.subtitle == "OriCode · Run a command")
        var loose = project
        loose.color = nil
        loose.name = "No folder"
        #expect(NudgeInfo(kind: .failed, title: "Fix it", body: "", thread: thread, ask: nil, options: [], project: loose).subtitle == "Failed")
    }

    @Test func aRepliesOpeningIsItsFirstLinesInPlainWords() {
        let reply = "## Done\n\nThe **store** tests pass, `swift test` is green.\n\n- one\n- two\n- three"
        #expect(NudgeInfo.opening(of: reply) == "Done\nThe store tests pass, swift test is green.\n- one")
        #expect(NudgeInfo.opening(of: "") == "")
    }

    @Test func aTurnsEndBuzzesWhoItShould() {
        #expect(NudgeInfo.endBuzzes(wrote: true, opened: true, nudging: false))
        #expect(NudgeInfo.endBuzzes(wrote: true, opened: false, nudging: false))
        #expect(NudgeInfo.endBuzzes(wrote: false, opened: false, nudging: true))
        #expect(!NudgeInfo.endBuzzes(wrote: false, opened: false, nudging: false))
        #expect(!NudgeInfo.endBuzzes(wrote: false, opened: true, nudging: true))
    }

    @Test func aTapBeforeTheRecordStillHasATitle() {
        let nudge = NudgeInfo(kind: .reply, title: "Fix it", body: "Done", thread: thread, ask: nil, options: [], project: project, agent: "claude")
        let shown = nudge.standIn
        #expect(shown.id == thread)
        #expect(shown.title == "Fix it")
        #expect(shown.project == project.id)
        #expect(shown.status == .idle)
        #expect(shown.reply == "Done")
        #expect(NudgeInfo(kind: .run, title: "Fix it", body: "ls", thread: thread, ask: "a", options: []).standIn.status == .asking)
    }
}
