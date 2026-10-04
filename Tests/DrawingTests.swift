import AppKit
import Testing
@testable import OriCode

@MainActor
struct DrawingTests {
    static let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 120">
      <rect x="10" y="10" width="300" height="100" rx="14" fill="white" fill-opacity="0.07"/>
      <text x="160" y="64" text-anchor="middle" fill="white">engine</text>
    </svg>
    """

    @Test func anSvgBlockIsADrawingOnceItsFenceCloses() throws {
        let closed = try #require(Drawing.source(of: "```svg\n\(Self.svg)\n```\n\n"))
        #expect(closed.closed && closed.svg == Self.svg)
        let streaming = try #require(Drawing.source(of: "``` SVG title\n<svg viewBox=\"0 0 10 10\">\n<rect"))
        #expect(!streaming.closed && streaming.svg == "<svg viewBox=\"0 0 10 10\">\n<rect")
        // A longer fence closes only on one as long, and tildes on tildes.
        #expect(Drawing.source(of: "````svg\n```\n<svg/>\n````")?.svg == "```\n<svg/>")
        #expect(Drawing.source(of: "~~~svg\n<svg/>\n```\n")?.closed == false)
    }

    @Test func otherBlocksStayAsTheyAre() {
        #expect(Drawing.source(of: "```swift\nlet a = 1\n```\n") == nil)
        #expect(Drawing.source(of: "```\n<svg/>\n```\n") == nil)
        #expect(Drawing.source(of: "```svgz\n<svg/>\n```\n") == nil)
        #expect(Drawing.source(of: "    ```svg\n<svg/>\n```\n") == nil)
        #expect(Drawing.source(of: "A paragraph about ```svg blocks.\n") == nil)
        #expect(Drawing.source(of: "```svg\n<svg/>\n```\ntext the split left behind\n") == nil)
    }

    @Test func aReplysSvgBlockIsItsOwnBlock() {
        let blocks = Reply.split("Here it is.\n\n```svg\n\(Self.svg)\n```\n\nAnd after.")
        #expect(blocks.count == 3)
        #expect(Drawing.source(of: blocks[1])?.svg == Self.svg)
    }

    @Test func aDrawingIsAsWideAsItsViewBoxAndNoWiderThanTheColumn() async throws {
        let image = try #require(await DrawingPress.shared.draw(Self.svg))
        #expect(image.size == CGSize(width: 320, height: 120))
        #expect(DrawingPress.shared.image(for: Self.svg) === image)
        let wide = Self.svg.replacingOccurrences(of: "0 0 320 120", with: "0 0 1464 120")
        let fitted = try #require(await DrawingPress.shared.draw(wide))
        #expect(abs(fitted.size.width - 732) <= 1 && abs(fitted.size.height - 60) <= 1, "\(fitted.size)")
        // Drawn clear, for the glass to show through.
        let pixels = try #require(image.representations.first as? NSBitmapImageRep)
        #expect(pixels.colorAt(x: 2, y: 2)?.alphaComponent == 0)
        #expect((pixels.colorAt(x: pixels.pixelsWide / 2, y: 30)?.alphaComponent ?? 0) > 0)
    }

    @Test func whatIsNotSvgStaysCode() async {
        #expect(await DrawingPress.shared.draw("not a drawing") == nil)
        #expect(DrawingPress.shared.refuses("not a drawing"))
    }
}
