import Foundation
import SwiftData
import Testing
@testable import OriCode

/// The menu's tools (K-303): what loosens what guards the user comes back as a change for them to
/// allow, and tightening is done at once.
@MainActor
struct MenuActsTests {
    @Test func whatLoosens() {
        #expect(MenuSetting.loosens("spend_per_thread", from: .number(5), to: .number(10)))
        #expect(MenuSetting.loosens("spend_per_thread", from: .number(5), to: .number(0)))
        #expect(!MenuSetting.loosens("spend_per_thread", from: .number(5), to: .number(2)))
        #expect(!MenuSetting.loosens("spend_per_thread", from: .number(0), to: .number(2)))
        #expect(MenuSetting.loosens("threads_working_at_once", from: .number(6), to: .number(8)))
        #expect(!MenuSetting.loosens("threads_working_at_once", from: .number(6), to: .number(3)))
        #expect(MenuSetting.loosens("threads_answer_first", from: false, to: true))
        #expect(!MenuSetting.loosens("threads_answer_first", from: true, to: false))
        #expect(MenuSetting.loosens("new_threads_permissions", from: "last_picked", to: "auto", lastPicked: "default"))
        #expect(!MenuSetting.loosens("new_threads_permissions", from: "auto", to: "last_picked", lastPicked: "default"))
        #expect(!MenuSetting.loosens("water", from: false, to: true))
    }

    @Test func aLooserModeIsAskedATighterOneIsSet() async throws {
        let container = try TestStore.memory()
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        let model = AppModel(container: container)
        model.support = FileManager.default.temporaryDirectory.appending(path: "oricode-menu-\(UUID().uuidString)", directoryHint: .isDirectory)
        model.providers = [.claude]
        let chat = Chat(project: project, title: "Lead", permissionMode: "acceptEdits")
        chat.provider = "claude"
        chat.started = true
        container.mainContext.insert(chat)
        try container.mainContext.save()

        let looser: JSON = ["tool": "change_thread", "args": ["permission_mode": "bypassPermissions", "reason": "Faster"]]
        let asked = try await model.menuAct(looser, from: chat.id)
        #expect(asked["change"] != nil)
        #expect(chat.permissionMode == "acceptEdits")

        let tighter: JSON = ["tool": "change_thread", "args": ["permission_mode": "plan", "reason": "Only reading now"]]
        _ = try await model.menuAct(tighter, from: chat.id)
        #expect(chat.permissionMode == "plan")

        var allowed = looser.object ?? [:]
        allowed["allowed"] = true
        _ = try await model.menuAct(.object(allowed), from: chat.id)
        #expect(chat.permissionMode == "bypassPermissions")
    }
}
