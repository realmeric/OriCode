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

    @Test func thePullRequestsLineSaysWhereItsChecksHaveGot() {
        #expect(pull([]).words == "no checks")
        #expect(pull(["pass", "pass", "skipped"]).words == "all 2 checks passed")
        #expect(pull(["pass"]).words == "its check passed")
        #expect(pull(["pass", "pending", "pending"]).words == "1 of 3 checks passed, 2 running")
        #expect(pull(["pass", "fail"]).words == "check 2 failed")
        #expect(pull(["fail", "fail", "pending"]).words == "0 of 3 checks passed, 2 checks failed, 1 running")
        #expect(pull(["pass"], state: "MERGED").words == "merged")
    }

    @Test func aReadingIsKeptAndWatchedOnlyWhileChecksRun() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = AppModel(container: container)
        model.took(pull(["pending"]), in: "/tmp/alpha", for: nil)
        #expect(model.pulls["/tmp/alpha"]?.pending == 1)
        #expect(model.pullWatches["/tmp/alpha"] != nil)
        model.took(pull(["pass"]), in: "/tmp/alpha", for: nil)
        #expect(model.pulls["/tmp/alpha"]?.words == "its check passed")
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
