import AppKit
import Foundation
import SwiftData

extension AppModel {
    var projects: [Project] {
        _ = revision
        return (try? context.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    var project: Project? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    /// Every project's threads in one list, newest first: the drawer, ⌘1–9 and the Thread menu.
    var chats: [Chat] {
        projects.flatMap(\.chats).sorted { $0.createdAt > $1.createdAt }
    }

    var chat: Chat? {
        guard let selectedChatID else { return nil }
        return project?.chats.first { $0.id == selectedChatID }
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(at: url)
    }

    func addProject(at url: URL) {
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: url.appending(path: ".git").path) else {
            say("\(url.lastPathComponent) isn't a git repository, so OriCode can't show what Claude changes there.")
            return
        }
        if let existing = projects.first(where: { $0.path == path }) {
            select(existing)
            return
        }
        let project = Project(name: url.lastPathComponent, path: path)
        project.colorIndex = ProjectColor.pick(taken: projects.compactMap(\.colorIndex))
        context.insert(project)
        save()
        select(project)
    }

    func select(_ project: Project) {
        selectedProjectID = project.id
        selectedChatID = project.chats.max { $0.updatedAt < $1.updatedAt }?.id
    }

    /// Picking a thread picks its project, since the list holds every project's threads.
    func select(_ chat: Chat) {
        if let project = chat.project { selectedProjectID = project.id }
        selectedChatID = chat.id
    }

    /// Projects from before badges had colours get theirs the first time the app opens.
    func colourProjects() {
        let uncoloured = projects.filter { $0.colorIndex == nil }
        guard !uncoloured.isEmpty else { return }
        for project in uncoloured {
            project.colorIndex = ProjectColor.pick(taken: projects.compactMap(\.colorIndex))
        }
        save()
    }

    @discardableResult
    func newChat() -> Chat? {
        guard let project else { return nil }
        let chat = Chat(project: project, permissionMode: lastPermissionMode)
        chat.model = lastModel
        let efforts = models.first { $0.id == lastModel }?.efforts ?? []
        chat.effort = lastEffort.flatMap { efforts.contains($0) ? $0 : nil }
        context.insert(chat)
        save()
        selectedChatID = chat.id
        return chat
    }

    func rename(_ chat: Chat, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chat.title = trimmed
        chat.titleIsCustom = true
        save()
    }

    func delete(_ chat: Chat) {
        let deleted = chat.id
        let wasSelected = deleted == selectedChatID
        Task { _ = try? await engine.request("close", ["threadId": .string(deleted.uuidString)]) }
        context.delete(chat)
        save()
        guard wasSelected else { return }
        // The next thread in the same project if there is one, so deleting doesn't switch projects.
        let rest = chats.filter { $0.id != deleted }
        if let next = rest.first(where: { $0.project?.id == selectedProjectID }) ?? rest.first {
            select(next)
        } else {
            selectedChatID = nil
        }
    }

    func save() {
        touch()
        do {
            try context.save()
        } catch {
            Engine.logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
