import SwiftData
@testable import OriCode

/// A store in memory for a test, with autosave off. SwiftData saves a main context fifteen
/// seconds after a change, by which time the test that made the change is over and its store
/// let go, and a main context that comes to save with its container gone ends the test host
/// there, under whatever test is running by then. A test that wants its changes stored saves
/// them, as the app does.
@MainActor
enum TestStore {
    static func memory() throws -> ModelContainer {
        let container = try ModelContainer(for: Project.self, Chat.self, Event.self, PlanTask.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        return container
    }
}
