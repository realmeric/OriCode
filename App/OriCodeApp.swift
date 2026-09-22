import SwiftUI

@main
struct OriCodeApp: App {
    var body: some Scene {
        Window("OriCode", id: "main") {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        Color.clear
            .frame(minWidth: 720, minHeight: 480)
    }
}
