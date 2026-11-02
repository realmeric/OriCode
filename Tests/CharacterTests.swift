import Foundation
import SwiftUI
import Testing
@testable import OriCode

/// What a memory pass reads of a thread.
struct CharacterTests {
    private let asked = UUID(), answered = UUID(), ran = UUID(), later = UUID()

    private func call(_ output: String) -> ToolCall {
        ToolCall(toolUseId: "1", name: "Bash", input: .object(["command": .string("bw get password github")]), result: output)
    }

    private var items: [Item] {
        [.user(id: asked, text: "Use one simulator", images: []), .tool(id: ran, call: call("the-password-out-of-oripass")), .text(id: answered, text: "Noted.")]
    }

    @Test func aPassReadsWhatWasSaidAndNothingAToolDid() {
        let (thread, last) = CharacterMemory.new(in: items, after: nil)
        #expect(thread == "User: Use one simulator\nAssistant: Noted.")
        #expect(last == answered)
    }

    @Test func aPassReadsOnlyWhatIsNew() {
        let more = items + [.user(id: later, text: "And sleep", images: [])]
        #expect(CharacterMemory.new(in: more, after: answered).thread == "User: And sleep")
    }

    @Test func aThreadTheUserSaidNothingNewInIsNotRead() {
        #expect(CharacterMemory.new(in: items, after: answered).thread.isEmpty)
        #expect(CharacterMemory.new(in: items + [.text(id: later, text: "More.")], after: answered).last == nil)
    }

    @Test func aColourReadsAsItsHex() {
        let hans = CharacterInfo(id: "hans", name: "Hans", symbol: "suit.spade.fill", colour: "#D8B26E")
        let gold = Color(red: 216.0 / 255, green: 178.0 / 255, blue: 110.0 / 255)
        #expect(hans.color == gold)
    }
}
