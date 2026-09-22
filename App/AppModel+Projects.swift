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

    var chats: [Chat] {
        (project?.chats ?? []).sorted { $0.createdAt > $1.createdAt }
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
        context.insert(project)
        save()
        select(project)
    }

    func select(_ project: Project) {
        selectedProjectID = project.id
        selectedChatID = project.chats.max { $0.updatedAt < $1.updatedAt }?.id
    }

    func select(_ chat: Chat) {
        selectedChatID = chat.id
    }

    @discardableResult
    func newChat() -> Chat? {
        guard let project else { return nil }
        let chat = Chat(project: project, permissionMode: lastPermissionMode)
        chat.model = lastModel
        chat.effort = lastEffort
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
        let wasSelected = chat.id == selectedChatID
        let id = chat.id.uuidString
        Task { _ = try? await engine.request("close", ["threadId": .string(id)]) }
        context.delete(chat)
        save()
        if wasSelected { selectedChatID = chats.first?.id }
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
