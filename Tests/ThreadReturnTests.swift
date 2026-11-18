import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import OriCode

/// A long thread opened again after a new one took the window (⌘N, ⌘2): the transcript comes
/// back showing its end, not a stretch of blank under the lazy stack's guess at its height.
@MainActor
struct ThreadReturnTests {
    private let suite = "ThreadReturnTests-\(UUID().uuidString)"
    private let container: ModelContainer
    private let defaults: UserDefaults
    private let project: Project
    private let model: AppModel
    private let long: Chat

    init() throws {
        container = try TestStore.memory()
        defaults = UserDefaults(suiteName: suite)!
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        long = Chat(project: project, title: "Tea")
        long.started = true
        long.position = 0
        container.mainContext.insert(long)
        try container.mainContext.save()
        model = AppModel(container: container, drafts: defaults)
        model.selectedProjectID = project.id
        model.selectedChatID = long.id
        model.drawerPinned = false
        model.drawerShown = false
        // Something half written in its composer, four lines of it, as Molten had.
        model.composer(for: long).draft.text = String(repeating: "bir iki üç dört beş altı yedi sekiz dokuz on ", count: 5)
        let conversation = model.conversation(for: long)
        for (asked, answer) in Self.turns {
            conversation.userSent(asked, previews: [], id: UUID())
            conversation.receive(EngineEvent(name: "text", threadId: long.id.uuidString, body: ["event": "text", "delta": .string(answer)]))
            conversation.receive(EngineEvent(name: "turn.done", threadId: long.id.uuidString, body: ["event": "turn.done", "stopReason": "end_turn"]))
        }
    }

    /// The thread Meriç had open, as Molten keeps it: a long Markdown reply and two of prose.
    private static let turns: [(String, String)] = [
        ("Without using any tools, write a long Markdown reply about tea: a ## heading, three paragraphs, a bulleted list of five items, a numbered list of four, a swift code block of about 15 lines, a link to https://en.wikipedia.org/wiki/Tea, another ## heading and three more paragraphs.", """
## A Leaf That Crossed the World

Tea starts as one plant, Camellia sinensis, an evergreen shrub that would grow into a small tree if growers let it. Everything sold as true tea, from a pale silver needle to a smoky lapsang, comes from its leaves and buds. The differences come from where the plant grows, which variety it is, when the leaves are picked, and above all what happens to them after picking. Herbal infusions like chamomile or rooibos get called tea in everyday speech, but they come from other plants entirely.

The drink most likely began in southwestern China, where people chewed or boiled the leaves for medicine long before anyone drank them for pleasure. By the Tang dynasty, tea had become ordinary enough that Lu Yu could write The Classic of Tea, a whole book on growing, processing and brewing it. Buddhist monks carried it to Japan, traders took it along the overland routes to Central Asia and Russia, and Dutch and Portuguese ships brought it to Europe in the seventeenth century. Britain's appetite for it later shaped colonial policy in India and Ceylon, and the British East India Company smuggled plants and expertise out of China to start plantations in Assam and Darjeeling.

Processing is what separates the main styles, and oxidation matters most. When a leaf is bruised or rolled, enzymes react with air and the leaf darkens, much like a cut apple does. Green tea is heated soon after picking to stop that reaction, so it keeps a fresh, grassy taste. Black tea is left to oxidize fully, which gives it malty, deeper flavors. Oolong sits somewhere in between, and its range runs from almost green to almost black. White tea gets the least handling of all: it is withered and dried, and little else is done to it.

- Green tea, steamed in Japan or pan-fired in China, with vegetal and sometimes marine notes
- Black tea, fully oxidized, the base of most breakfast blends and of masala chai
- Oolong, partly oxidized, often rolled into tight balls that unfurl over several infusions
- White tea, made from young buds and leaves, delicate and faintly sweet
- Pu-erh, fermented and often aged for years, earthy and prized by collectors

Brewing a good cup is mostly a matter of controlling a few variables:

1. Use fresh, filtered water, since chlorine and heavy minerals flatten the flavor.
2. Match the temperature to the tea, around 75 to 80°C for green and close to boiling for black.
3. Measure the leaf, roughly 2 to 3 grams per 200 milliliters as a starting point.
4. Time the steep, then remove the leaves so the cup does not turn bitter.

If you wanted an app to handle those numbers for you, a small Swift model could look like this:

```swift
enum TeaKind: String, CaseIterable {
    case green, black, oolong, white, puerh

    var temperatureCelsius: Int {
        switch self {
        case .green: return 78
        case .white: return 80
        case .oolong: return 90
        case .black, .puerh: return 98
        }
    }

    var steepSeconds: Int {
        switch self {
        case .green, .white: return 120
        case .oolong: return 150
        case .black, .puerh: return 240
        }
    }
}
```

There is much more history, chemistry and regional detail in the [Wikipedia article on tea](https://en.wikipedia.org/wiki/Tea).

## Tea as Ritual and Habit

Many cultures turned the practice of drinking tea into something more formal than the drink itself. The Japanese tea ceremony, chanoyu, sets out each gesture, from how the bowl is wiped to how the guest turns it before drinking, and it treats the whole thing as a discipline of attention. The Chinese gongfu style is looser but still exact about its methods: small clay pots, a high ratio of leaf to water, and many short infusions, each tasting a little different from the last. In both, what you notice is the point as much as what you drink.

Everyday tea has rituals too, even if nobody calls them that. In Turkey, tea comes in small tulip-shaped glasses from a stacked double kettle called a çaydanlık. Strong tea brews in the upper pot, and each drinker dilutes it with hot water from the lower one. It is offered in shops, offices and homes almost by reflex. In Morocco, green tea with fresh mint and a lot of sugar is poured from a height to raise a foam. In Britain, the question of whether milk goes in before or after the tea has run for centuries without being settled.

Tea also carries real economic and environmental weight. Millions of smallholders and plantation workers depend on it, often for low wages, and climate change is already moving the altitudes and regions where the best leaves can grow. Buying from producers who are open about their sourcing, or from single estates that name their gardens, is one way to get better tea and a fairer trade at once. Even a plain teabag in the morning connects you to all of that history.
"""),
        ("Without tools, write about 500 words of plain prose paragraphs on the history of coffee.", """
Coffee's history begins in the highlands of Ethiopia, where the coffee plant grows wild in the understory of forests. A common story holds that a goatherd named Kaldi noticed his animals becoming unusually lively after eating the red berries of a certain shrub, though the tale first appears centuries after the events it describes and is best treated as a legend. What is better documented is that people in the Horn of Africa were chewing the fruit and crushing the beans into mixtures with fat for energy long before anyone roasted them and brewed a drink.

The practice of brewing coffee likely developed in Yemen, probably sometime in the fifteenth century. Sufi mystics in the region used the beverage to stay awake during long nights of devotional prayer, and coffee houses, known as qahveh khaneh, soon spread through the cities of the Arabian Peninsula. These gathering places became centers of conversation, music, chess and news. Their popularity alarmed some religious and political authorities, who saw the crowds as a threat to order. Several rulers attempted to close the houses, and debates over whether coffee itself was permissible under Islamic law continued for years. Despite these efforts, the drink kept spreading along the trade routes that connected Yemen to Mecca, Cairo, Damascus and Istanbul.

By the sixteenth century, coffee had reached the Ottoman Empire, where it became deeply woven into social life. Istanbul opened its first coffee houses in the mid-1550s, and they quickly became fixtures of urban culture. Ottoman coffee was prepared in a small pot called a cezve, with finely ground beans boiled together with sugar, a method that survives in Turkey and much of the Middle East today. Coffee also reached Europe through Venice, where merchants brought it in the early seventeenth century. Church leaders there were reportedly suspicious of the drink, and according to a popular story Pope Clement VIII tasted it and gave it his approval, which helped it gain acceptance. European coffee houses soon appeared in London, Paris, Vienna and elsewhere, and they became known as "penny universities" in England because a cup cost a penny and conversation was free.

The Dutch played a decisive role in the plant's global spread. They obtained seedlings from Yemen and began cultivating coffee in Java, then part of their colonial holdings, in the late 1600s. Later, plants from Dutch stock were sent to botanical gardens in Amsterdam and then to the Americas. The French carried a seedling to Martinique in 1720, and from there coffee spread across the Caribbean, Central America and South America. Brazil became the world's dominant producer during the nineteenth century, and its plantations, worked for generations by enslaved Africans and later by paid laborers, shaped both the global supply and the economies of many nations. Colonial powers established coffee estates across Africa and Asia, often at great human cost.

In the modern era, coffee has changed in many ways. Espresso machines developed in Italy in the early twentieth century, and instant coffee was commercialized in the years around the First and Second World Wars. The specialty coffee movement of recent decades has returned attention to origin, varietal, processing and roasting, reconnecting drinkers with the farmers who grow the beans. At the same time, climate change, disease and price volatility threaten growers in many producing regions. The long journey of coffee from a wild shrub in Ethiopia to a daily ritual for billions of people reflects religion, commerce, colonialism and pleasure, and its history continues to unfold in every cup poured today.
"""),
        ("Without tools, write about 500 words of plain prose paragraphs on the history of chocolate.", """
Chocolate begins in the rainforests of Mesoamerica, where the cacao tree grows in the shade of taller trees. The Olmec, who lived on the Gulf Coast of present-day Mexico roughly three thousand years ago, are thought by many researchers to have been among the first to process cacao beans, though the evidence is indirect and debated. Chemical residue found on pottery at sites in Honduras points to cacao drinks being made more than three thousand years ago, which places the beginnings of chocolate far earlier than most people imagine. The Maya later cultivated cacao widely, and their cities depended on it for trade, ceremony and daily life. Cacao beans even served as currency in some parts of the region.

The drink people made from cacao was very different from the sweet chocolate of today. Beans were roasted, ground into a paste, mixed with water, and often flavored with chili, maize, vanilla or annatto. The result was frothy, bitter and thick, and it was usually served cold or at room temperature. The Aztecs, who controlled much of Mesoamerica when Spanish forces arrived, prized the drink highly. Their word for it, xocolatl, is often linked to the modern word chocolate, though the exact origin of the name remains uncertain. Aztec rulers reportedly drank it from gold cups, and it was reserved largely for nobles, warriors and religious occasions.

Spanish conquistadors encountered cacao in the early sixteenth century and brought it back to Europe, where it first circulated mainly among the Spanish court and clergy. Europeans began adding sugar, cinnamon and vanilla, and the drink became warmer and sweeter to suit local tastes. For a long time chocolate remained a luxury enjoyed by the wealthy, and it was sometimes consumed in private chocolate houses, which were fashionable gathering places in cities such as London during the seventeenth and eighteenth centuries. Debates even arose over whether chocolate broke religious fasting rules, and some church authorities took the question seriously.

The technical transformation of chocolate came in the nineteenth century. In 1828, the Dutch chemist Coenraad van Houten developed a press that separated cacao butter from the ground beans, producing a fine cocoa powder that mixed easily with liquids. Shortly afterward, British and Swiss manufacturers began making solid eating chocolate, and in 1875 the Swiss Daniel Peter combined chocolate with condensed milk, developed by Henri Nestlé, to create milk chocolate. These innovations turned chocolate from a bitter drink into a confection that could be sold to ordinary people in bars and boxes. Companies such as Cadbury, Fry's, Lindt and Hershey grew into international brands during this period.

Chocolate remains tied to the regions where cacao is grown, and that connection carries serious questions today. Most cacao now comes from smallholder farms in West Africa, particularly Côte d'Ivoire and Ghana, where child labor, low farmgate prices and deforestation are persistent concerns. Growers face pressure from disease, climate change and aging trees, and many depend on fluctuating global markets. Fair trade certification, direct sourcing and efforts to pay farmers more have attempted to address these problems, with mixed results. The story of chocolate, which began as a bitter drink shared among ancient Mesoamerican communities, now runs through global supply chains that touch almost every household on Earth.
""")
    ]

    @Test func aLongThreadOpenedAgainShowsItsEnd() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = stage(width: 1180)
        defer { window.close() }
        try await settle(1.5)
        let first = try #require(standing(in: window))
        #expect(first.atEnd, "the thread didn't come up at its end the first time: \(first)")
        for time in 1...5 {
            // ⌘N, a thread waiting for its first message; the long one's transcript goes.
            try #require(model.newChat())
            try await settle(1.2)
            // ⌘2, the long thread again.
            model.select(long)
            try await settle(1.5)
            let back = try #require(standing(in: window))
            #expect(back.atEnd, "return \(time) stood at \(back)")
        }
    }

    /// A short thread sent from home with a picture, opened from the drawer once its turn is
    /// over: its lines are on screen without a scroll.
    @Test func aShortThreadWithAPictureOpenedFromHomeShowsItsLines() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let short = Chat(project: project, title: "Ok")
        short.started = true
        short.position = 1
        container.mainContext.insert(short)
        let conversation = model.conversation(for: short)
        let picture = NSImage(size: NSSize(width: 600, height: 400), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(picture.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        conversation.userSent("Reply with one word: ok", previews: [png], id: UUID())
        conversation.receive(EngineEvent(name: "thinking", threadId: short.id.uuidString, body: ["event": "thinking", "delta": .string("Just one word.")]))
        conversation.receive(EngineEvent(name: "text", threadId: short.id.uuidString, body: ["event": "text", "delta": .string("ok")]))
        conversation.receive(EngineEvent(name: "turn.done", threadId: short.id.uuidString, body: ["event": "turn.done", "stopReason": "end_turn"]))
        model.selectedChatID = nil
        model.drawerPinned = true
        let window = stage(width: 1180)
        defer { window.close() }
        try await settle(1.5)
        for time in 1...3 {
            // Built while no window shows, as a thread opened from home behind another app is.
            window.orderOut(nil)
            model.select(short)
            try await settle(0.6)
            window.orderFrontRegardless()
            try await settle(1.5)
            let seen = try #require(standing(in: window))
            #expect(seen.text > 0, "open \(time) showed \(seen)")
            model.selectedChatID = nil
            try await settle(1.0)
        }
    }

    private struct Standing: CustomStringConvertible {
        let top: CGFloat, bottom: CGFloat, height: CGFloat
        /// How much of the replies' text shows in the transcript, in points of its height.
        let text: CGFloat
        /// Its foot at the document's, and the replies' text on screen there.
        var atEnd: Bool { abs(bottom - height) < 2 && text > 100 }
        var description: String { "\(Int(top))-\(Int(bottom)) of \(Int(height)), \(Int(text))pt of text showing" }
    }

    /// Where the transcript's scroll view stands in its document, the tallest one in the window,
    /// and how much of the replies' text shows in it: a reply is a text view of its own, laid out
    /// only around what the lazy stack shows.
    private func standing(in window: NSWindow) -> Standing? {
        func all<V: NSView>(_ view: NSView, _ kind: V.Type) -> [V] {
            ((view as? V).map { [$0] } ?? []) + view.subviews.flatMap { all($0, kind) }
        }
        guard let root = window.contentView,
              let scroll = all(root, NSScrollView.self).filter({ $0.frame.height > 300 && $0.frame.width > 300 })
                .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let document = scroll.documentView else { return nil }
        let seen = scroll.contentView.bounds
        let top = document.isFlipped ? seen.minY : document.frame.height - seen.maxY
        let window = scroll.convert(scroll.bounds, to: nil)
        let text = all(document, ReplyTextView.self)
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .map { $0.convert($0.bounds, to: nil).intersection(window) }
            .filter { !$0.isNull }
            .reduce(0) { $0 + $1.height }
        return Standing(top: top, bottom: top + seen.height, height: document.frame.height, text: text)
    }

    private final class Unplaced: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func stage(width: CGFloat) -> NSWindow {
        let host = NSHostingController(rootView: AnyView(
            RootView()
                .environment(model)
                .environment(Updates())
                .modelContainer(container)
                .defaultAppStorage(defaults)
                .frame(minWidth: 720, minHeight: 480)
                .preferredColorScheme(.dark)))
        let window = Unplaced(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.title = ""
        window.ignoresMouseEvents = true
        window.setContentSize(NSSize(width: width, height: 760))
        window.setFrameOrigin(NSPoint(x: 120, y: 120))
        window.level = .floating
        window.alphaValue = 0.01
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private func settle(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }
}
