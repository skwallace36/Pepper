import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Controls", systemImage: "slider.horizontal.3") {
                NavigationStack {
                    ControlsView()
                }
            }

            Tab("List", systemImage: "list.bullet") {
                NavigationStack {
                    ListTab()
                }
            }

            Tab("Misc", systemImage: "ellipsis.circle") {
                NavigationStack {
                    MiscTab()
                }
            }
        }
    }
}
