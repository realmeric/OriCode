import AppKit
import SwiftUI

/// The editors ⌘K can open a project in, those of them installed, and the one Settings picked.
enum Editor {
    static let key = "editorBundleID"

    struct App: Hashable {
        let id: String
        let name: String
        let url: URL
    }

    private static let known = [
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("dev.zed.Zed", "Zed"),
        ("com.microsoft.VSCode", "Visual Studio Code"),
        ("com.apple.dt.Xcode", "Xcode"),
        ("com.sublimetext.4", "Sublime Text"),
        ("com.panic.Nova", "Nova"),
    ]

    static var installed: [App] {
        known.compactMap { id, name in NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { App(id: id, name: name, url: $0) } }
    }

    /// The one picked in Settings, or the first installed.
    static var chosen: App? {
        let apps = installed
        let saved = UserDefaults.standard.string(forKey: key)
        return apps.first { $0.id == saved } ?? apps.first
    }
}

/// The small things reached for all day: Finder, the editor, paths, a level up or down, the
/// transcript's footer, notifications, the engine, and taking a project out of the list.
extension AppModel {
    var qualityCommands: [PaletteItem] {
        let folder = workingFolder
        let noFolder: String? = folder == nil ? "Add a project first" : nil
        let editor = Editor.chosen
        let running = conversations.values.contains { $0.running }
        var items: [PaletteItem] = []

        items.append(command("project.reveal", "Reveal in Finder", icon: "folder", keywords: ["show", "finder"], unavailable: noFolder) {
            if let folder { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: folder)]) }
        })
        let editorName = editor?.name ?? "the editor"
        items.append(command("project.editor", "Open in \(editorName)", icon: "chevron.left.forwardslash.chevron.right",
                             keywords: ["editor", "cursor", "zed", "code", "xcode"],
                             unavailable: noFolder ?? (editor == nil ? "No editor installed that OriCode knows" : nil)) {
            if let folder, let editor { Self.open([URL(filePath: folder)], in: editor) }
        })
        if let file = openFile, let folder, let editor {
            let url = file.path.hasPrefix("/") ? URL(filePath: file.path) : URL(filePath: folder).appending(path: file.path)
            items.append(command("file.editor", "Open \(url.lastPathComponent) in \(editor.name)", icon: "doc.text", keywords: ["editor"]) {
                Self.open([url], in: editor)
            })
        }
        items.append(command("project.copyPath", "Copy project path", icon: "doc.on.clipboard", keywords: ["folder", "path"], unavailable: noFolder) { [weak self] in
            self?.copy(folder, saying: "Copied the path.")
        })

        if let option = option(for: chat), !option.levels.isEmpty {
            let at = option.levels.firstIndex(of: effectiveLevel ?? "") ?? -1
            items.append(command("effort.raise", "Raise effort", icon: "arrow.up", keywords: ["more", "harder", "thinking"],
                                 unavailable: at >= option.levels.count - 1 ? "Already at the highest level" : nil) { [weak self] in
                self?.stepEffort(1)
            })
            items.append(command("effort.lower", "Lower effort", icon: "arrow.down", keywords: ["less", "faster", "thinking"],
                                 unavailable: at <= 0 ? "Already at the lowest level" : nil) { [weak self] in
                self?.stepEffort(-1)
            })
        }

        let defaults = UserDefaults.standard
        let times = defaults.bool(forKey: TranscriptSettings.showTime)
        items.append(command("transcript.times", times ? "Hide turn times" : "Show turn times", icon: "clock", keywords: ["footer", "how long"]) {
            defaults.set(!times, forKey: TranscriptSettings.showTime)
        })
        let cost = defaults.bool(forKey: TranscriptSettings.showCost)
        items.append(command("transcript.cost", cost ? "Hide turn cost" : "Show turn cost", icon: "dollarsign.circle", keywords: ["footer", "price"]) {
            defaults.set(!cost, forKey: TranscriptSettings.showCost)
        })
        let notify = defaults.object(forKey: "notify") as? Bool ?? true
        items.append(command("notifications", notify ? "Notifications off" : "Notifications on", icon: notify ? "bell.slash" : "bell",
                             keywords: ["notify", "alerts"]) {
            defaults.set(!notify, forKey: "notify")
        })
        items.append(command("engine.restart", "Restart engine", icon: "arrow.clockwise.circle", keywords: ["node", "reload"],
                             unavailable: running ? "Wait for the running turns to end" : nil) { [weak self] in
            self?.restartEngine()
        })
        if let project {
            let busy = project.chats.contains { conversations[$0.id]?.running == true }
            items.append(command("project.remove", "Remove project…", icon: "folder.badge.minus", keywords: ["delete", "forget"],
                                 unavailable: busy ? "Wait for its threads to finish" : nil) { [weak self] in
                self?.removingProject = project
            })
        }
        return items
    }

    /// The level the open thread runs at: the one picked, or where Default lands.
    private var effectiveLevel: String? {
        let picked = chat == nil ? startingEffort : chat?.effort
        return picked ?? defaultLevel(for: chat)
    }

    /// One level up or down, the way a step on the rail goes: landing on Default's own level is
    /// Default.
    func stepEffort(_ by: Int) {
        guard let option = option(for: chat), let at = option.levels.firstIndex(of: effectiveLevel ?? "") else { return }
        let next = min(max(at + by, 0), option.levels.count - 1)
        guard next != at else { return }
        let level = option.levels[next]
        withAnimation(Motion.move) { setEffort(level == defaultLevel(for: chat) ? nil : level, for: chat) }
    }

    /// Ends the engine and starts it again, which ends every thread's CLI; each resumes its
    /// session on its next send.
    func restartEngine() {
        guard !conversations.values.contains(where: { $0.running }) else { return }
        Task {
            await engine.stop()
            await startEngine()
            say(engineState == .ready ? "The engine is back." : "The engine didn't start again.")
        }
    }

    /// Takes a project and its threads out of OriCode. Its folder stays, and so do any worktrees.
    func remove(_ project: Project) {
        // Its shells go with it: the project's own, and each worktree thread's.
        for folder in Set([project.path] + project.chats.map(\.cwd)) {
            terminals.end(folder: folder)
        }
        customActions.forget(project: project.id)
        for chat in project.chats {
            let id = chat.id.uuidString
            conversations[chat.id] = nil
            Task { _ = try? await engine.request("close", ["threadId": .string(id)]) }
        }
        let removed = project.id
        context.delete(project)
        save()
        guard selectedProjectID == removed else { return }
        if let next = projects.first(where: { $0.id != removed }) {
            select(next)
        } else {
            selectedProjectID = nil
            selectedChatID = nil
        }
    }

    private static func open(_ urls: [URL], in editor: Editor.App) {
        NSWorkspace.shared.open(urls, withApplicationAt: editor.url, configuration: NSWorkspace.OpenConfiguration())
    }
}
