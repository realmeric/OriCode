import Link
import SwiftUI

/// Everything running on the Mac.
struct HomeView: View {
    @Environment(PhoneClient.self) private var store

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.threads.values.sorted { $0.updated > $1.updated }) { thread in
                    Text(thread.title)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { macMenu }
            }
        }
    }

    private var macMenu: some View {
        Menu {
            Text(store.mac?.name ?? "Mac")
            Button("Unpair", role: .destructive) { store.unpair() }
        } label: {
            Mark().frame(width: 22, height: 22)
        }
    }
}
