import SwiftUI

struct ContentView: View {
    @Binding var selectedTab: String

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Controls", systemImage: "slider.horizontal.3", value: "controls") {
                NavigationStack {
                    ControlsView()
                }
            }

            Tab("List", systemImage: "list.bullet", value: "list") {
                NavigationStack {
                    ListTab()
                }
            }

            Tab("Misc", systemImage: "ellipsis.circle", value: "misc") {
                NavigationStack {
                    MiscTab()
                }
            }
        }
    }
}
