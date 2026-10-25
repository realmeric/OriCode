import SwiftUI

/// Home: what's been handed out today, one capsule a thread, newest at the top, over the composer,
/// which starts the next. A send from here starts a thread and stays here (Meriç, 2026-10-25:
/// "gönderdiğinde bu ekranda bir kapsül açıyor, o kapsül thread'i bir işi temsil ediyor").
/// The work a thread set going hangs under its capsule on a bracket while it works, and goes
/// when it's done: the thread opened shows all of it. It reads what the app
/// already holds and asks the engine for nothing.
struct HomeBoard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HomeLayout.unitGap) {
                ForEach(model.homeCapsules, id: \.id) { chat in
                    VStack(alignment: .leading, spacing: HomeLayout.kidGap) {
                        HomeCapsule(chat: chat)
                        let kids = model.homeKids(of: chat)
                        if !kids.isEmpty {
                            VStack(alignment: .leading, spacing: HomeLayout.kidGap) {
                                ForEach(Array(kids.enumerated()), id: \.element.id) { place, kid in
                                    HomeKid(chat: kid, last: place == kids.count - 1)
                                }
                            }
                            .padding(.leading, HomeLayout.indent)
                        }
                    }
                }
            }
            .padding(.top, HomeLayout.top)
            .padding(.bottom, 12)
            .column()
        }
        .scrollIndicators(.never)
        // Capsules go under the window's top and the composer's glass fading, never cut.
        .clipped()
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: HomeLayout.top)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 16)
            }
        }
    }
}

/// The board's measures, from the design (scratch/design051/split): a title in a column of its
/// own so every step starts at one x, a child's label shortened by its indent.
enum HomeLayout {
    static let top: CGFloat = 52
    static let unitGap: CGFloat = 6
    static let kidGap: CGFloat = 4
    static let indent: CGFloat = 32
    static let capsuleHeight: CGFloat = 34
    static let kidHeight: CGFloat = 26
    static let titleColumn: CGFloat = 180
    /// Where a capsule's title starts, and an ask on it.
    static let titleStart: CGFloat = 66
    /// Under a capsule's mark, where its bracket leaves from: 14 + half a 14pt mark.
    static let markCentre: CGFloat = 21
    /// A capsule's title starts 66pt in (14 + a 14pt mark + 8 + its project's 22pt badge + 8), a
    /// child's label 29 past its indent (10 + a 12pt mark + 7), so this takes off what the child's start adds.
    static var kidColumn: CGFloat { titleColumn - indent + 37 }
}

/// One thread on home: its mark, its few words, the step it's on in faint ink, a workflow's
/// phases at its end, and once over the first line of its reply. A click opens it.
private struct HomeCapsule: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    @State private var hovered = false

    var body: some View {
        let status = model.status(of: chat)
        let done = status.state == .done || status.state == .idle
        // What waits on Meriç in this thread or under it, answered right here (Meriç, 2026-10-25:
        // "izin vermem gerekip gerekmediği homeda yazmıyor, içine girince fark ediyosun").
        let asks = model.homeAsks(of: chat)
        let shape = RoundedRectangle(cornerRadius: HomeLayout.capsuleHeight / 2, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.open(chatID: chat.id)
            } label: {
                HStack(spacing: 8) {
                    HomeMark(chat: chat, size: 14)
                    // The drawer's badge, so the project reads at a glance (Meriç, 2026-10-25).
                    if let project = chat.project { ProjectBadge(project: project) }
                    Text(chat.title)
                        .font(.system(size: 13))
                        .foregroundStyle(done ? Ink.secondary : Ink.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: HomeLayout.titleColumn, alignment: .leading)
                    Text(asks.isEmpty ? line(status) ?? "" : "")
                        .font(.system(size: 12))
                        .foregroundStyle(done ? Ink.secondary.opacity(0.8) : Ink.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let phases = model.homePhases(of: chat) {
                        HomePhases(phases: phases)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 14)
                .frame(height: HomeLayout.capsuleHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(chat.title)
            .accessibilityValue(line(status) ?? status.word)
            ForEach(asks) { waiting in
                AskForm(ask: waiting.ask, cwd: waiting.holder.cwd, thread: waiting.holder.id, listens: false, compact: true)
                    .padding(.leading, HomeLayout.titleStart)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
            }
        }
        .background(shape.fill(Color.white.opacity(hovered ? 0.08 : !asks.isEmpty ? 0.07 : done ? 0.035 : 0.05)))
        .onHover { hovered = $0 }
        // What the drawer's row offers, here too.
        .contextMenu {
            Button("Open Beside") { model.openBeside(chat) }
            Button("Rename") { model.open(chatID: chat.id); model.startRename(chat) }
            Button("Archive") { withAnimation(Motion.move) { model.archive(chat) } }
            Button("Delete…") { model.askToDelete(chat) }
        }
        .animation(Motion.fade, value: asks.map(\.id))
    }

    /// What the capsule says after its title: the step at work, or once over its reply's first line.
    private func line(_ status: OverviewStatus) -> String? {
        if let step = status.step { return step }
        if status.state == .done || status.state == .idle { return model.outcomes[chat.id]?.line }
        return nil
    }
}

/// Work a thread set going, under its capsule: a workflow's agent, a subagent, a worker, a thread
/// it opened or ran for its plan. The bracket leaves from under the parent's mark.
private struct HomeKid: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    let last: Bool
    @State private var hovered = false

    var body: some View {
        let status = model.status(of: chat)
        let working = chat.agentWorking || status.live
        Button {
            model.open(chatID: chat.id)
        } label: {
            HStack(spacing: 7) {
                HomeMark(chat: chat, size: 12)
                Text(chat.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(working ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: HomeLayout.kidColumn, alignment: .leading)
                Text(working ? (status.step ?? "") : "")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: HomeLayout.kidHeight)
            .background(Capsule().fill(Color.white.opacity(hovered ? 0.07 : working ? 0.05 : 0.035)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .background(alignment: .topLeading) { Bracket(last: last) }
        .accessibilityLabel(chat.title)
    }
}

/// The bracket's piece for one child: down from the row above to this row's middle, and on down
/// to the next unless it's the last.
private struct Bracket: View {
    let last: Bool

    var body: some View {
        Canvas { context, size in
            let x: CGFloat = 0.75
            let middle = size.height / 2 + HomeLayout.kidGap
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: middle - 6))
            path.addQuadCurve(to: CGPoint(x: x + 6, y: middle), control: CGPoint(x: x, y: middle))
            path.addLine(to: CGPoint(x: HomeLayout.indent - HomeLayout.markCentre - 4, y: middle))
            if !last {
                path.move(to: CGPoint(x: x, y: middle - 6))
                path.addLine(to: CGPoint(x: x, y: size.height + HomeLayout.kidGap * 2))
            }
            context.stroke(path, with: .color(.white.opacity(0.2)), lineWidth: 1.5)
        }
        .frame(width: HomeLayout.indent - HomeLayout.markCentre, height: HomeLayout.kidHeight)
        .offset(x: HomeLayout.markCentre - HomeLayout.indent, y: -HomeLayout.kidGap)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A thread's mark on home: lit while it works, pulsing while it asks, at rest once over. A
/// thread not in memory is at rest.
private struct HomeMark: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    let size: CGFloat

    var body: some View {
        Group {
            if let conversation = model.conversations[chat.id] {
                ThreadMark(conversation: conversation, moving: true)
            } else {
                RaysMark(slots: [], turning: false, restingOpacity: 0.28, dotOpacity: chat.agentWorking ? 0.92 : 0.28)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A workflow's phases at its capsule's end: done, at work, not reached.
private struct HomePhases: View {
    let phases: [StageLayout.State]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(phases.enumerated()), id: \.offset) { _, state in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(state == .live ? 0.92 : state == .finished ? 0.55 : 0.14))
                    .frame(width: 14, height: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

extension AppModel {
    /// Home and the stage are a preview in 0.5.0, off unless turned on in Settings › General
    /// (Meriç, 2026-10-25: 0.5.0 ships what's certain; these go on in 0.6.0).
    nonisolated static let previewKey = "previewHome"
    /// Off under test, whatever the test host's own defaults say: the test host is Molten, whose
    /// preview Meriç keeps on.
    nonisolated static var preview: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil && UserDefaults.standard.bool(forKey: previewKey)
    }

    /// The threads home shows: every project's top threads at work, or worked on today, a
    /// project's together, the project with the newest first and its newest first (Meriç,
    /// 2026-10-25: "yeni threadler her zaman üstte olmalı", "aynı proje threadleri yan yana").
    var homeCapsules: [Chat] {
        let all = projects.flatMap(\.chats).filter { $0.started && !$0.archived }
        let tops = topThreads
        let today = Calendar.current
        let shown = all.filter { chat in
            guard tops[chat.id] == chat.id else { return false }
            if conversations[chat.id]?.working == true || chat.agentWorking { return true }
            return today.isDateInToday(chat.updatedAt)
        }
        .sorted { $0.createdAt > $1.createdAt }
        var order: [UUID] = []
        for chat in shown { if let id = chat.project?.id, !order.contains(id) { order.append(id) } }
        return shown.sorted { a, b in
            let pa = a.project.flatMap { order.firstIndex(of: $0.id) } ?? 0, pb = b.project.flatMap { order.firstIndex(of: $0.id) } ?? 0
            return pa == pb ? a.createdAt > b.createdAt : pa < pb
        }
    }

    /// The asks waiting on Meriç in a thread on home or in the work under it, oldest first.
    func homeAsks(of chat: Chat) -> [WaitingAsk] {
        let tops = topThreads
        return waitingAsks.filter { (tops[$0.holder.id] ?? $0.holder.id) == chat.id || $0.holder.openedBy.map { tops[$0] == chat.id } == true }
    }

    /// The threads under one on home that are at work now, in the order they started. Done, they
    /// go (Meriç, 2026-10-25: "alt threadler her zaman görünür duruyor, durmamalı").
    func homeKids(of chat: Chat) -> [Chat] {
        threads(under: chat)
            .filter { !$0.archived && ($0.agentWorking || conversations[$0.id]?.working == true) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// A live workflow's phases in its order, each done, at work or not reached; nil with none.
    func homePhases(of chat: Chat) -> [StageLayout.State]? {
        guard let run = conversations[chat.id]?.heads.liveWorkflow?.run, !run.phases.isEmpty else { return nil }
        return run.phases.map { phase in
            let agents = run.agents.filter { $0.phase == phase }
            if agents.isEmpty { return .ahead }
            return agents.allSatisfy { $0.state == .done || $0.state == .failed } ? .finished : .live
        }
    }

    /// Esc with a thread open and nothing over it goes home.
    func goHome() {
        selectedChatID = nil
    }
}
