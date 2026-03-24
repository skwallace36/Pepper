import SwiftUI
import UIKit

// MARK: - Adjustable Stepper

/// A UIView with the .adjustable accessibility trait. Responds to
/// `accessibility_action increment` / `accessibility_action decrement`.
final class AdjustableStepperUIView: UIView {
    private let valueLabel = UILabel()
    private(set) var value: Int = 5 {
        didSet { valueLabel.text = "\(value) / 10" }
    }

    var onValueChanged: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .systemBlue.withAlphaComponent(0.1)
        layer.cornerRadius = 10

        valueLabel.text = "\(value) / 10"
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        valueLabel.textAlignment = .center
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        isAccessibilityElement = true
        accessibilityIdentifier = "adjustable_stepper"
        accessibilityLabel = "Custom Stepper"
        accessibilityTraits = .adjustable
    }

    override var accessibilityValue: String? {
        get { "\(value)" }
        set { }
    }

    override func accessibilityIncrement() {
        value = min(10, value + 1)
        onValueChanged?(value)
        print("[PepperTest] A11y: incremented to \(value)")
    }

    override func accessibilityDecrement() {
        value = max(0, value - 1)
        onValueChanged?(value)
        print("[PepperTest] A11y: decremented to \(value)")
    }
}

struct AdjustableStepperView: UIViewRepresentable {
    @Binding var value: Int

    func makeUIView(context: Context) -> AdjustableStepperUIView {
        let view = AdjustableStepperUIView()
        view.onValueChanged = { newValue in
            DispatchQueue.main.async { value = newValue }
        }
        return view
    }

    func updateUIView(_ uiView: AdjustableStepperUIView, context: Context) {}
}

// MARK: - Custom Actions Card

/// A UIView with named accessibility custom actions.
/// Responds to `accessibility_action invoke name="Mark as Read"` / `name="Archive"`.
final class CustomActionsUIView: UIView {
    private let statusLabel = UILabel()
    var onActionInvoked: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .systemGreen.withAlphaComponent(0.1)
        layer.cornerRadius = 10

        let titleLabel = UILabel()
        titleLabel.text = "Inbox Item"
        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        statusLabel.text = "Last: none"
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
        ])

        isAccessibilityElement = true
        accessibilityIdentifier = "custom_actions_card"
        accessibilityLabel = "Inbox Item"
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Mark as Read") { [weak self] _ in
                self?.handleAction("Mark as Read"); return true
            },
            UIAccessibilityCustomAction(name: "Archive") { [weak self] _ in
                self?.handleAction("Archive"); return true
            },
        ]
    }

    private func handleAction(_ name: String) {
        statusLabel.text = "Last: \(name)"
        accessibilityValue = name
        onActionInvoked?(name)
        print("[PepperTest] A11y: custom action '\(name)' invoked")
    }
}

struct CustomActionsCardView: UIViewRepresentable {
    @Binding var lastAction: String

    func makeUIView(context: Context) -> CustomActionsUIView {
        let view = CustomActionsUIView()
        view.onActionInvoked = { action in
            DispatchQueue.main.async { lastAction = action }
        }
        return view
    }

    func updateUIView(_ uiView: CustomActionsUIView, context: Context) {}
}

// MARK: - Magic Tap Target

/// A UIView that handles `accessibilityPerformMagicTap()`.
/// Responds to `accessibility_action magic_tap element=magic_tap_target`.
final class MagicTapUIView: UIView {
    private let statusLabel = UILabel()
    var onMagicTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .systemPurple.withAlphaComponent(0.1)
        layer.cornerRadius = 10

        let titleLabel = UILabel()
        titleLabel.text = "Magic Tap Target"
        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        statusLabel.text = "not triggered"
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
        ])

        isAccessibilityElement = true
        accessibilityIdentifier = "magic_tap_target"
        accessibilityLabel = "Magic Tap Target"
        accessibilityValue = "not triggered"
    }

    override func accessibilityPerformMagicTap() -> Bool {
        statusLabel.text = "triggered"
        accessibilityValue = "triggered"
        onMagicTap?()
        print("[PepperTest] A11y: magic tap triggered")
        return true
    }
}

struct MagicTapTargetView: UIViewRepresentable {
    @Binding var triggered: Bool

    func makeUIView(context: Context) -> MagicTapUIView {
        let view = MagicTapUIView()
        view.onMagicTap = {
            DispatchQueue.main.async { triggered = true }
        }
        return view
    }

    func updateUIView(_ uiView: MagicTapUIView, context: Context) {}
}
