import Foundation
import Testing
@testable import OriCode

/// Starting the engine, with a node that's never found, so nothing starts.
struct EngineTests {
    private actor Searches {
        var count = 0
        func add() { count += 1 }
    }

    @Test func twoStartsAtOnceLookForOneEngine() async {
        let searches = Searches()
        let engine = Engine(findNode: { _ in
            await searches.add()
            try await Task.sleep(for: .milliseconds(100))
            throw NodeLocator.NotFound(message: "No node here.")
        })
        async let first: Void = engine.start(nodeOverride: nil)
        async let second: Void = engine.start(nodeOverride: nil)
        var failed = 0
        do { try await first } catch { failed += 1 }
        do { try await second } catch { failed += 1 }
        #expect(await searches.count == 1)
        // Both hear how the one start went.
        #expect(failed == 2)

        // Once it's over, the next start is a start of its own.
        try? await engine.start(nodeOverride: nil)
        #expect(await searches.count == 2)
    }
}
