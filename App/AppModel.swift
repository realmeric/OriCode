import AppKit
import Foundation
import Observation
import SwiftData

struct ModelOption: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let description: String
    let efforts: [String]
    /// Whether the SDK says the model can run in fast mode.
    let fast: Bool
    /// The level a thread gets when it picks none: the model's own, or the effortLevel in the
    /// user's Claude Code settings. Nil when the model has no levels, or until the engine knows.
    let defaultEffort: String?
    /// Whether the thread can run as Ultracode on this model.
    let ultra: Bool
    /// Why it can't when it nearly could: "workflows" while dynamic workflows are off.
    let ultraBlocked: String?
    /// One of the account's older models, which Claude Code lists under More models.
    let more: Bool?
    /// The Claude Code version the model needs, when the one here is older: listed, not picked.
    let needs: String?

    /// The SDK's id for Default (recommended), the model Claude Code picks.
    static let claudeDefault = "default"

    /// Levels the picker offers, low to high, with Ultracode last where the model can run it,
    /// the way Claude Code's own picker has it.
    var levels: [String] {
        efforts + (ultra ? [Effort.ultracode] : [])
    }

    /// The stops the picker draws: Ultracode shows, dimmed, when only workflows keep it off.
    var stops: [String] {
        efforts + (ultra || ultraBlocked != nil ? [Effort.ultracode] : [])
    }
}

/// Settings › New threads. Each setting is fixed there, or left empty to follow the last pick.
enum NewThreads {
    static let model = "newThreadModel"
    static let effort = "newThreadEffort"
    static let fast = "newThreadFast"
    static let permissionMode = "newThreadPermissionMode"
    /// The effort setting's value for Claude Code's own default: the thread picks no level.
    static let claudeDefault = "default"
    static let on = "on"
    static let off = "off"
}

/// Effort as the wire has it: nil is Claude Code's default, and `ultracode` rides the same
/// field as the levels even though it's a session setting underneath.
enum Effort {
    static let ultracode = "ultracode"
}

struct FastReading: Equatable {
    /// on, off or cooldown.
    let state: String
    let reason: String?
}

struct Hello: Codable, Sendable {
    let version: String
    let models: [ModelOption]
    let claude: String?
    let loggedIn: Bool
}

@MainActor
@Observable
final class AppModel {
    enum EngineState: Equatable {
        case starting
        case ready
        case noNode(String)
        case noClaude
        case notLoggedIn
        case stopped
    }

    var engineState: EngineState = .starting
    var models: [ModelOption] = []
    /// The effortLevel in the user's Claude Code settings, which is where Default lands when set.
    var settingsEffort: String?
    /// Bumped whenever the app's defaults change, so what reads them there (a new thread's
    /// starting choices, which Settings can change) redraws.
    private(set) var defaultsRevision = 0
    /// What Claude Code last said about fast mode for each model, by the model's id: whether it
    /// would serve it and, if not, why. The answer is the account's more than any thread's, so a
    /// thread that hasn't asked yet, or no thread at all, shows what's already known.
    var fastReadings: [String: FastReading] = [:]
    /// Bumped to put the cursor in the composer when nothing else would move it there: ⌘N on the
    /// draft that's already open.
    var composerFocus = 0
    /// The models the user starred, by id, in the order starred; the models page and the model
    /// pickers put them first. One Claude Code stops listing stays here, unseen, in case it's back.
    var favoriteModels = UserDefaults.standard.stringArray(forKey: "favoriteModels") ?? [] {
        didSet { UserDefaults.standard.set(favoriteModels, forKey: "favoriteModels") }
    }
    /// A transient line under the composer, for things the user did that didn't work.
    private(set) var note: String?
    /// "from the next reply", shown under the capsule when a mode change can't reach the running turn.
    var modeNote: String?
    let engine = Engine()
    let notifier = Notifier()
    let context: ModelContext
    /// Bumped on every save so views reading fetched lists redraw.
    private(set) var revision = 0
    var conversations: [UUID: Conversation] = [:]
    var branches: [UUID: BranchInfo] = [:]
    var changesShown = false
    var commandCenterShown = false
    /// ⌘J's terminal, and the shells behind it, one per folder.
    var terminalShown = false
    let terminals = TerminalStore()
    /// Your own ⌘K rows, from Application Support/OriCode/actions.json.
    let customActions = CustomActionStore()
    /// Threads whose session Continue in Claude Code gave to the terminal's claude.
    var handedOff: Set<UUID> = []
    /// Where the composer's top edge is in the window, which the terminal stops above.
    var composerTop: CGFloat = 0
    /// ⌘K's levels, what's typed at each, and what it's doing.
    let palette = PaletteState()
    /// The model button's picker, here so Esc can close it before anything under it.
    var modelPickerShown = false
    /// Where the model button is in the window, so a click on it is left to the button.
    var modelButtonFrame = CGRect.zero
    /// Whether the last titled window to become key is the main one, for what ⌘W closes.
    var mainWindowKey = true
    /// Whether the engine has been told a turn is running, so it keeps App Nap off.
    var holdingForTurns = false
    var draftAttachments: [ImageAttachment] = []
    var usage: PlanUsage?
    var usageAt: Date?
    var usageStale = false
    var usageLoading = false
    var fileFinderShown = false
    var projectFiles: [String] = []
    var openFile: OpenFile?
    /// Slash commands by folder; an empty list means they're being fetched.
    var slashCommands: [String: [SlashCommandInfo]] = [:]
    let changes = ChangesState()
    var drawerShown = false
    var drawerPinned = UserDefaults.standard.bool(forKey: "drawerPinned") {
        didSet { UserDefaults.standard.set(drawerPinned, forKey: "drawerPinned") }
    }
    var peekedChatID: UUID?
    var renamingChatID: UUID?
    var deletingChat: Chat?
    /// A project Remove project… is asking about.
    var removingProject: Project?
    var deletingLoss: WorktreeLoss?
    var showingShortcuts = false
    var mouseInDrawer = false
    var drawerTask: Task<Void, Never>?
    private var listening = false
    private var noteTask: Task<Void, Never>?

    var selectedProjectID: UUID? {
        didSet { UserDefaults.standard.set(selectedProjectID?.uuidString, forKey: "selectedProject") }
    }

    var selectedChatID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedChatID?.uuidString, forKey: "selectedChat")
            loadSelectedConversation()
            if let selectedChatID { notifier.clear(chatID: selectedChatID) }
            refreshBranch(for: chat)
        }
    }

    var lastPermissionMode: String {
        get { UserDefaults.standard.string(forKey: "lastPermissionMode") ?? "default" }
        set { UserDefaults.standard.set(newValue, forKey: "lastPermissionMode") }
    }

    var lastModel: String? {
        get { UserDefaults.standard.string(forKey: "lastModel") }
        set { UserDefaults.standard.set(newValue, forKey: "lastModel") }
    }

    var lastEffort: String? {
        get { UserDefaults.standard.string(forKey: "lastEffort") }
        set { UserDefaults.standard.set(newValue, forKey: "lastEffort") }
    }

    var lastFast: Bool {
        get { UserDefaults.standard.bool(forKey: "lastFast") }
        set { UserDefaults.standard.set(newValue, forKey: "lastFast") }
    }

    /// What the next new thread starts with: what Settings › New threads fixes, and the last
    /// pick in the composer for what it leaves to that.
    var startingModel: String? {
        _ = defaultsRevision
        return UserDefaults.standard.string(forKey: NewThreads.model)?.nonEmpty ?? lastModel
    }

    var startingEffort: String? {
        _ = defaultsRevision
        return switch UserDefaults.standard.string(forKey: NewThreads.effort) ?? "" {
        case "": lastEffort
        case NewThreads.claudeDefault: String?.none
        case let level: level
        }
    }

    var startingFast: Bool {
        _ = defaultsRevision
        return switch UserDefaults.standard.string(forKey: NewThreads.fast) ?? "" {
        case NewThreads.on: true
        case NewThreads.off: false
        default: lastFast
        }
    }

    var startingPermissionMode: String {
        _ = defaultsRevision
        return UserDefaults.standard.string(forKey: NewThreads.permissionMode)?.nonEmpty ?? lastPermissionMode
    }

    /// The model a thread runs on: its own, or with no thread the one the next starts on, or
    /// the first the SDK lists, which is Claude Code's default.
    func option(for chat: Chat?) -> ModelOption? {
        let id = chat == nil ? startingModel : chat?.model
        return models.first { $0.id == id } ?? models.first
    }

    init(container: ModelContainer) {
        context = container.mainContext
        selectedProjectID = UserDefaults.standard.string(forKey: "selectedProject").flatMap(UUID.init)
        selectedChatID = UserDefaults.standard.string(forKey: "selectedChat").flatMap(UUID.init)
        drawerShown = drawerPinned
        clearDrafts()
        loadSelectedConversation()
        notifier.open = { [weak self] id in self?.open(chatID: id) }
        colourProjects()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsRevision += 1 }
        }
        // Titled windows only: text input puts borderless helper windows in the key spot too.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, window.styleMask.contains(.titled) else { return }
            let main = window.identifier?.rawValue.hasPrefix("main") == true
            MainActor.assumeIsolated { self?.mainWindowKey = main }
        }
    }

    func open(chatID: UUID) {
        guard let chat = try? context.fetch(FetchDescriptor<Chat>(predicate: #Predicate { $0.id == chatID })).first,
              let project = chat.project
        else { return }
        selectedProjectID = project.id
        selectedChatID = chat.id
        (NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true } ?? NSApp.mainWindow)?.makeKeyAndOrderFront(nil)
    }

    private func loadSelectedConversation() {
        guard let id = selectedChatID, conversations[id] == nil,
              let chat = try? context.fetch(FetchDescriptor<Chat>(predicate: #Predicate { $0.id == id })).first
        else { return }
        conversations[id] = Conversation(chat: chat, context: context)
    }

    func say(_ line: String) {
        note = line
        noteTask?.cancel()
        noteTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { note = nil }
        }
    }

    func touch() {
        revision += 1
    }

    var nodeOverride: String? {
        UserDefaults.standard.string(forKey: "nodePath")
    }

    func boot() async {
        if !listening {
            listening = true
            installEscapeMonitor()
            installPasteMonitor()
            Task { await listen() }
        }
        await startEngine()
    }

    func startEngine() async {
        engineState = .starting
        do {
            try await engine.start(nodeOverride: nodeOverride)
            let reply = try await engine.request("hello")
            Engine.logger.notice("hello \(String(decoding: (try? reply.data()) ?? Data(), as: UTF8.self), privacy: .public)")
            let hello = try reply.decode(Hello.self)
            models = hello.models
            engineState = hello.claude == nil ? .noClaude : hello.loggedIn ? .ready : .notLoggedIn
            refreshBranch(for: chat)
            refreshUsage()
        } catch let error as NodeLocator.NotFound {
            engineState = .noNode(error.message)
        } catch {
            Engine.logger.error("engine failed to start: \(error.localizedDescription, privacy: .public)")
            engineState = .stopped
        }
    }

    private func listen() async {
        for await output in engine.output {
            switch output {
            case .event(let event):
                handle(event)
            case .stopped:
                engineState = .stopped
                engineStopped()
            }
        }
    }

    private func handle(_ event: EngineEvent) {
        route(event)
    }
}
