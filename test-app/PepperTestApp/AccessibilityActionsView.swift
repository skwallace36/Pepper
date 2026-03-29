import SwiftUI
import UIKit

// MARK: - SwiftUI Wrapper

struct AccessibilityActionsWrapper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AccessibilityActionsViewController {
        AccessibilityActionsViewController()
    }

    func updateUIViewController(_ vc: AccessibilityActionsViewController, context: Context) {}
}

// MARK: - View Controller

/// Surfaces for `accessibility_action` command testing.
/// Provides adjustable, custom-action, and magic-tap elements.
final class AccessibilityActionsViewController: UIViewController {

    private let magicTapLabel = UILabel()
    private let adjustableView = AdjustableCounterView()
    private let customActionView = CustomActionTargetView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Accessibility Actions"
        view.backgroundColor = .systemBackground
        buildUI()
    }

    // MARK: - Magic Tap

    override func accessibilityPerformMagicTap() -> Bool {
        magicTapLabel.text = "Magic tap: triggered"
        magicTapLabel.textColor = .systemGreen
        print("[PepperTest] Magic tap performed")
        return true
    }

    // MARK: - UI

    private func buildUI() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 24
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 1. Adjustable element
        stack.addArrangedSubview(makeSectionLabel("Adjustable Element"))
        adjustableView.accessibilityIdentifier = "a11y_adjustable"
        adjustableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            adjustableView.heightAnchor.constraint(equalToConstant: 60),
        ])
        stack.addArrangedSubview(adjustableView)

        // 2. Custom actions element
        stack.addArrangedSubview(makeSectionLabel("Custom Actions"))
        customActionView.accessibilityIdentifier = "a11y_custom_actions"
        customActionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            customActionView.heightAnchor.constraint(equalToConstant: 60),
        ])
        stack.addArrangedSubview(customActionView)

        // 3. Magic tap
        stack.addArrangedSubview(makeSectionLabel("Magic Tap"))

        let magicTapHint = UILabel()
        magicTapHint.text = "Two-finger double-tap (or use accessibility_action magic_tap)"
        magicTapHint.font = UIFont.preferredFont(forTextStyle: .caption1)
        magicTapHint.textColor = .secondaryLabel
        magicTapHint.adjustsFontForContentSizeCategory = true
        magicTapHint.numberOfLines = 0
        stack.addArrangedSubview(magicTapHint)

        magicTapLabel.text = "Magic tap: waiting"
        magicTapLabel.font = UIFont.preferredFont(forTextStyle: .body)
        magicTapLabel.textColor = .label
        magicTapLabel.adjustsFontForContentSizeCategory = true
        magicTapLabel.accessibilityIdentifier = "a11y_magic_tap_status"
        stack.addArrangedSubview(magicTapLabel)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])
    }

    private func makeSectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.textColor = .label
        label.adjustsFontForContentSizeCategory = true
        return label
    }
}

// MARK: - Adjustable Counter View

/// A custom view with the `.adjustable` accessibility trait.
/// Increment/decrement changes the displayed counter value.
final class AdjustableCounterView: UIView {

    private var counter = 5
    private let valueLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 10

        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = "Counter"
        updateAccessibilityValue()

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)
        valueLabel.textAlignment = .center
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)

        let hint = UILabel()
        hint.text = "Adjustable (increment / decrement)"
        hint.font = UIFont.preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabel
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)

        NSLayoutConstraint.activate([
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 2),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])

        refreshLabel()
    }

    override func accessibilityIncrement() {
        counter += 1
        refreshLabel()
        print("[PepperTest] Adjustable increment: \(counter)")
    }

    override func accessibilityDecrement() {
        counter -= 1
        refreshLabel()
        print("[PepperTest] Adjustable decrement: \(counter)")
    }

    private func refreshLabel() {
        valueLabel.text = "Value: \(counter)"
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        accessibilityValue = "\(counter)"
    }
}

// MARK: - Custom Action Target View

/// A view with named custom accessibility actions.
/// Shows which action was last invoked.
final class CustomActionTargetView: UIView {

    private let statusLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 10

        isAccessibilityElement = true
        accessibilityLabel = "Message item"

        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Mark as Read") { [weak self] _ in
                self?.didInvoke("Mark as Read")
                return true
            },
            UIAccessibilityCustomAction(name: "Archive") { [weak self] _ in
                self?.didInvoke("Archive")
                return true
            },
        ]

        statusLabel.text = "Last action: none"
        statusLabel.font = UIFont.preferredFont(forTextStyle: .body)
        statusLabel.textAlignment = .center
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.accessibilityIdentifier = "a11y_custom_action_status"
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    private func didInvoke(_ name: String) {
        statusLabel.text = "Last action: \(name)"
        print("[PepperTest] Custom action invoked: \(name)")
    }
}
