import SwiftUI

// MARK: - Slow Body View

/// A SwiftUI view that deliberately takes >10us in its `body` property,
/// providing a test surface for Pepper's swiftui_body (body_track) command.
struct SlowBodyView: View {
    @State private var counter: Int = 0
    @State private var slowness: SlownessLevel = .medium

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                GroupBox("Slow Body Evaluation") {
                    VStack(spacing: 12) {
                        Text("This view's child deliberately stalls during body evaluation so swiftui_body can measure it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Picker("Slowness", selection: $slowness) {
                            ForEach(SlownessLevel.allCases) { level in
                                Text(level.label).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("slowness_picker")

                        Button("Trigger Re-render") {
                            counter += 1
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("trigger_rerender_button")

                        Text("Renders: \(counter)")
                            .font(.caption.monospacedDigit())
                            .accessibilityIdentifier("slow_body_render_count")
                    }
                }

                GroupBox("Slow Child View") {
                    SlowChildView(seed: counter, slowness: slowness)
                }

                GroupBox("Usage") {
                    VStack(spacing: 8) {
                        Text("swiftui_body start \u{2192} tap Trigger \u{2192} swiftui_body log")
                            .font(.caption.monospaced())
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .accessibilityIdentifier("slow_body_hint")

                        Text("Look for SlowChildView with duration > 10us in the log output.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Slow Body")
    }
}

// MARK: - Slowness Level

enum SlownessLevel: String, CaseIterable, Identifiable {
    case light
    case medium
    case heavy

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var microseconds: useconds_t {
        switch self {
        case .light: 50
        case .medium: 500
        case .heavy: 5_000
        }
    }
}

// MARK: - Slow Child View

/// The actual slow view — body evaluation includes a usleep call.
struct SlowChildView: View {
    let seed: Int
    let slowness: SlownessLevel

    var body: some View {
        // Deliberately slow: this is what swiftui_body will measure
        let _ = usleep(slowness.microseconds)

        VStack(spacing: 8) {
            Text("SlowChildView")
                .font(.headline)
                .accessibilityIdentifier("slow_child_title")

            Text("Seed: \(seed) | Delay: \(slowness.microseconds)us")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("slow_child_info")

            // Additional content to make the view non-trivial
            HStack(spacing: 8) {
                ForEach(0..<5) { i in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hue: Double(i) / 5.0, saturation: 0.6, brightness: 0.9))
                        .frame(width: 40, height: 40)
                        .accessibilityIdentifier("slow_child_block_\(i)")
                }
            }
        }
        .padding()
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("slow_child_view")
    }
}
