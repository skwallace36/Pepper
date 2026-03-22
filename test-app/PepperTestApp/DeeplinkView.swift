import SwiftUI

struct DeeplinkView: View {
    let route: String
    let params: [String: String]

    var body: some View {
        VStack(spacing: 16) {
            Text("Deeplink Received")
                .font(.title)
                .accessibilityIdentifier("deeplink_title")

            Text("Route: \(route)")
                .accessibilityIdentifier("deeplink_route")

            if !params.isEmpty {
                ForEach(Array(params.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                    Text("\(key) = \(value)")
                }
                .accessibilityIdentifier("deeplink_params")
            }
        }
        .navigationTitle("Deeplink")
    }
}
