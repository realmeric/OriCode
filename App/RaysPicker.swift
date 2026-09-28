import SwiftUI

/// A model as a ray: the head's mark small, with the arc this model stands on lit in its agent's
/// colour, or the mark at rest when it isn't one of the rays.
struct RayGlyph: View {
    let slot: Int?
    let color: Color

    /// Heavier than the mark's own proportion, which at this size draws hairlines. One Canvas, since
    /// seven shapes a row were most of what the rays' page cost to turn to.
    var body: some View {
        Canvas { context, size in
            let circle = CGRect(origin: .zero, size: size).insetBy(dx: 1.2, dy: 1.2)
            var resting = Path()
            for index in 0..<RaysMark.rays where index != slot {
                resting.addPath(Ray(index: index, count: RaysMark.rays, gap: 26).path(in: circle))
            }
            context.stroke(resting, with: .color(.white.opacity(slot == nil ? 0.4 : 0.2)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            if let slot {
                context.stroke(Ray(index: slot, count: RaysMark.rays, gap: 26).path(in: circle), with: .color(color),
                               style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
            let dot = CGRect(x: size.width / 2 - 2.25, y: size.height / 2 - 2.25, width: 4.5, height: 4.5)
            context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(slot == nil ? 0.4 : 0.7)))
        }
        .frame(width: 16, height: 16)
    }
}

/// How many rays the head has, and their names under it, or what having none means.
struct RaysTitle: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?

    var body: some View {
        let picked = model.rayNames(for: chat)
        let head = ModelMenu.shortName(model.option(for: chat)?.name ?? "The head")
        VStack(spacing: 2) {
            Text(picked.isEmpty ? "No rays" : picked.count == 1 ? "1 ray" : "\(picked.count) rays")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .frame(height: 26)
                .id(picked.count)
                .transition(.opacity.animation(Motion.fade))
            Text(picked.isEmpty ? "\(head) does every part itself" : picked.joined(separator: ", "))
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 16)
                .id(picked)
                .transition(.opacity.animation(Motion.fade))
        }
        .animation(Motion.move, value: picked)
        .accessibilityElement(children: .combine)
    }
}

/// A model that can be a ray: its agent's mark and name, and at the end the glyph that says which
/// arc it holds on the head's mark.
struct RayRow: View {
    let option: ModelOption
    let agent: String
    let slot: Int?
    let keyed: Bool
    /// Six are picked and this isn't one of them.
    let full: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let lit = slot != nil
        Button(action: action) {
            HStack(spacing: 10) {
                AgentMark(agent: agent)
                    .frame(width: 14, height: 14)
                    .opacity(lit ? 1 : 0.45)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.name)
                        .font(Type.body)
                        .foregroundStyle(lit ? Ink.primary : Ink.primary.opacity(0.8))
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(Type.secondary)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                RayGlyph(slot: slot, color: MarkPalette.color(for: agent))
                    .opacity(lit || hovering || keyed ? 1 : 0.5)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 40)
            .opacity(full ? 0.45 : 1)
            .background(hovering || keyed ? Surface.hover : .clear, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(full)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: lit)
        .help(full ? "The mark has six rays; let one go first" : lit ? "Stop sending work to \(option.name)" : "Send work to \(option.name)")
        .accessibilityLabel(option.name)
        .accessibilityValue(lit ? "Ray" : "Not a ray")
        .accessibilityHint(full ? "The mark has six rays; let one go first" : lit ? "Puts the ray out" : "Lights it as a ray")
        .accessibilityAddTraits(lit ? .isSelected : [])
    }
}

/// Every model a ray can be, under its agent, which folds as on the model page. Up and down go
/// over them, Return or Space lights a ray or puts it out, right folds an agent, and left goes back.
struct RayList: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    let back: () -> Void
    @State private var keyed: String?
    @FocusState private var focused: Bool

    static let row: CGFloat = 42
    static let section: CGFloat = 36

    /// The list's height with the agents open that the page has open.
    @MainActor
    static func height(_ model: AppModel, chat: Chat?) -> CGFloat {
        model.rayChoices(for: chat).reduce(16) { sum, entry in
            sum + section + (model.raysOpen.contains(entry.agent.id) ? CGFloat(entry.models.count) * row : 0)
        }
    }

    var body: some View {
        let slots = model.raySlots(for: chat)
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.rayChoices(for: chat), id: \.agent.id) { entry in
                        let open = model.raysOpen.contains(entry.agent.id)
                        AgentSection(agent: entry.agent.id, title: entry.agent.name, open: open, keyed: keyed == "agent:" + entry.agent.id) {
                            fold(entry.agent.id)
                        }
                        .frame(height: Self.section - 2)
                        .id("agent:" + entry.agent.id)
                        if open {
                            ForEach(entry.models) { option in
                                let ref = ModelRef(provider: entry.agent.id, id: option.id)
                                RayRow(option: option, agent: entry.agent.id, slot: slots[ref], keyed: keyed == ref.stored,
                                       full: slots[ref] == nil && slots.count >= RaysMark.rays) { toggle(ref) }
                                    .id(ref.stored)
                            }
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            .onChange(of: keyed) { _, row in
                withAnimation(Motion.move) { reader.scrollTo(row) }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.leftArrow) {
            back()
            return .handled
        }
        .onKeyPress(keys: [.return, .space, .rightArrow]) { press in
            guard let keyed else { return .ignored }
            if keyed.hasPrefix("agent:") {
                fold(String(keyed.dropFirst(6)))
            } else if press.key != .rightArrow {
                toggle(ModelRef(stored: keyed))
            }
            return .handled
        }
    }

    private func toggle(_ ref: ModelRef) {
        withAnimation(Motion.move) { model.setRay(ref, model.raySlots(for: chat)[ref] == nil, for: chat) }
    }

    private func fold(_ agent: String) {
        withAnimation(Motion.move) { model.raysOpen.formSymmetricDifference([agent]) }
    }

    private func move(_ by: Int) -> KeyPress.Result {
        let ids = model.rayChoices(for: chat).flatMap { entry in
            ["agent:" + entry.agent.id]
                + (model.raysOpen.contains(entry.agent.id) ? entry.models.map { ModelRef(provider: entry.agent.id, id: $0.id).stored } : [])
        }
        let at = keyed.flatMap(ids.firstIndex(of:)) ?? -1
        guard ids.indices.contains(at + by) else { return .ignored }
        keyed = ids[at + by]
        return .handled
    }
}

/// The list, built a frame after the page turns rather than in the turn's own frame, where it was
/// most of the work. It's still clear then: what's under the mark rises in 0.1s after the turn.
struct DeferredRayList: View {
    let chat: Chat?
    let back: () -> Void
    @State private var ready = false

    var body: some View {
        if ready {
            RayList(chat: chat, back: back)
        } else {
            // The main queue's next turn, after this frame is laid out and committed; a task
            // started here runs inside the same pass.
            Color.clear
                .onAppear { DispatchQueue.main.async { ready = true } }
        }
    }
}

/// The picker's round button, as Back to Defaults draws it.
struct CircleButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? Ink.primary : Ink.secondary)
                .frame(width: 30, height: 30)
                .background(hovering ? Surface.hover : Surface.card, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
