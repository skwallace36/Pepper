import SwiftUI
import UIKit

// MARK: - Main Screen

struct RenderTrackingView: View {
    @State private var timerCount: Int = 0
    @State private var subtreeToggle: Bool = false
    @State private var forceRenderSeed: Int = 0
    @State private var timer: Timer?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // MARK: - Auto-incrementing counter
                GroupBox("Auto Counter") {
                    VStack(spacing: 8) {
                        Text("Ticks: \(timerCount)")
                            .font(.title2.monospacedDigit())
                            .accessibilityIdentifier("render_timer_count")

                        HStack(spacing: 12) {
                            Button(timer == nil ? "Start" : "Stop") {
                                if timer == nil {
                                    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                                        timerCount += 1
                                    }
                                } else {
                                    timer?.invalidate()
                                    timer = nil
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("render_timer_toggle")

                            Button("Reset") {
                                timer?.invalidate()
                                timer = nil
                                timerCount = 0
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("render_timer_reset")
                        }
                    }
                }

                // MARK: - Subtree toggle
                GroupBox("Subtree Re-render") {
                    VStack(spacing: 8) {
                        Toggle("Toggle State", isOn: $subtreeToggle)
                            .accessibilityIdentifier("render_subtree_toggle")

                        Text("State: \(subtreeToggle ? "ON" : "OFF")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("render_subtree_state")
                    }
                }

                // MARK: - Child views with independent render counts
                GroupBox("Render Isolation") {
                    VStack(spacing: 12) {
                        Text("Only Child A should re-render when toggle changes")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        RenderChildA(flag: subtreeToggle)
                        RenderChildB()
                        RenderChildC()
                    }
                }

                // MARK: - Force re-render
                GroupBox("Force Re-render") {
                    VStack(spacing: 8) {
                        Text("Seed: \(forceRenderSeed)")
                            .font(.caption.monospacedDigit())
                            .accessibilityIdentifier("render_force_seed")

                        Button("Force Re-render") {
                            forceRenderSeed += 1
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("render_force_button")
                    }
                }

                // MARK: - Expensive view
                GroupBox("Expensive View") {
                    ExpensiveView(seed: forceRenderSeed)
                }

                // MARK: - UIKit embedded view
                GroupBox("UIKit Render Surface") {
                    UIKitRenderCountView()
                        .frame(height: 80)
                        .accessibilityIdentifier("render_uikit_surface")
                }
            }
            .padding()
        }
        .navigationTitle("Render Tracking")
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

// MARK: - Child Views with Render Counters

struct RenderChildA: View {
    let flag: Bool
    @State private var renderCount: Int = 0

    var body: some View {
        let _ = incrementRenderCount()
        HStack {
            Text("Child A (reactive)")
                .font(.subheadline)
            Spacer()
            Text("renders: \(renderCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("render_child_a_count")
        }
        .padding(8)
        .background(flag ? Color.green.opacity(0.1) : Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("render_child_a")
    }

    private func incrementRenderCount() {
        DispatchQueue.main.async { renderCount += 1 }
    }
}

struct RenderChildB: View {
    @State private var renderCount: Int = 0

    var body: some View {
        let _ = incrementRenderCount()
        HStack {
            Text("Child B (isolated)")
                .font(.subheadline)
            Spacer()
            Text("renders: \(renderCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("render_child_b_count")
        }
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("render_child_b")
    }

    private func incrementRenderCount() {
        DispatchQueue.main.async { renderCount += 1 }
    }
}

struct RenderChildC: View {
    @State private var renderCount: Int = 0
    @State private var localState: Bool = false

    var body: some View {
        let _ = incrementRenderCount()
        HStack {
            Text("Child C (local state)")
                .font(.subheadline)
            Spacer()
            Button(localState ? "On" : "Off") {
                localState.toggle()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("render_child_c_toggle")
            Text("renders: \(renderCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("render_child_c_count")
        }
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("render_child_c")
    }

    private func incrementRenderCount() {
        DispatchQueue.main.async { renderCount += 1 }
    }
}

// MARK: - Expensive View (intentionally inefficient for `renders why`)

struct ExpensiveView: View {
    let seed: Int
    @State private var renderCount: Int = 0

    var body: some View {
        let _ = incrementRenderCount()
        // Intentionally expensive: sort a large array on every render
        let _ = (0..<5000).map { Int.random(in: 0..<10000) }.sorted()
        let _ = (1...1000).reduce(0, +)

        VStack(spacing: 4) {
            Text("Expensive computation on every render")
                .font(.caption)
                .foregroundStyle(.orange)
            Text("renders: \(renderCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("render_expensive_count")
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("render_expensive_view")
    }

    private func incrementRenderCount() {
        DispatchQueue.main.async { renderCount += 1 }
    }
}

// MARK: - UIKit Render Surface (UIViewRepresentable)

struct UIKitRenderCountView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIKitRenderTrackingUIView {
        UIKitRenderTrackingUIView()
    }

    func updateUIView(_ uiView: UIKitRenderTrackingUIView, context: Context) {
        uiView.recordUpdate()
    }
}

final class UIKitRenderTrackingUIView: UIView {
    private var updateCount: Int = 0
    private let countLabel = UILabel()
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 8

        titleLabel.text = "UIKit Surface"
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.accessibilityIdentifier = "render_uikit_title"

        countLabel.text = "updates: 0"
        countLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countLabel.textColor = .secondaryLabel
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.accessibilityIdentifier = "render_uikit_update_count"

        addSubview(titleLabel)
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            countLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func recordUpdate() {
        updateCount += 1
        countLabel.text = "updates: \(updateCount)"
    }
}
