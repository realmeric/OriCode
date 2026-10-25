import Link
import SwiftUI

/// Home: everything on the Mac, each project's threads under its badge, on black. The Mac's mark
/// in the toolbar holds the Mac's name and Unpair; asleep or closed, every mark rests.
struct HomeView: View {
    @Environment(PhoneClient.self) private var store
    @Environment(Router.self) private var router
    @State private var stops = 0

    private var awake: Bool { store.mac?.state ?? .awake == .awake }

    /// Every ask, oldest first, as the Mac's queue orders them.
    private var asks: [AskInfo] {
        store.asks.values.sorted { ($0.asked, $0.id) < ($1.asked, $1.id) }
    }

    /// Projects with threads, in the Mac's order; in each, a thread asking first, then those at
    /// work, then the latest.
    private var sections: [(project: ProjectInfo?, threads: [ThreadInfo])] {
        let grouped = Dictionary(grouping: store.threads.values, by: \.project)
        return grouped.map { (store.projects[$0.key], $0.value.sorted(by: Self.order)) }
            .sorted { ($0.project?.order ?? .max) < ($1.project?.order ?? .max) }
    }

    private static func order(_ a: ThreadInfo, _ b: ThreadInfo) -> Bool {
        func rank(_ thread: ThreadInfo) -> Int {
            switch thread.status {
            case .asking: 0
            case .working: 1
            default: 2
            }
        }
        return rank(a) != rank(b) ? rank(a) < rank(b) : a.updated > b.updated
    }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            List {
                if !asks.isEmpty {
                    Section {
                        ForEach(asks) { ask in
                            AskCard(ask: ask)
                                .listRowBackground(Color.black)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                    } header: {
                        Text("\(asks.count) waiting on you")
                            .font(.subheadline)
                            .foregroundStyle(Ink.secondary)
                            .textCase(nil)
                    }
                }
                ForEach(sections, id: \.project?.id) { section in
                    Section {
                        ForEach(section.threads) { thread in
                            ThreadRow(thread: thread, awake: awake, undelivered: store.stopSent(for: thread.id)?.undelivered() == true)
                                .contentShape(.rect)
                                .onTapGesture { router.path.append(thread.id) }
                                .swipeActions(edge: .trailing) {
                                    if thread.status == .working || thread.status == .asking {
                                        Button("Stop", role: .destructive) { stop(thread) }
                                    }
                                }
                                .contextMenu {
                                    if thread.status == .working || thread.status == .asking {
                                        Button("Stop", systemImage: "stop.fill", role: .destructive) { stop(thread) }
                                    }
                                }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Badge(project: section.project)
                            Text(section.project?.name ?? "")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(awake ? Ink.secondary : Ink.faint)
                        }
                        .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .overlay {
                if store.threads.isEmpty && store.asks.isEmpty {
                    VStack(spacing: 14) {
                        Mark(restingOpacity: awake ? 0.3 : 0.15)
                            .opacity(awake ? 1 : 0.3)
                            .frame(width: 44, height: 44)
                        Text("Nothing running")
                            .font(.subheadline)
                            .foregroundStyle(Ink.faint)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { ThreadView(id: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { macMenu }
            }
            .refreshable { await store.fetch() }
            .onAppear { Launch.listShown() }
            .sensoryFeedback(.impact(weight: .light), trigger: stops)
        }
    }

    private func stop(_ thread: ThreadInfo) {
        if let old = store.stopSent(for: thread.id) { store.clear(old.id) }
        store.send(.stop(thread: thread.id))
        stops += 1
    }

    private var macMenu: some View {
        Menu {
            Section(macLine) {
                Button("Unpair", role: .destructive) { store.unpair() }
            }
        } label: {
            Mark(dotOpacity: 1, restingOpacity: 0.55)
                .opacity(awake ? 1 : 0.3)
                .frame(width: 22, height: 22)
        }
    }

    /// The only place the Mac's state is written.
    private var macLine: String {
        let name = store.mac?.name ?? "Mac"
        switch store.mac?.state {
        case .asleep: return "\(name) · Asleep"
        case .closed: return "\(name) · Closed"
        default: return name
        }
    }
}

/// A thread's row: its mark, its title, what it's on in faint ink, and Stopped or Failed at the end.
struct ThreadRow: View {
    let thread: ThreadInfo
    let awake: Bool
    /// A Stop the Mac refused or never took.
    var undelivered = false

    var body: some View {
        HStack(spacing: 12) {
            ThreadMark(thread: thread, awake: awake)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title)
                    .font(.body)
                    .foregroundStyle(awake ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
                if awake, let step = thread.step, thread.status == .working {
                    Text(step)
                        .font(.footnote)
                        .foregroundStyle(Ink.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if undelivered {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Ink.red)
            } else if let end {
                Text(end)
                    .font(.footnote)
                    .foregroundStyle(Ink.secondary)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(Color.black)
        .listRowSeparator(.hidden)
    }

    private var end: String? {
        switch thread.status {
        case .stopped: "Stopped"
        case .failed: "Failed"
        default: nil
        }
    }
}
