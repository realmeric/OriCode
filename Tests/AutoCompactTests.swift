import Foundation
import SwiftData
import Testing
@testable import OriCode

/// K-387: Settings' threshold reaches the engine with a Claude thread's send, and no other agent's.
@MainActor
@Suite(.serialized)
struct AutoCompactTests {
    @Test func theThresholdGoesWithAClaudeSendOnly() throws {
        let container = try TestStore.memory()
        let model = AppModel(container: container)
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        let claude = Chat(project: project)
        let codex = Chat(project: project)
        codex.provider = "codex"
        container.mainContext.insert(claude)
        container.mainContext.insert(codex)
        let defaults = UserDefaults.standard
        let kept = defaults.object(forKey: AutoCompact.key)
        defer { defaults.set(kept, forKey: AutoCompact.key) }

        defaults.removeObject(forKey: AutoCompact.key)
        #expect(model.sendParams(in: claude, text: "hi", images: [])["compactAt"] == .number(200_000))
        #expect(model.sendParams(in: codex, text: "hi", images: [])["compactAt"] == nil)
        defaults.set(400_000, forKey: AutoCompact.key)
        #expect(model.sendParams(in: claude, text: "hi", images: [])["compactAt"] == .number(400_000))
        defaults.set(0, forKey: AutoCompact.key)
        #expect(model.sendParams(in: claude, text: "hi", images: [])["compactAt"] == nil)
    }
}
