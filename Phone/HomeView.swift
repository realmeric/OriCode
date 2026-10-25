import Link
import SwiftUI

/// Home: everything on the Mac, each project's threads under its badge, on black. The Mac's mark
/// in the toolbar holds the Mac's name and Unpair; asleep or closed, every mark rests.
struct HomeView: View {
    @Environment(PhoneClient.self) private var store

    private var awake: Bool { store.mac?.state ?? .awake == .awake }

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
        NavigationStack {
            List {
                ForEach(sections, id: \.project?.id) { section in
                    Section {
                        ForEach(section.threads) { thread in
                            ThreadRow(thread: thread, awake: awake)
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
                if store.threads.isEmpty {
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { macMenu }
            }
            .refreshable { await store.fetch() }
            .onAppear { Launch.listShown() }
        }
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
            if let end {
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
