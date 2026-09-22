import Foundation
import Observation
import SwiftData

struct ModelOption: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let description: String
    let efforts: [String]
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
    /// A transient line under the composer, for things the user did that didn't work.
    private(set) var note: String?
    /// "from the next reply", shown under the capsule when a mode change can't reach the running turn.
    var modeNote: String?
    let engine = Engine()
    let context: ModelContext
    /// Bumped on every save so views reading fetched lists redraw.
    private(set) var revision = 0
    var conversations: [UUID: Conversation] = [:]
    private var listening = false
    private var noteTask: Task<Void, Never>?

    var selectedProjectID: UUID? {
        didSet { UserDefaults.standard.set(selectedProjectID?.uuidString, forKey: "selectedProject") }
    }

    var selectedChatID: UUID? {
        didSet { UserDefaults.standard.set(selectedChatID?.uuidString, forKey: "selectedChat") }
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

    init(container: ModelContainer) {
        context = container.mainContext
        selectedProjectID = UserDefaults.standard.string(forKey: "selectedProject").flatMap(UUID.init)
        selectedChatID = UserDefaults.standard.string(forKey: "selectedChat").flatMap(UUID.init)
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
