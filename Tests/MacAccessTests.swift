import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import OriCode

/// Seeing and using the Mac (K-290): the one answer it's asked for, the send that carries it, and
/// what the app does with an agent's call while it's off, on its own windows, and without the
/// permissions macOS gives. The test host has neither permission, so a picture or a click here
/// stops at saying which one is missing.
@MainActor
@Suite(.serialized)
struct MacAccessTests {
    private let container: ModelContainer

    init() throws {
        container = try TestStore.memory()
    }

    /// Runs `body` with the answer set to `answer`, nil for never asked, and puts back what was there.
    private func with(_ answer: String?, _ body: () async throws -> Void) async rethrows {
        let before = UserDefaults.standard.string(forKey: MacAccess.key)
        defer { UserDefaults.standard.set(before, forKey: MacAccess.key) }
        UserDefaults.standard.set(answer, forKey: MacAccess.key)
        try await body()
    }

    private func event(_ name: String, _ body: [String: JSON] = [:]) -> EngineEvent {
        EngineEvent(name: name, threadId: UUID().uuidString, body: .object(body))
    }

    private func refusal(_ name: String, _ body: [String: JSON] = [:]) async -> String? {
        do {
            _ = try await MacHands.answer(event(name, body), from: UUID())
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func itIsAskedUntilAnsweredEitherWay() async {
        await with(nil) { #expect(MacAccess.unanswered && !MacAccess.isOn) }
        await with(MacAccess.off) { #expect(!MacAccess.unanswered && !MacAccess.isOn) }
        await with(MacAccess.on) { #expect(!MacAccess.unanswered && MacAccess.isOn) }
    }

    @Test func aSendCarriesItOnlyWhileItIsOn() async throws {
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        let chat = Chat(project: project)
        container.mainContext.insert(chat)
        try container.mainContext.save()
        let model = AppModel(container: container)
        await with(MacAccess.on) { #expect(model.sendParams(in: chat, text: "hi", images: [])["mac"] == true) }
        await with(MacAccess.off) { #expect(model.sendParams(in: chat, text: "hi", images: [])["mac"] == nil) }
        await with(nil) { #expect(model.sendParams(in: chat, text: "hi", images: [])["mac"] == nil) }
    }

    @Test func offTheAppDoesNothingAnAgentAsks() async {
        await with(MacAccess.off) {
            for name in MacHands.asks {
                #expect(await refusal(name, ["app": "Finder", "bundleId": "com.apple.finder"])?.contains("hasn't let agents see and use the Mac") == true)
            }
        }
    }

    @Test func itNeverOffersOrFindsOriCodesOwnWindows() async throws {
        await with(MacAccess.on) {
            let listed = try? await MacHands.answer(event("mac.apps"), from: UUID())
            let ids = listed?["apps"]?.array?.compactMap { $0["bundleId"]?.string } ?? []
            #expect(!ids.isEmpty)
            // Another process of this build, the Molten make run opened beside the test host,
            // is another app's windows; this process is never listed or found.
            let mine = Bundle.main.bundleIdentifier ?? ""
            let others = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == mine && $0 != NSRunningApplication.current && $0.activationPolicy == .regular }
            #expect(ids.filter { $0 == mine }.count == others.count)
            if others.isEmpty {
                #expect(await refusal("mac.find", ["app": .string(Build.name)])?.contains("never lets an agent see or use its own windows") == true)
            } else {
                #expect(await refusal("mac.find", ["app": .string(Build.name)]) == nil)
            }
            #expect(await refusal("mac.find", ["app": "No Such App Anywhere"]) == "No app called No Such App Anywhere is running. list_apps lists the ones that are.")
            let finder = try? await MacHands.answer(event("mac.find", ["app": "finder"]), from: UUID())
            #expect(finder?["bundleId"] == "com.apple.finder")
        }
    }

    @Test func withoutMacOSsPermissionsItSaysWhichIsMissing() async {
        await with(MacAccess.on) {
            if !CGPreflightScreenCaptureAccess() {
                #expect(await refusal("mac.screenshot", ["bundleId": "com.apple.finder"])?.contains("doesn't have Screen Recording") == true)
            }
            if !AXIsProcessTrusted() {
                #expect(await refusal("mac.click", ["bundleId": "com.apple.finder", "x": 1, "y": 1])?.contains("doesn't have Accessibility") == true)
                #expect(await refusal("mac.type", ["bundleId": "com.apple.finder", "text": "x"])?.contains("doesn't have Accessibility") == true)
            }
        }
    }

    @Test func keysAreNamedAsPressKeySaysThem() {
        #expect(MacHands.keys("cmd+,")?.0 == 43)
        #expect(MacHands.keys("cmd+,")?.1 == .maskCommand)
        #expect(MacHands.keys("CMD+Shift+K")?.0 == 40)
        #expect(MacHands.keys("cmd+shift+k")?.1 == [.maskCommand, .maskShift])
        #expect(MacHands.keys("return")?.0 == 36)
        #expect(MacHands.keys("cmd++")?.0 == 24)
        #expect(MacHands.keys("f12")?.0 == 111)
        #expect(MacHands.keys("hyper+k") == nil)
        #expect(MacHands.keys("cmd+") == nil)
        #expect(MacHands.keys("") == nil)
    }

    @Test func theAskNamesTheAppItIsFor() {
        let ask = PendingAsk(requestId: "r", kind: "permission", tool: "Mac", input: ["app": "OriCode Molten", "bundleId": "com.realmeric.oricode.molten"], options: nil)
        #expect(ask.app == "OriCode Molten")
        let other = PendingAsk(requestId: "s", kind: "permission", tool: "Bash", input: ["app": "x"], options: nil)
        #expect(other.app == nil)
        #expect(AppModel.afterQuit(ask, allow: false, answers: nil, message: "No.", cwd: "/tmp") == "The app was quit while you waited for permission to see and use OriCode Molten. No.")
    }

    /// Allowed on a card a quit cut off, the app goes to the engine with the send as the grant,
    /// which the engine allows before the agent calls on it again.
    @Test func anAskAQuitCutOffIsAllowedWithTheSend() throws {
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        let chat = Chat(project: project)
        container.mainContext.insert(chat)
        try container.mainContext.save()
        let model = AppModel(container: container)
        let ask = PendingAsk(requestId: "r", kind: "permission", tool: "Mac", input: ["app": "OriCode Molten", "bundleId": "com.realmeric.oricode.molten"], options: nil)
        let grant = model.turnParams(in: chat, text: "go", allowing: ask)["grant"]
        #expect(grant?["tool"] == "Mac")
        #expect(grant?["input"]?["bundleId"] == "com.realmeric.oricode.molten")
    }

    @Test func sheetsAreLeftOutButWindowsSharingAFrameAreKept() {
        let main = CGRect(x: 0, y: 38, width: 1200, height: 800)
        let sheet = CGRect(x: 350, y: 66, width: 500, height: 424)
        let other = CGRect(x: 1000, y: 200, width: 600, height: 500)
        #expect(MacHands.unsheeted([main, sheet, other], frame: { $0 }) == [main, other])
        #expect(MacHands.unsheeted([main, main], frame: { $0 }) == [main, main])
    }

    @Test func textIsTypedInWholeCharactersTwentyUnitsAtMost() {
        let text = String(repeating: "a", count: 19) + "😀" + "b"
        let chunks = MacHands.chunks(text)
        #expect(chunks.map(\.count) == [19, 3])
        #expect(chunks.allSatisfy { $0.count <= 20 })
        #expect(String(decoding: chunks.joined(), as: UTF16.self) == text)
        #expect(MacHands.chunks("").isEmpty)
        #expect(MacHands.chunks(String(repeating: "x", count: 45)).map(\.count) == [20, 20, 5])
    }
}
