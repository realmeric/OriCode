import Foundation
import SwiftData
import Testing
@testable import OriCode

@MainActor
struct ProjectsTests {
    @Test func aFolderWithoutGitIsAProject() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = AppModel(container: container)
        let folder = FileManager.default.temporaryDirectory.appending(path: "oricode-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        model.addProject(at: folder)

        #expect(model.projects.map(\.path) == [folder.standardizedFileURL.path])
        #expect(model.project?.name == folder.lastPathComponent)
        model.addProject(at: folder)
        #expect(model.projects.count == 1)
    }
}
