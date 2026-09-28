import Foundation
import SwiftData
import Testing
@testable import OriCode

/// Workflows, a switch of their own beside the level: sent with the level the thread is on, kept
/// with the thread they were turned on in, and said when Claude Code won't run them.
@MainActor
struct WorkflowsTests {
    private let container: ModelContainer
    private let project: Project
    private let chat: Chat
    private let model: AppModel

    static let models = [
        ModelOption(id: "sonnet", name: "Sonnet 5", description: "", efforts: ["low", "medium", "high", "xhigh", "max"],
                    fast: false, defaultEffort: "medium", ultra: true, ultraBlocked: nil, more: nil, needs: nil),
        ModelOption(id: "opus", name: "Opus 5.5", description: "", efforts: ["low", "medium", "high", "xhigh", "max"],
                    fast: false, defaultEffort: "medium", ultra: false, ultraBlocked: "workflows", more: nil, needs: nil),
    ]

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project)
        chat.model = "sonnet"
        chat.started = true
        chat.effort = "medium"
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model = AppModel(container: container)
        model.models = Self.models
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
    }

    @Test func aSendCarriesWorkflowsBesideTheLevel() {
        #expect(model.sendParams(in: chat, text: "go", images: [])["workflows"] == nil)
        model.setWorkflows(true, for: chat)
        let params = model.sendParams(in: chat, text: "go", images: [])
        #expect(params["effort"] == "medium")
        #expect(params["workflows"] == true)
        // On a model that can't run them the thread keeps its choice, and sends none.
        chat.model = "opus"
        #expect(model.sendParams(in: chat, text: "go", images: [])["workflows"] == nil)
        #expect(chat.workflows)
    }

    @Test func workflowsStayWithTheirThreadAndBackToDefaultsTurnsThemOff() throws {
        model.setWorkflows(true, for: chat)
        #expect(!model.atDefaults(chat))
        let next = try #require(model.newChat())
        #expect(!next.workflows)
        model.resetToDefaults(for: chat)
        #expect(!chat.workflows)
    }

    @Test func aThreadStoredAtUltracodeComesBackAtExtraHighWithWorkflows() throws {
        chat.effort = Effort.ultracode
        try container.mainContext.save()
        let again = AppModel(container: container)
        _ = again
        #expect(chat.effort == "xhigh")
        #expect(chat.workflows)
    }

    @Test func thePickerSaysWhenClaudeCodeWontRunThem() {
        model.setWorkflows(true, for: chat)
        let conversation = model.conversation(for: chat)
        #expect(PickerState(model: model, chat: chat).workflowsMissing == nil)
        conversation.receive(EngineEvent(name: "workflowTool", threadId: chat.id.uuidString, body: ["available": false]))
        #expect(PickerState(model: model, chat: chat).workflowsMissing == "Workflows are off in Claude Code · see /config")
        conversation.receive(EngineEvent(name: "effort", threadId: chat.id.uuidString,
                                         body: ["level": "medium", "ultracode": false, "asked": "xhigh", "askedUltracode": true]))
        #expect(PickerState(model: model, chat: chat).workflowsMissing == "Ultracode didn't turn on here · running at Medium")
    }
}
