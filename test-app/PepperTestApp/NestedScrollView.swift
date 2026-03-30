import SwiftUI

struct NestedScrollView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // MARK: - Header content
                GroupBox("Nested Scroll Test") {
                    Text("This screen tests nested horizontal ScrollViews inside a vertical ScrollView. Scroll horizontally within each row without affecting the outer vertical scroll.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("nested_scroll_description")
                }

                // MARK: - First horizontal scroll (Quick Actions)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Actions")
                        .font(.headline)
                        .accessibilityIdentifier("quick_actions_header")

                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 12) {
                            ForEach(1...10, id: \.self) { index in
                                VStack(spacing: 6) {
                                    Image(systemName: "bolt.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                        .frame(width: 56, height: 56)
                                        .background(
                                            [Color.blue, .green, .orange, .purple, .red,
                                             .teal, .indigo, .mint, .pink, .cyan][index - 1]
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 12))

                                    Text("Action \(index)")
                                        .font(.caption)
                                }
                                .accessibilityIdentifier("action_item_\(index)")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("quick_actions_scroll")
                }

                // MARK: - Spacer content between scrolls
                GroupBox("Middle Content") {
                    VStack(spacing: 8) {
                        Text("Static content between the two horizontal scroll areas.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            ForEach(["star.fill", "heart.fill", "flag.fill"], id: \.self) { icon in
                                Image(systemName: icon)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("middle_content")
                }

                // MARK: - Second horizontal scroll (Categories)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Categories")
                        .font(.headline)
                        .accessibilityIdentifier("categories_header")

                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 12) {
                            ForEach(1...10, id: \.self) { index in
                                VStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(
                                            [Color.red, .orange, .yellow, .green, .blue,
                                             .purple, .pink, .teal, .indigo, .mint][index - 1]
                                                .opacity(0.3)
                                        )
                                        .frame(width: 100, height: 60)
                                        .overlay(
                                            Text("Cat \(index)")
                                                .font(.caption.bold())
                                        )

                                    Text("Category \(index)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityIdentifier("category_item_\(index)")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("categories_scroll")
                }

                // MARK: - Bottom padding content
                GroupBox("Bottom Content") {
                    Text("Content below both horizontal scrolls to ensure the outer vertical scroll is long enough to require scrolling.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("bottom_content")
                }
            }
            .padding()
        }
        .navigationTitle("Nested Scroll")
        .accessibilityIdentifier("nested_scroll_view")
    }
}
