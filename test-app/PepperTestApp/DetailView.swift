import SwiftUI

struct DetailView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 20) {
            Text("Detail Screen")
                .font(.title)
                .accessibilityIdentifier("detail_title")

            Text("Total taps: \(state.totalTaps)")
                .accessibilityIdentifier("detail_total_label")

            NavigationLink("Push Deeper") {
                DeeperView()
            }
            .accessibilityIdentifier("push_deeper_link")
        }
        .navigationTitle("Detail")
    }
}

struct DeeperView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 20) {
            Text("Deepest Screen")
                .font(.title)
                .accessibilityIdentifier("deeper_title")

            Text("Nav stack is 3 levels deep")
                .accessibilityIdentifier("deeper_label")

            Button("Tap from the deep") {
                state.incrementTap()
            }
            .accessibilityIdentifier("deep_tap_button")
        }
        .navigationTitle("Deeper")
    }
}
