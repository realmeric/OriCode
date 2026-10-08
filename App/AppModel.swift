import AppKit
import Foundation
import Observation
import SwiftData
import SwiftUI

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
    /// Whether a thread on it can run workflows, at any of its levels.
    let ultra: Bool
    /// Why it can't when it nearly could: "workflows" while dynamic workflows are off.
    let ultraBlocked: String?
    /// One of the account's older models, which Claude Code lists under More models.
    let more: Bool?
    /// The Claude Code version the model needs, when the one here is older: listed, not picked.
    let needs: String?
    /// The maker whose login reaches it, when that maker keeps the login to its own apps: pi's
    /// claude.ai, xAI and Meta logins. Listed, not picked, until it's turned on in Settings › Agents.
    var forbidden: String? = nil
    /// Its workflows are OriCode's own, on Rays: the head plans, sends workers out and merges what
    /// they bring, on a model with no workflows of its own.
    var ultraRays: Bool? = nil

    /// The SDK's id for Default (recommended), the model Claude Code picks.
    static let claudeDefault = "default"

    /// Whether a menu can pick it: nothing it needs is missing and nothing forbids it.
    var pickable: Bool { needs == nil && forbidden == nil }

    /// The model with workflows, for as long as the engine hasn't learned whether Claude Code runs
    /// them: a thread's workflows then show, and go out, as they are, and Claude Code runs them
    /// or not.
    var assumingWorkflows: ModelOption {
        guard !ultra, ultraBlocked == nil, needs == nil else { return self }
        return ModelOption(
            id: id, name: name, description: description, efforts: efforts, fast: fast, defaultEffort: defaultEffort,
            ultra: true, ultraBlocked: nil, more: more, needs: needs)
    }
}

/// Settings › New threads. Each setting is fixed there, or left empty to follow the last pick.
enum NewThreads {
    static let provider = "newThreadProvider"
    /// A model named the way ModelRef stores it.
    static let model = "newThreadModel"
    static let effort = "newThreadEffort"
    static let fast = "newThreadFast"
    static let permissionMode = "newThreadPermissionMode"
    /// Where a new thread works: empty for the project's folder, or `worktree` for a branch of its own.
    static let workspace = "newThreadWorkspace"
    static let worktree = "worktree"
    /// What a worktree thread's branch is called before its own name.
    static let branchPrefix = "branchPrefix"
    static let defaultBranchPrefix = "oricode/"
    /// Which model writes a commit message: empty for the agent's small one, or the thread's own.
    static let messageModel = "commitMessageModel"
    static let threadModel = "thread"
    /// The effort setting's value for Claude Code's own default: the thread picks no level.
    static let claudeDefault = "default"
    static let on = "on"
    static let off = "off"
}

/// Hello's levels for an agent end in `ultracode` when it can run workflows. A thread stored
/// before workflows were a switch of their own may still hold it as its effort, which
/// `carryUltracode` turns into Extra high with workflows on.
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
    let providers: [ProviderInfo]
}

@MainActor
@Observable
final class AppModel {
    /// The engine's own state. Whether an agent can run is the agent's, in `providers`: the
    /// engine is ready once hello answers, signed in or not, so git and the review work either way.
    enum EngineState: Equatable {
        case starting
        case ready
        case noNode(String)
        case stopped
    }

    var engineState: EngineState = .starting
    /// The agents hello lists, Claude Code alone until it answers.
    var providers: [ProviderInfo] = [.claude]
    /// Every agent the engine knows, turned on or not, for Settings › Agents.
    var agents: [AgentInfo] = []
    /// The model APIs with a key in the Keychain, as last asked.
    var keysKept: Set<String> = []
    /// Agents the engine is asking about after Settings › Agents changed them or showed them.
    var checkingAgents: Set<String> = []
    var agentSettings = AgentSettings()
    @ObservationIgnored var keychain = Keychain(prefix: "OriCode")
    /// Each agent's models by its id: Claude Code's from hello, another's once a menu needs them.
    var modelsByAgent: [String: [ModelOption]] = [:]
    /// The agents whose models have been asked for since the engine started.
    @ObservationIgnored var modelsAsked: Set<String> = []
    /// How long a thread only looked at stays in memory once another is open, and the timers that
    /// count it, one per thread left.
    @ObservationIgnored var awayLimit: Duration = .seconds(180)
    @ObservationIgnored var leaving: [UUID: Task<Void, Never>] = [:]
    /// The effortLevel in the user's Claude Code settings, which is where Default lands when set.
    var settingsEffort: String?
    /// Bumped whenever the app's defaults change, so what reads them there (a new thread's
    /// starting choices, which Settings can change) redraws.
    private(set) var defaultsRevision = 0
    /// Every write to UserDefaults posts the same notification, the window's frame on each move
    /// among them, so the revision moves only when one of the keys those choices read has.
    private static let startingKeys = [
        NewThreads.provider, NewThreads.model, NewThreads.effort, NewThreads.fast, NewThreads.permissionMode,
        "lastProvider", "lastModel", "lastEffort", "lastFast", "lastPermissionMode",
    ]
    @ObservationIgnored private var startingSeen: [String] = []
    /// Whether the main window can be seen: not hidden, minimised, on another Space or covered.
    @ObservationIgnored private var windowVisible = true {
        didSet { if windowVisible != oldValue { tellWindow() } }
    }
    /// What Claude Code last said about fast mode for each model, by ModelRef's key: whether it
    /// would serve it and, if not, why. The answer is the account's more than any thread's, so a
    /// thread that hasn't asked yet, or no thread at all, shows what's already known.
    var fastReadings: [String: FastReading] = [:]
    /// Bumped to put the cursor in the composer when nothing else would move it there: ⌘N on the
    /// draft that's already open.
    var composerFocus = 0
    /// What a link in the transcript does, made once: MarkdownUI makes `App/Foo.swift` a URL with
    /// no scheme, which the default action hands to Launch Services, and nothing there opens it.
    /// A new action on every body changed the environment of every Markdown block in the thread.
    /// One for each thread, since a thread in view isn't always the open one and a link resolves
    /// against its own thread's folder.
    @ObservationIgnored private var links: [UUID: OpenURLAction] = [:]

    func links(in thread: UUID) -> OpenURLAction {
        if let made = links[thread] { return made }
        let made = OpenURLAction { [unowned self] url in
            openLink(url, cwd: chat(withID: thread)?.cwd ?? "")
        }
        links[thread] = made
        return made
    }

    /// The models the user starred, by ModelRef's key, in the order starred; the models page and
    /// the model pickers put them first. One Claude Code stops listing stays here, unseen, in case
    /// it's back.
    var favoriteModels = UserDefaults.standard.stringArray(forKey: "favoriteModels") ?? [] {
        didSet { UserDefaults.standard.set(favoriteModels, forKey: "favoriteModels") }
    }
    /// The models Settings › Agents turned on or off for the model menu, by ModelRef's key. One
    /// not here follows its agent's picks (`ModelsPage.picks`).
    var menuModels = UserDefaults.standard.dictionary(forKey: "menuModels") as? [String: Bool] ?? [:] {
        didSet { UserDefaults.standard.set(menuModels, forKey: "menuModels") }
    }
    /// The agents the model page has open, the one in use when it turns to the page.
    var modelsOpen: Set<String> = []
    /// Whether the picker shows its rays' page, and the agents open on it.
    var raysShown = false
    var raysOpen: Set<String> = []
    /// A transient line under the composer, for things the user did that didn't work.
    private(set) var note: String?
    /// "from the next reply", shown under the capsule when a mode change can't reach the running turn.
    var modeNote: String?
    let engine = Engine()
    let notifier = Notifier()
    /// The build's Application Support folder, which the No folder project's own folder is in.
    @ObservationIgnored var support = Build.support
    let context: ModelContext
    /// Kept, so the context never outlives its store: an observer that fired on a model whose
    /// container had gone trapped inside SwiftData.
    private let store: ModelContainer
    /// Bumped on every save so views reading fetched lists redraw.
    private(set) var revision = 0
    /// The projects as of a revision, and the open thread as of a revision and a selection.
    @ObservationIgnored var fetched: (revision: Int, projects: [Project])?
    @ObservationIgnored var selected: (revision: Int, project: UUID?, id: UUID, chat: Chat?)?
    var conversations: [UUID: Conversation] = [:]
    /// What was said in every thread, for ⌘K, and the rows it gave the last query.
    let said = MessageIndex()
    @ObservationIgnored var paletteFound: (query: String, revision: Int, ready: Bool, items: [PaletteItem])?
    var branches: [UUID: BranchInfo] = [:]
    /// ⌘⇧D's review, and what it has read of the open thread's folder, which the button at
    /// the top right counts from even while it's closed.
    var reviewShown = false
    let review = ReviewState()
    var commandCenterShown = false
    /// ⌘I's heads, for the open thread.
    var headsShown = false {
        didSet { watchHeads() }
    }
    /// The thread the engine is telling what its heads are doing.
    var headsWatched: UUID?
    /// Your own ⌘K rows, from Application Support/OriCode/actions.json.
    let customActions = CustomActionStore()
    let shortcuts = Shortcuts()
    /// Threads whose session Continue in gave to their agent's CLI in a block, and that block.
    var handedOff: [UUID: UUID] = [:]
    /// The block drawn full over each thread's conversation, by thread: another thread keeps its
    /// own keyboard and asks, and coming back finds its block where it was.
    var openBlocks: [UUID: UUID] = [:]
    /// The block whose panel is in the window but not yet showing: its terminal comes into the
    /// window in a turn with nothing moving, and the panel rises in the next.
    var stagingBlock: UUID?
    /// Whether the composer is a shell prompt for the thread's folder, after a `!` at its start.
    var shellPrompt = false
    /// The commands run from it in this launch, by their block's id, running or ended.
    var shellBlocks: [UUID: ShellBlock] = [:]
    /// Marks the blocks a message sent into a turn carried as read, by the message, once Claude
    /// takes it up.
    var shellReads: [UUID: () -> Void] = [:]
    /// Keeps App Nap off while a command runs.
    var shellActivity: NSObjectProtocol?
    /// Whether each block is in the transcript's view, once it has said.
    var shellsInView: [UUID: Bool] = [:]
    /// An item the transcript is asked to bring into view and light for a moment: a block's Show,
    /// or a message ⌘K found. It waits for the transcript that holds it, so it can be set in the
    /// same moment as the thread switch that brings that transcript.
    var reveal: UUID?
    /// Bumped to bring the thread's transcript to its end, as its pill does: ⌘K's way to it.
    var threadEnd = 0
    /// What the user's shell can run as a first word, for Tab at the prompt, once asked.
    var shellNames: Task<[String], Never>?
    /// The user's own zsh, kept to answer Tab at the prompt when that's their shell.
    var zshCompletion: ZshCompletion?
    /// Tab's list of matches is up in the composer, and Esc puts it away first.
    var composerMenu = false
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
    /// The prompt the latest click on a suggested thread handed the composer, which the next
    /// click's takes the place of.
    @ObservationIgnored var suggestedPrompt: String?
    /// Each agent's plan usage by its id, and when the engine last read it.
    var usages: [String: PlanUsage] = [:]
    var usagesAt: [String: Date] = [:]
    var usageStale = false
    var usageLoading = false
    var fileFinderShown = false
    /// Each folder's branch's pull request, for the folders that have one.
    var pulls: [String: PullRequest] = [:]
    /// The next look at a pull request whose checks still run.
    @ObservationIgnored var pullWatches: [String: Task<Void, Never>] = [:]
    /// How many times an open pull request has been found with no checks yet.
    @ObservationIgnored var pullLooks: [String: Int] = [:]
    /// Which threads the drawer lists; not kept, so a launch shows them all.
    var drawerFilter: DrawerFilter = .all
    var sideShown = false
    var pullShown = false
    var pullMerging = false
    var side = SideAnswer()
    var projectFiles: [String] = []
    /// The folder those files are in.
    @ObservationIgnored var projectFilesFolder: String?
    var openFile: OpenFile?
    /// A return of the keyboard to the composer is on its way. The model's own: kept by its
    /// address in a set, a model made where one had just been freed found the old one's still there.
    @ObservationIgnored var keyboardReturning = false
    /// The open file's editor, whose text a save reads.
    @ObservationIgnored weak var fileEditor: NSTextView?
    /// Slash commands by agent, then by folder; an empty list means they're being fetched.
    var slashCommands: [String: [String: [SlashCommandInfo]]] = [:]
    var drawerShown = false {
        didSet { if drawerShown { drawerBuilt = true } }
    }
    /// Whether the thread list has been made: from the pointer reaching the hot zone, or the first
    /// time it opens. After that it stays in the window, out of sight, so opening it moves it
    /// rather than makes it.
    var drawerBuilt = false
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
    var peekTask: Task<Void, Never>?
    /// The wait for the soonest session limit to reset, when a thread it stopped goes on.
    var resumeTask: Task<Void, Never>?
    private var booted = false
    /// A `provider` event that came before hello's list did, applied once it has.
    @ObservationIgnored var earlyProviders: [ProviderInfo] = []
    private var noteTask: Task<Void, Never>?

    var selectedProjectID: UUID? {
        didSet { UserDefaults.standard.set(selectedProjectID?.uuidString, forKey: "selectedProject") }
    }

    /// The thread the composer is on, and with it the capsule, the review, the menus and Esc.
    var selectedChatID: UUID? {
        didSet {
            // The thread beside, picked by any route, trades places with the one that was open:
            // each stays in its half and the composer crosses, so neither is drawn twice. A draft
            // or a thread that's gone has no half to keep, and the picked one is alone again.
            if let selectedChatID, selectedChatID == besideChatID {
                let other = oldValue.flatMap { staysInView($0) ? $0 : nil }
                if other != nil { composerHalf = composerHalf == .left ? .right : .left }
                besideChatID = other
            }
            // With no thread open there's no pair: an empty project picked shows its empty state.
            if selectedChatID == nil, besideChatID != nil { besideChatID = nil }
            if let oldValue, !inView(oldValue) { letGoSoon(oldValue) }
            if let selectedChatID { leaving[selectedChatID]?.cancel() }
            UserDefaults.standard.set(selectedChatID?.uuidString, forKey: "selectedChat")
            // A ⌘digit peek ends when another thread is opened, however it's opened.
            if peekedChatID != selectedChatID { peekedChatID = nil }
            if let selectedChatID { loadConversation(selectedChatID) }
            if let selectedChatID { notifier.clear(chatID: selectedChatID) }
            refreshBranch(for: chat)
            readReview()
            returnKeyboard()
            watchHeads()
            tellWindow()
        }
    }

    /// A second thread in view beside the open one, never the same thread. It can be another
    /// project's, so it's found with `chat(withID:)`.
    var besideChatID: UUID? {
        didSet {
            guard besideChatID != oldValue else { return }
            if let besideChatID, besideChatID == selectedChatID { self.besideChatID = nil }
            if let oldValue, !inView(oldValue) { letGoSoon(oldValue) }
            guard let besideChatID else {
                composerHalf = .left
                return
            }
            leaving[besideChatID]?.cancel()
            loadConversation(besideChatID)
            notifier.clear(chatID: besideChatID)
        }
    }

    enum Half {
        case left
        case right
    }

    /// Which half the open thread, and so the composer, is in while another is beside it.
    private(set) var composerHalf = Half.left

    /// Whether a thread is on the glass: the open one, or the one beside it.
    func inView(_ id: UUID) -> Bool {
        id == selectedChatID || id == besideChatID
    }

    /// Whether a thread can be left in view: one that has begun and is still in the drawer.
    private func staysInView(_ id: UUID) -> Bool {
        guard let chat = chat(withID: id) else { return false }
        return chat.started && !chat.archived && chat.project != nil
    }

    /// The thread beside takes the window when the open one is closed, archived or deleted;
    /// false when there's none.
    func besideTakesWindow() -> Bool {
        guard let id = besideChatID else { return false }
        besideChatID = nil
        guard let chat = chat(withID: id), chat.project != nil else { return false }
        select(chat)
        return true
    }

    var lastPermissionMode: String {
        get { UserDefaults.standard.string(forKey: "lastPermissionMode") ?? "default" }
        set { UserDefaults.standard.set(newValue, forKey: "lastPermissionMode") }
    }

    var lastModel: ModelRef? {
        get { Self.storedModel("lastModel") }
        set { UserDefaults.standard.set(newValue?.stored, forKey: "lastModel") }
    }

    var lastEffort: String? {
        get { UserDefaults.standard.string(forKey: "lastEffort") }
        set { UserDefaults.standard.set(newValue, forKey: "lastEffort") }
    }

    var lastFast: Bool {
        get { UserDefaults.standard.bool(forKey: "lastFast") }
        set { UserDefaults.standard.set(newValue, forKey: "lastFast") }
    }

    /// Claude Code's models, as hello and the `models` events give them.
    var models: [ModelOption] {
        get { models(of: ProviderInfo.claudeID) }
        set { modelsByAgent[ProviderInfo.claudeID] = newValue }
    }

    /// What the next new thread starts with: what Settings › New threads fixes, and the last
    /// pick in the composer for what it leaves to that.
    var startingModel: String? {
        _ = defaultsRevision
        let agent = startingProvider
        return [Self.storedModel(NewThreads.model), lastModel].compactMap { $0 }.first { $0.provider == agent }?.id
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
    /// the first its agent lists, for Claude Code the SDK's default; with only the levels its agent takes.
    func option(for chat: Chat?) -> ModelOption? {
        let id = chat == nil ? startingModel : chat?.model
        let list = models(of: providerID(for: chat))
        return (list.first { $0.id == id } ?? list.first).map(agent(for: chat).narrowing)
    }

    init(container: ModelContainer) {
        store = container
        context = container.mainContext
        selectedProjectID = UserDefaults.standard.string(forKey: "selectedProject").flatMap(UUID.init)
        selectedChatID = UserDefaults.standard.string(forKey: "selectedChat").flatMap(UUID.init)
        drawerShown = drawerPinned
        clearDrafts()
        carryUltracode()
        if let selectedChatID { loadConversation(selectedChatID) }
        notifier.open = { [weak self] id in self?.open(chatID: id) }
        colourProjects()
        startingSeen = startingValues
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startingDefaultsMoved() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, window.identifier?.rawValue.hasPrefix("main") == true else { return }
            let visible = window.occlusionState.contains(.visible)
            MainActor.assumeIsolated { self?.windowVisible = visible }
        }
        // Files change outside the app too: an editor, a terminal, another tool.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.readReview()
                self?.refreshPull(for: self?.chat)
            }
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
              chat.project != nil
        else { return }
        select(chat)
        (NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true } ?? NSApp.mainWindow)?.makeKeyAndOrderFront(nil)
    }

    /// Reads the thread's events on a context of its own, off the main thread, and replays them
    /// here. Anything that needs the conversation meanwhile, an engine event or a send, makes it
    /// at once through `conversation(for:)`, and then this one is dropped.
    private func loadConversation(_ id: UUID) {
        guard conversations[id] == nil else { return }
        let container = context.container
        Task {
            let stored = await Task.detached(priority: .userInitiated) { StoredEvent.read(id, from: ModelContext(container)) }.value
            guard inView(id), conversations[id] == nil,
                  let chat = try? context.fetch(FetchDescriptor<Chat>(predicate: #Predicate { $0.id == id })).first
            else { return }
            conversations[id] = Conversation(chat: chat, context: context, stored: stored, said: said, pictures: SentPictures.standard)
        }
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

    private var startingValues: [String] {
        Self.startingKeys.map { "\(UserDefaults.standard.object(forKey: $0) ?? "")" }
    }

    private func startingDefaultsMoved() {
        let now = startingValues
        guard now != startingSeen else { return }
        startingSeen = now
        defaultsRevision += 1
    }

    /// Tells the engine which thread is open and whether the window can be seen: while it can't,
    /// the other threads' idle CLIs go at once.
    func tellWindow() {
        guard engineState == .ready else { return }
        let params: JSON = ["threadId": selectedChatID.map { .string($0.uuidString) } ?? .null, "visible": .bool(windowVisible)]
        Task { _ = try? await engine.request("window", params) }
    }

    var nodeOverride: String? {
        UserDefaults.standard.string(forKey: "nodePath")
    }

    /// Once a launch: opened with a folder, the window's task runs twice.
    func boot() async {
        guard !booted else { return }
        booted = true
        installEscapeMonitor()
        installPasteMonitor()
        installActionKeys()
        Task { await listen() }
        await startEngine()
    }

    func startEngine() async {
        engineState = .starting
        do {
            try await engine.start(nodeOverride: nodeOverride)
            let reply = try await engine.request("hello", ["agents": agentsForHello])
            Engine.logger.notice("hello \(String(decoding: (try? reply.data()) ?? Data(), as: UTF8.self), privacy: .public)")
            let hello = try reply.decode(Hello.self)
            // Which models run workflows comes a moment later, in the models event.
            models = hello.models.map(\.assumingWorkflows)
            providers = hello.providers
            for found in earlyProviders { checked(found) }
            earlyProviders = []
            modelsAsked = []
            engineState = .ready
            Task { await loadAgents() }
            refreshBranch(for: chat)
            tellWindow()
            readReview()
            pickUpAfterQuit()
            scheduleResumes()
            watchHeads()
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
