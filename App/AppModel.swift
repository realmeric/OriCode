import AppKit
import Foundation
import Observation
import OSLog
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
    /// The most tokens it reads at once, when the agent's catalog says: Claude Code's does.
    var window: Int? = nil

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
            ultra: true, ultraBlocked: nil, more: more, needs: needs, window: window)
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
    /// When this launch began. ⌘⇧I shows a plan whose tasks are all done only if one has changed since.
    @ObservationIgnored let openedAt = Date.now
    /// Each agent's models by its id: Claude Code's from hello, another's once a menu needs them.
    var modelsByAgent: [String: [ModelOption]] = [:]
    /// The agents whose models have been asked for since the engine started.
    @ObservationIgnored var modelsAsked: Set<String> = []
    /// How long a thread only looked at stays in memory once another is open, and the timers that
    /// count it, one per thread left.
    @ObservationIgnored var awayLimit: Duration = .seconds(180)
    @ObservationIgnored var leaving: [UUID: Task<Void, Never>] = [:]
    /// A thread's events from its turn's end on, held while its reply is still showing a burst
    /// the agent sent all at once, so the footer comes under the last words and not over them.
    @ObservationIgnored var behindBurst: [UUID: [EngineEvent]] = [:]
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
    /// What each thread's composer holds, by thread, and the one for the window with no thread
    /// open, which the thread it starts takes with it.
    @ObservationIgnored var composers: [UUID: ComposerState] = [:]
    @ObservationIgnored var looseComposer = ComposerState()
    /// Where started threads' drafts are kept across a quit, text only, and each draft's count of
    /// edits when it was last written there. A test gives its model a suite of its own.
    @ObservationIgnored let draftsKept: UserDefaults
    @ObservationIgnored var draftsWritten: [UUID: Int] = [:]
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
    /// The models heads never pick, as `agent/model`, from Settings › Agents.
    var headsKeepOff = Rays.keepOff {
        didSet { UserDefaults.standard.set(headsKeepOff, forKey: Rays.keepOffKey) }
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
    /// Each project's two letters on its badge, told apart from every other project's.
    @ObservationIgnored var initials: [UUID: String] = [:]
    @ObservationIgnored var selected: (revision: Int, project: UUID?, id: UUID, chat: Chat?)?
    var conversations: [UUID: Conversation] = [:]
    /// What an opened thread says before its stored events have made a conversation.
    var transcriptStatus: [UUID: String] = [:]
    @ObservationIgnored var conversationReadTokens: [UUID: UUID] = [:]
    @ObservationIgnored var transcriptStatusWaits: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let readEvents: @Sendable (UUID, ModelContext) throws -> [StoredEvent]
    private static let transcriptLogger = Logger(subsystem: "com.realmeric.oricode", category: "transcript")
    /// Claude Code's water on this Mac today, this week and this month, for the usage card.
    let waterTotals = WaterTotals()
    /// What was said in every thread, for ⌘K, and the rows it gave the last query.
    let said = MessageIndex()
    @ObservationIgnored var paletteFound: (query: String, revision: Int, ready: Bool, items: [PaletteItem])?
    /// What ⌘K reaches as it was last made, and the count that moves once something it read then
    /// has changed. Let go whenever ⌘K opens or closes. Seven of its rows read UserDefaults, which
    /// Observation never hears of, so what those keys held is kept with it.
    @ObservationIgnored var paletteKept: (turn: Int, defaults: [String], reach: PaletteReach)?
    var paletteTurn = 0
    var branches: [UUID: BranchInfo] = [:]
    /// ⌘⇧D's review, and what it has read of the open thread's folder, which the button at
    /// the top right counts from even while it's closed.
    var reviewShown = false
    let review = ReviewState()
    var commandCenterShown = false {
        didSet { paletteKept = nil }
    }
    /// ⌘I's heads, for the open thread.
    var headsShown = false {
        didSet { watchHeads() }
    }
    /// The thread the engine is telling what its heads are doing.
    var headsWatched: UUID?
    /// ⌘⇧I's screen of everything running, and how each thread's latest turn in this launch went,
    /// which only that screen reads.
    var overviewShown = false {
        didSet { if overviewShown != oldValue { overviewHeld = [:] } }
    }
    /// Whether each row on ⌘⇧I was at work as it opened, which holds its place while it's up.
    @ObservationIgnored var overviewHeld: [UUID: Bool] = [:]
    var outcomes: [UUID: Outcome] = [:]
    /// The ask a notification's click opened the screen on, lit at the top of its queue until the
    /// screen goes.
    var overviewAsk: String?
    /// The worker, subagent or workflow agent each live ask came from, by its request id: found
    /// once as the ask comes, or as the engine tells of the asker's thread after it, so a view
    /// reading who asks does a lookup. An ask from before a quit isn't here, and stays its holder's.
    var askers: [String: Chat] = [:]
    /// The thread answering for each ask before the user, by its request id, while one is: the
    /// thread that set the asker's turn going, or one above it (K-296). An ask not here is the user's.
    var askHolders: [String: UUID] = [:]
    /// Each held ask's deadline, after which it goes up by itself, and whether its holder has read
    /// it in a wait_thread yet.
    @ObservationIgnored var holdDeadlines: [String: (read: Bool, timer: Task<Void, Never>)] = [:]
    /// How long a thread has to read an ask in a wait_thread, and then to answer it.
    @ObservationIgnored var holdLimits = (unread: Duration.seconds(30), unanswered: Duration.seconds(120))
    /// The threads Stop has sent an interrupt to, until their turn ends: an ask of one is about to
    /// be cancelled, so the turn's end of the thread holding it doesn't send it up.
    @ObservationIgnored var interrupting: Set<UUID> = []
    /// The workflow agents' threads whose transcripts the engine reads for the app while they're
    /// on the glass.
    @ObservationIgnored var followed: Set<UUID> = []
    /// The pieces of a read of an agent's transcript before its last: where they end, and their events.
    @ObservationIgnored var heldPieces: [UUID: (offset: Int, events: [JSON])] = [:]
    /// The subagents' and workers' threads this engine has told of, by the agent's id, which each of
    /// a worker's events names.
    @ObservationIgnored var agentThreads: [String: UUID] = [:]
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
    /// ⌘K's levels, what's typed at each, and what it's doing.
    let palette = PaletteState()
    /// The model button's picker, here so Esc can close it before anything under it.
    var modelPickerShown = false
    /// Whether the last titled window to become key is the main one, for what ⌘W closes.
    var mainWindowKey = true
    /// Whether the engine has been told a turn is running, so it keeps App Nap off.
    var holdingForTurns = false
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
    /// wait_thread's calls by the thread they wait on, each woken when that thread's turn ends.
    @ObservationIgnored var turnWaits: [UUID: [UUID: TurnWait]] = [:]
    /// Each thread's plan that runs, how far it is and the time left, in engine/progress.ts's words,
    /// while a task of it works.
    var planLines: [UUID: String] = [:]
    /// Tasks of a plan that runs whose thread is being made, a worktree say, so none starts twice.
    @ObservationIgnored var startingTasks: Set<UUID> = []
    /// Threads the user stopped whose turn hasn't ended yet, so a task of a plan there says so.
    @ObservationIgnored var stoppedByUser: Set<UUID> = []
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
    /// The one ask whether agents may see and use the Mac, at a launch that hasn't answered it.
    var askingMacAccess = false
    var mouseInDrawer = false
    var drawerTask: Task<Void, Never>?
    var peekTask: Task<Void, Never>?
    /// The wait for the soonest session limit to reset, when a thread it stopped goes on.
    var resumeTask: Task<Void, Never>?
    private var booted = false
    /// The old threads' titles have been asked for, which happens once a launch.
    @ObservationIgnored private var titlesAsked = false
    /// The open thread's read at launch.
    @ObservationIgnored private var openRead: Task<Void, Never>?
    /// A `provider` event that came before hello's list did, applied once it has.
    @ObservationIgnored var earlyProviders: [ProviderInfo] = []
    private var noteTask: Task<Void, Never>?

    var selectedProjectID: UUID? {
        didSet { UserDefaults.standard.set(selectedProjectID?.uuidString, forKey: "selectedProject") }
    }

    /// The project the drawer's header names: picked there, in ⌘K or by adding one, and not
    /// moved by opening another project's thread, so the drawer keeps its shape. Its New thread
    /// starts there.
    var drawerProjectID: UUID? = UserDefaults.standard.string(forKey: "drawerProject").flatMap(UUID.init) {
        didSet { UserDefaults.standard.set(drawerProjectID?.uuidString, forKey: "drawerProject") }
    }

    /// The thread the keyboard is in, and with it the capsule, the review, the menus and Esc.
    var selectedChatID: UUID? {
        didSet {
            // The thread beside, picked by any route, trades places with the one that was open:
            // each stays in its half and the keyboard crosses, so neither is drawn twice. A draft
            // or a thread that's gone has no half to keep, and the picked one is alone again.
            if let selectedChatID, selectedChatID == besideChatID {
                let other = oldValue.flatMap { staysInView($0) ? $0 : nil }
                if other != nil { composerHalf = composerHalf == .left ? .right : .left }
                besideChatID = other
            }
            // With no thread open there's no pair: an empty project picked shows its empty state.
            if selectedChatID == nil, besideChatID != nil { besideChatID = nil }
            if let oldValue, oldValue != selectedChatID { keepDraft(of: oldValue) }
            if let oldValue, !inView(oldValue) {
                if conversations[oldValue] == nil { stopConversationRead(oldValue) }
                letGoSoon(oldValue)
            }
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
            followAgents()
        }
    }

    /// A second thread in view beside the open one, never the same thread. It can be another
    /// project's, so it's found with `chat(withID:)`.
    var besideChatID: UUID? {
        didSet {
            guard besideChatID != oldValue else { return }
            if let besideChatID, besideChatID == selectedChatID { self.besideChatID = nil }
            if let oldValue, !inView(oldValue) {
                if conversations[oldValue] == nil { stopConversationRead(oldValue) }
                letGoSoon(oldValue)
            }
            UserDefaults.standard.set(besideChatID?.uuidString, forKey: "besideChat")
            followAgents()
            guard let besideChatID else {
                composerHalf = .left
                return
            }
            leaving[besideChatID]?.cancel()
            loadConversation(besideChatID)
            notifier.clear(chatID: besideChatID)
        }
    }

    enum Half: String {
        case left
        case right
    }

    /// Which half the open thread, and so the keyboard, is in while another is beside it.
    private(set) var composerHalf = Half.left {
        didSet { UserDefaults.standard.set(composerHalf.rawValue, forKey: "composerHalf") }
    }

    /// The half the keyboard is in while both threads are drawn, which changes as it crosses to
    /// the other: the capsule's title fades on it, and a thread opened any other way takes the
    /// capsule's title at once.
    var keyboardSide: Half? {
        besideShown == nil ? nil : composerHalf
    }

    /// Where the window's capsule is drawn, in the window, which a drawer passing over may cut.
    var capsuleFrame = CGRect.zero

    /// At launch: the thread that was beside the open one is beside it again, each in the half it
    /// was in. One deleted or archived meanwhile isn't, and the open thread has the window; the
    /// half kept for that pair goes too, or the next pair would come back with its sides traded.
    private func restorePair() {
        let kept = UserDefaults.standard
        let half = kept.string(forKey: "composerHalf").flatMap(Half.init) ?? .left
        if let beside = kept.string(forKey: "besideChat").flatMap(UUID.init), chat?.started == true, staysInView(beside) {
            besideChatID = beside
        }
        if besideChatID == nil { kept.removeObject(forKey: "besideChat") }
        composerHalf = besideChatID == nil ? .left : half
    }

    /// Whether the conversation's side of the window is wide enough for two columns, as RootView
    /// last laid it out. Under that a pair folds to the open thread.
    var roomForTwo = true

    /// How wide the review's button is drawn, which the island's lane stops short of.
    var reviewButtonWidth: CGFloat = 0
    /// A pinned drawer put away for a review that had no room beside it; it comes back with the
    /// review's going.
    var drawerAside = false

    /// The thread beside, while it's drawn: there's room for two and the open thread has begun,
    /// a draft having the window to itself until its first message.
    var besideShown: Chat? {
        guard roomForTwo, let besideChatID, currentConversation?.started == true || chat?.started == true else { return nil }
        return chat(withID: besideChatID)
    }

    /// Whether a thread is drawn, which a thread folded away at a narrow width isn't: it stays in
    /// memory like one in view, and says so when it ends or asks like one that's away.
    func onGlass(_ id: UUID) -> Bool {
        id == selectedChatID || id == besideShown?.id
    }

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

    init(container: ModelContainer, drafts: UserDefaults = .standard,
         readEvents: @escaping @Sendable (UUID, ModelContext) throws -> [StoredEvent] = StoredEvent.read) {
        store = container
        context = container.mainContext
        draftsKept = drafts
        self.readEvents = readEvents
        selectedProjectID = UserDefaults.standard.string(forKey: "selectedProject").flatMap(UUID.init)
        // The drawer's header starts on the project that was open, and stays on it from then on.
        if drawerProjectID.map({ id in projects.contains { $0.id == id } }) != true { drawerProjectID = selectedProjectID }
        selectedChatID = UserDefaults.standard.string(forKey: "selectedChat").flatMap(UUID.init)
        drawerShown = drawerPinned
        clearDrafts()
        carryUltracode()
        if let selectedChatID { openRead = loadConversation(selectedChatID) }
        restorePair()
        notifier.open = { [weak self] id in self?.open(chatID: id) }
        notifier.openAsk = { [weak self] id, ask in self?.showAsk(ask, holder: id) }
        colourProjects()
        settleAgents()
        startingSeen = startingValues
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startingDefaultsMoved()
                self?.paletteDefaultsMoved()
            }
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
        // What's typed and not sent is kept as the app is left, since a crash or a kill asks nobody.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepDrafts() }
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
    @discardableResult
    private func loadConversation(_ id: UUID) -> Task<Void, Never>? {
        guard conversations[id] == nil else {
            transcriptStatus[id] = nil
            return nil
        }
        // A read still under way goes on; the thread opened again once it has failed reads afresh.
        guard conversationReadTokens[id] == nil else { return nil }
        stopConversationRead(id)
        let token = UUID()
        conversationReadTokens[id] = token
        // Ended with the read, so an open that reads in the usual few milliseconds wakes nothing later.
        transcriptStatusWaits[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, conversationReadTokens[id] == token,
                  conversations[id] == nil, inView(id)
            else { return }
            transcriptStatus[id] = "Still reading this conversation."
            Self.transcriptLogger.notice("Still reading transcript \(id.uuidString, privacy: .public)")
        }
        let container = context.container
        let first = openRead
        let reader = readEvents
        return Task { [weak self] in
            defer {
                if self?.conversationReadTokens[id] == token {
                    self?.conversationReadTokens[id] = nil
                    self?.transcriptStatusWaits[id]?.cancel()
                    self?.transcriptStatusWaits[id] = nil
                }
            }
            let stored: [StoredEvent]
            do {
                stored = try await Task.detached(priority: .userInitiated) { try reader(id, ModelContext(container)) }.value
            } catch {
                guard !Task.isCancelled, let self, conversationReadTokens[id] == token,
                      conversations[id] == nil, inView(id)
                else { return }
                let line = error.localizedDescription
                transcriptStatus[id] = line
                Self.transcriptLogger.error("Couldn't read transcript \(id.uuidString, privacy: .public): \(line, privacy: .public)")
                return
            }
            // A thread restored beside the open one is read alongside it and replayed after it,
            // so the pair's launch shows the open thread as soon as one thread's does.
            await first?.value
            guard !Task.isCancelled, let self, conversationReadTokens[id] == token, inView(id), conversations[id] == nil,
                  let chat = try? context.fetch(FetchDescriptor<Chat>(predicate: #Predicate { $0.id == id })).first
            else { return }
            let read = Conversation(chat: chat, context: context, stored: stored, said: said, pictures: SentPictures.standard)
            pace(read)
            conversations[id] = read
            transcriptStatus[id] = nil
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

    /// Settings › Agents' switch went off, so the apps each thread was let use are asked about
    /// again once it's back on.
    func tellMacOff() {
        guard engineState == .ready else { return }
        Task { _ = try? await engine.request("macOff", [:]) }
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

    /// Claude Code's titles for the threads that still go by their first message, asked for once
    /// a few seconds after launch, off the way of anything the user is doing: a thread otherwise
    /// takes its title only at its next turn (K-320), and an old one may never have another.
    private func titleOldThreads() {
        guard !titlesAsked else { return }
        titlesAsked = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, engineState == .ready else { return }
            let untitled = projects.flatMap(\.chats).filter { $0.started && !$0.titleIsCustom && $0.sessionId != nil && $0.providerID == ProviderInfo.claudeID }
            guard !untitled.isEmpty else { return }
            let sessions = untitled.map { JSON.object(["threadId": .string($0.id.uuidString), "sessionId": .string($0.sessionId ?? ""), "cwd": .string($0.cwd)]) }
            guard let reply = try? await engine.request("sessions.titles", ["sessions": .array(sessions)]), let titles = reply["titles"]?.object else { return }
            for chat in untitled where !chat.titleIsCustom {
                guard let title = titles[chat.id.uuidString]?.string?.nonEmpty else { continue }
                chat.title = Chat.title(from: title)
                chat.titleIsCustom = true
            }
            save()
        }
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
            movePlans()
            scheduleResumes()
            watchHeads()
            followAgents()
            titleOldThreads()
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
