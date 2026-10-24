import Foundation
import SwiftUI
import Testing
@testable import OriCode

struct HandoffTests {
    /// What a reviewer returned and the task the script then gave the agent that checks it, as a
    /// real run (wf_9de18c5a, 2026-10-20) recorded them: the result printed again with spaces.
    private let result = #"""
        {"findings":[{"file":"App/TranscriptView.swift","line":112,"severity":"medium","problem":"For one second after the press, the kept row's frame reader moves the scroll back every time the row's frame changes. The only thing that lets go early is onScrollPhaseChange seeing .tracking or .interacting (line 170). On macOS a legacy mouse wheel (not a trackpad, not Magic Mouse) sends wheel events with no gesture phase. NSScrollView starts no live scroll for those, so the scroll phase likely never leaves .idle, though I haven't confirmed that. Scenario: a wheel-mouse user presses Show earlier and at once scrolls up to read the items that just came in, which is the obvious next move. Each tick moves the row, the action fires, scroll(for:) sees that the scroll differs from `from` and the row is on screen away from `under`, and position.scrollTo(y:) puts it back. The wheel seems dead for up to a second. The card's live check scrolled only before the press, so nothing ran a hand scroll inside the window.","fix":"In the frame reader's action, before scrolling, check `position.isPositionedByUser`. The press's own scrollTo(id:) clears it and any user scroll sets it, whatever the input device. If it is set, clear `kept` and don't scroll. Keep the phase check alongside it."}]}
        """#
    private let task = #"""
        You are working in /Users/merickucukmeric/Developer/OriCode on main. No other agent of this workflow edits the tree while you run, but another OriCode thread of Meriç's may commit to main: stage only your own files and git pull --rebase before pushing. Follow CLAUDE.md and KANBAN.md's "How to work this board". Commit messages carry NO Co-Authored-By or any AI trailer: Meriç's global rule overrides any default. Prose for the board, Linear, CHANGELOG, README or commits follows the meric-writing skill (load it with the Skill tool). Engine commands need PATH=/opt/homebrew/bin:$PATH. Linear tools load with ToolSearch.

        Testing, Meriç's word on 2026-10-20: earlier cards tested far more than needed. Test what the change can break and no more. One make test at the end, not several. A unit test for the behaviour the card adds. A live check in the test host only for a Done when line no unit test can show, done once, with real agent turns only if the line is about an agent. make perf-quick before and after only if the card touches a path rule 6 names (typing, scrolling a transcript, a streaming turn, launch). No frame sweeps beyond the one or two widths the change affects.

        Land card K-300 (Linear REA-242), commit 6718dac, unpushed. Check these findings yourself, fix the real ones, reject the rest with a reason:
        [
         {
          "file": "App/TranscriptView.swift",
          "line": 112,
          "severity": "medium",
          "problem": "For one second after the press, the kept row's frame reader moves the scroll back every time the row's frame changes. The only thing that lets go early is onScrollPhaseChange seeing .tracking or .interacting (line 170). On macOS a legacy mouse wheel (not a trackpad, not Magic Mouse) sends wheel events with no gesture phase. NSScrollView starts no live scroll for those, so the scroll phase likely never leaves .idle, though I haven't confirmed that. Scenario: a wheel-mouse user presses Show earlier and at once scrolls up to read the items that just came in, which is the obvious next move. Each tick moves the row, the action fires, scroll(for:) sees that the scroll differs from `from` and the row is on screen away from `under`, and position.scrollTo(y:) puts it back. The wheel seems dead for up to a second. The card's live check scrolled only before the press, so nothing ran a hand scroll inside the window.",
          "fix": "In the frame reader's action, before scrolling, check `position.isPositionedByUser`. The press's own scrollTo(id:) clears it and any user scroll sets it, whatever the input device. If it is set, clear `kept` and don't scroll. Keep the phase check alongside it."
         }
        ]
        make test once; amend the card commit keeping its subject; put the final hash on the board; git pull --rebase; git push origin main; run ~/Library/Developer/OriCode.noindex/scratch/harness/board.sh "K-300"; move REA-242 to Done in Linear.
        """#

    @Test func aTaskFindsTheRunsItTookFromALongResult() {
        #expect(result.count > 400)
        let runs = Handoff.runs(task: task, result: result)
        let taken = runs.task.map { String(task[$0]) }
        // Past the 400 characters the snapshot keeps, the finding's last sentences are found whole.
        #expect(taken.contains { $0.contains("If it is set, clear `kept` and don't scroll. Keep the phase check alongside it.") })
        #expect(taken.contains { $0.contains("For one second after the press") })
        #expect(runs.result.contains { result.distance(from: result.startIndex, to: $0.upperBound) > 400 })
        // Nothing shorter than 24 characters, and the preamble the script wrote itself isn't taken.
        #expect(taken.allSatisfy { $0.count >= Handoff.least })
        #expect(!taken.contains { $0.contains("How to work this board") })
    }

    @Test func aTaskThatSharesNothingDrawsNoHop() {
        #expect(Handoff.runs(task: "Run make test and say what failed.", result: result).isEmpty)
        // A run under 24 characters, or one starting inside a word, isn't a handoff.
        #expect(Handoff.runs(task: "the scroll phase likely", result: result).isEmpty)
        #expect(Handoff.runs(task: "xcroll phase likely never leaves", result: "scroll phase likely never leaves").task.map { "xcroll phase likely never leaves"[$0] } == ["phase likely never leaves"])
    }

    @Test func theWellStartsAtTheFirstRunAndLightsIt() {
        let runs = Handoff.runs(task: task, result: result)
        let well = Handoff.well(task, runs: runs.task)
        let text = String(well.characters)
        #expect(text.hasPrefix("…"))
        #expect(text.prefix(300).contains("For one second after the press"))
        let lit = well.runs.filter { $0.foregroundColor == Ink.primary }.map { String(well[$0.range].characters) }
        #expect(lit.contains { $0.contains("For one second after the press") })
    }

    @Test func aSourceLineShownWithoutItsMarkdownDimsWhole() {
        let task = "Fix these:\nRisk: `Cache.invalidate` at Sources/Store/Cache.swift:3 mutates `entries` without any synchronization."
        let line = "Risk: Cache.invalidate at Sources/Store/Cache.swift:3 mutates entries without any synchronization."
        let shown = Handoff.source(line, task: task)
        #expect(shown.runs.allSatisfy { $0.foregroundColor == Color.white.opacity(0.34) })
    }

    @Test func anAgentsTaskOpensWholeWithWhatItTookInInk() {
        let runs = Handoff.runs(task: task, result: result)
        let well = Handoff.task(task + "\n\n", runs: runs.task)
        // From its first word to its last, the preamble too, with nothing after it.
        #expect(String(well.characters).hasPrefix("You are working in") && String(well.characters).hasSuffix("move REA-242 to Done in Linear."))
        let inked = well.runs.filter { $0.foregroundColor == Ink.primary }.map { String(well[$0.range].characters) }
        #expect(inked.contains { $0.contains("For one second after the press") })
        #expect(!inked.contains { $0.contains("How to work this board") })
    }
}
