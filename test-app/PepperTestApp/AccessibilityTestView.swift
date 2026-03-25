import SwiftUI
import UIKit

// MARK: - SwiftUI Wrapper

struct AccessibilityTestWrapper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AccessibilityTestViewController {
        AccessibilityTestViewController()
    }

    func updateUIViewController(_ vc: AccessibilityTestViewController, context: Context) {}
}

// MARK: - View Controller

/// Intentional accessibility violations for `accessibility_audit` testing.
/// Each element triggers a specific audit check. IDs prefixed with `a11y_`.
final class AccessibilityTestViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Accessibility Test"
        view.backgroundColor = .systemBackground
        buildUI()
    }

    private func buildUI() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 24
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(makeSectionLabel("Violations"))

        // 1. Tiny button (30x30pt) — triggers touch_target
        let tinyButton = UIButton(type: .system)
        tinyButton.setTitle("Tiny", for: .normal)
        tinyButton.accessibilityIdentifier = "a11y_tiny_button"
        tinyButton.translatesAutoresizingMaskIntoConstraints = false
        tinyButton.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
        let tinyRow = makeRow("1. Tiny button (30x30pt) — touch_target", tinyButton)
        NSLayoutConstraint.activate([
            tinyButton.widthAnchor.constraint(equalToConstant: 30),
            tinyButton.heightAnchor.constraint(equalToConstant: 30),
        ])
        stack.addArrangedSubview(tinyRow)

        // 2. Unlabeled icon button — triggers missing_label
        let iconButton = UIButton(type: .custom)
        let config = UIImage.SymbolConfiguration(pointSize: 24)
        iconButton.setImage(UIImage(systemName: "star.fill", withConfiguration: config), for: .normal)
        iconButton.tintColor = .systemYellow
        iconButton.accessibilityLabel = ""
        iconButton.isAccessibilityElement = true
        iconButton.accessibilityTraits = .button
        iconButton.accessibilityIdentifier = "a11y_unlabeled_icon"
        iconButton.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
        stack.addArrangedSubview(makeRow("2. Unlabeled icon button — missing_label", iconButton))

        // 3. Low contrast text (#CCCCCC on white) — triggers contrast
        let lowContrastLabel = UILabel()
        lowContrastLabel.text = "Low contrast text"
        lowContrastLabel.textColor = UIColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1.0)
        lowContrastLabel.backgroundColor = .white
        lowContrastLabel.accessibilityIdentifier = "a11y_low_contrast"
        stack.addArrangedSubview(makeRow("3. Low contrast (#CCCCCC on white) — contrast", lowContrastLabel))

        // 4. Fixed font label — triggers dynamic_type
        let fixedFontLabel = UILabel()
        fixedFontLabel.text = "Fixed font text"
        fixedFontLabel.font = UIFont.systemFont(ofSize: 14)
        fixedFontLabel.accessibilityIdentifier = "a11y_fixed_font"
        stack.addArrangedSubview(makeRow("4. Fixed font (.systemFont(ofSize: 14)) — dynamic_type", fixedFontLabel))

        // 5. Redundant traits (button + link) — triggers redundant_trait
        let redundantButton = UIButton(type: .system)
        redundantButton.setTitle("Redundant traits", for: .normal)
        redundantButton.accessibilityTraits = [.button, .link]
        redundantButton.accessibilityIdentifier = "a11y_redundant_trait"
        redundantButton.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
        stack.addArrangedSubview(makeRow("5. Button + link traits — redundant_trait", redundantButton))

        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeSectionLabel("Good Example"))

        // 6. Good example — passes all checks
        let goodButton = UIButton(type: .system)
        goodButton.setTitle("Good accessible button", for: .normal)
        goodButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        goodButton.titleLabel?.adjustsFontForContentSizeCategory = true
        goodButton.accessibilityLabel = "Good accessible button"
        goodButton.accessibilityIdentifier = "a11y_good_example"
        goodButton.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
        stack.addArrangedSubview(makeRow("6. Proper label, contrast, size, dynamic type", goodButton))

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

    // MARK: - Helpers

    private func makeRow(_ description: String, _ element: UIView) -> UIView {
        let row = UIStackView()
        row.axis = .vertical
        row.spacing = 6

        let label = UILabel()
        label.text = description
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0

        row.addArrangedSubview(label)
        row.addArrangedSubview(element)
        return row
    }

    private func makeSectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.textColor = .label
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func makeSeparator() -> UIView {
        let sep = UIView()
        sep.backgroundColor = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([sep.heightAnchor.constraint(equalToConstant: 1)])
        return sep
    }

    @objc private func buttonTapped(_ sender: UIButton) {
        let id = sender.accessibilityIdentifier ?? "unknown"
        print("[PepperTest] A11y button tapped: \(id)")
    }
}
