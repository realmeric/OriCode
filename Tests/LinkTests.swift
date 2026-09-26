import Foundation
import Testing
@testable import OriCode

/// A link in a reply, built the way MarkdownUI builds it: `URL(string:)` with no base.
struct LinkTests {
    private let cwd = "/Users/me/Projects/app"

    private func file(_ destination: String) -> LinkedFile? {
        URL(string: destination).flatMap { LinkedFile($0, cwd: cwd) }
    }

    @Test func aPathIsTheThreadsFolderOrItsOwn() {
        #expect(file("App/Files.swift") == LinkedFile(path: "/Users/me/Projects/app/App/Files.swift", line: nil))
        #expect(file("./App/../README.md")?.path == "/Users/me/Projects/app/README.md")
        #expect(file("/etc/hosts")?.path == "/etc/hosts")
        #expect(file("~/notes.txt")?.path == NSHomeDirectory() + "/notes.txt")
        #expect(file("file:///Users/me/Projects/app/App/Files.swift") == LinkedFile(path: "/Users/me/Projects/app/App/Files.swift", line: nil))
    }

    @Test func everyWayOfWritingALine() {
        #expect(file("App/Files.swift#L42")?.line == 42)
        #expect(file("App/Files.swift#L42-L50")?.line == 42)
        #expect(file("App/Files.swift:42")?.line == 42)
        #expect(file("App/Files.swift:42:7") == LinkedFile(path: "/Users/me/Projects/app/App/Files.swift", line: 42))
        #expect(file("file:///Users/me/Projects/app/App/Files.swift#L9")?.line == 9)
        #expect(file("README.md#setup") == LinkedFile(path: "/Users/me/Projects/app/README.md", line: nil))
    }

    @Test func aFileAndLineThatParseAsAScheme() {
        #expect(file("Files.swift:42") == LinkedFile(path: "/Users/me/Projects/app/Files.swift", line: 42))
        #expect(file("Makefile:12:3") == LinkedFile(path: "/Users/me/Projects/app/Makefile", line: 12))
    }

    @Test func spacesArePercentDecoded() {
        #expect(file("My%20Notes/todo.txt:3") == LinkedFile(path: "/Users/me/Projects/app/My Notes/todo.txt", line: 3))
        #expect(file("file:///Users/me/My%20Notes/todo.txt")?.path == "/Users/me/My Notes/todo.txt")
    }

    @Test func theWebAndOtherAppsKeepTheirLinks() {
        #expect(file("https://github.com/realmeric/OriCode/blob/main/App/Files.swift#L42") == nil)
        #expect(file("http://localhost:8080") == nil)
        #expect(file("mailto:someone@example.com") == nil)
        #expect(file("tel:5551234") == nil)
        #expect(file("#top") == nil)
    }
}
