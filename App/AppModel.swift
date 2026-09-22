import Foundation
import Observation

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
    let engine = Engine()
    private var listening = false

    var nodeOverride: String? {
        UserDefaults.standard.string(forKey: "nodePath")
    }

    func boot() async {
        if !listening {
            listening = true
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
            }
        }
    }

    private func handle(_ event: EngineEvent) {}
}
