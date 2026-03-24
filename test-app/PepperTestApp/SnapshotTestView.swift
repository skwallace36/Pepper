import SwiftUI

struct SnapshotTestView: View {
    @State private var counter: Int = 0
    @State private var isDarkStyle: Bool = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("\(counter)")
                .font(.system(size: 80, weight: .bold, design: .monospaced))
                .foregroundStyle(isDarkStyle ? Color.yellow : Color.blue)
                .accessibilityIdentifier("snapshot_counter")

            Text("Counter: \(counter), Style: \(isDarkStyle ? "dark" : "light")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("snapshot_status")

            VStack(spacing: 12) {
                Button("Increment") {
                    counter += 1
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("snapshot_increment_button")

                Button("Reset") {
                    counter = 0
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("snapshot_reset_button")

                Button("Toggle Style") {
                    isDarkStyle.toggle()
                }
                .buttonStyle(.bordered)
                .tint(isDarkStyle ? .yellow : .blue)
                .accessibilityIdentifier("snapshot_toggle_style_button")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDarkStyle ? Color.black : Color.white)
        .navigationTitle("Snapshot Test")
    }
}
