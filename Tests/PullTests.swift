import Foundation
import SwiftData
import Testing
@testable import OriCode

@MainActor
struct PullTests {
    private func pull(_ states: [String], state: String = "OPEN") -> PullRequest {
        PullRequest(number: 12, title: "Fix the drawer", url: "https://github.com/o/r/pull/12", state: state,
                    checks: states.enumerated().map { PullCheck(name: "check \($0.offset + 1)", state: $0.element, link: nil) })
    }

    @Test func thePullRequestsLineSaysTheOneThingWorthKnowing() {
        #expect(pull([]).words == "no checks")
        #expect(pull(["pass", "pass", "skipped"]).words == "ready to merge")
        #expect(pull(["pending", "pending"]).words == "2 checks running")
        #expect(pull(["pass", "pending", "pending"]).words == "1 of 3 checks passed")
        #expect(pull(["pass", "fail"]).words == "check 2 failed")
        #expect(pull(["fail", "fail", "pending"]).words == "2 checks failed")
        #expect(pull(["pass"], state: "MERGED").words == "merged")
        var conflicted = pull(["pass"])
        conflicted.mergeable = "CONFLICTING"
        conflicted.base = "main"
        #expect(conflicted.words == "conflicts with main" && conflicted.troubled)
        #expect(conflicted.blocked == "It conflicts with main")
        #expect(pull(["pass"]).blocked == nil && !pull(["pass"]).troubled)
        #expect(pull(["pending"]).blocked == "A check is still running")
        var draft = pull(["pass"])
        draft.draft = true
        #expect(draft.words == "draft" && draft.blocked == "It's a draft")
    }

    @Test func aCheckSaysHowItWent() {
        #expect(PullCheck(name: "CI / test", state: "fail", link: nil, seconds: 64).outcome == "failed after 1m 4s")
        #expect(PullCheck(name: "CI / lint", state: "pass", link: nil, seconds: 6).outcome == "passed in 6s")
        #expect(PullCheck(name: "CI / lint", state: "pending", link: nil).outcome == "running")
        #expect(PullCheck(name: "CI / test", state: "fail", link: nil).short == "test")
        let decoded = try? JSONDecoder().decode(PullRequest.self, from: Data(#"{"number":1,"title":"t","url":"u","state":"OPEN","checks":[{"name":"a","state":"pass","link":null}]}"#.utf8))
        #expect(decoded?.mergeable == "UNKNOWN" && decoded?.checks.first?.seconds == nil)
    }

    @Test func aReadingIsKeptAndWatchedOnlyWhileChecksRun() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = AppModel(container: container)
        model.took(pull(["pending"]), in: "/tmp/alpha", for: nil)
        #expect(model.pulls["/tmp/alpha"]?.pending == 1)
        #expect(model.pullWatches["/tmp/alpha"] != nil)
        model.took(pull(["pass"]), in: "/tmp/alpha", for: nil)
        #expect(model.pulls["/tmp/alpha"]?.words == "ready to merge")
        #expect(model.pullWatches["/tmp/alpha"] == nil)
        // Open with no checks listed yet: looked at again three times, and then left alone.
        for _ in 0..<3 {
            model.took(pull([]), in: "/tmp/alpha", for: nil)
            #expect(model.pullWatches["/tmp/alpha"] != nil)
        }
        model.took(pull([]), in: "/tmp/alpha", for: nil)
        #expect(model.pullWatches["/tmp/alpha"] == nil)
        model.pushedMaybe(in: "/tmp/alpha")
        model.took(pull([]), in: "/tmp/alpha", for: nil)
        #expect(model.pullWatches["/tmp/alpha"] != nil)
        model.took(nil, in: "/tmp/alpha", for: nil)
        #expect(model.pulls["/tmp/alpha"] == nil)
    }
}
