import SwiftUI
import UIKit

struct PropertyEditWrapper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PropertyEditViewController {
        PropertyEditViewController()
    }

    func updateUIViewController(_ uiViewController: PropertyEditViewController, context: Context) {}
}

/// Test surface for the `edit` command — views with known starting properties.
class PropertyEditViewController: UIViewController {

    // MARK: - Views

    private let coloredBox = UIView()
    private let titleLabel = UILabel()
    private let iconImageView = UIImageView()
    private let resetButton = UIButton(type: .system)

    // MARK: - Original values (restored on reset)

    private struct Defaults {
        static let boxColor         = UIColor.systemBlue
        static let boxAlpha: CGFloat        = 1.0
        static let boxCornerRadius: CGFloat = 12.0
        static let boxBorderWidth: CGFloat  = 2.0
        static let boxBorderColor           = UIColor.systemIndigo.cgColor

        static let labelText        = "Hello, Pepper"
        static let labelFont        = UIFont.systemFont(ofSize: 18, weight: .semibold)
        static let labelColor       = UIColor.label

        static let imageHidden      = false
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Property Edit"
        view.backgroundColor = .systemBackground
        buildUI()
        applyDefaults()
    }

    // MARK: - Build

    private func buildUI() {
        // --- Colored box ---
        coloredBox.accessibilityIdentifier = "edit_test_box"
        coloredBox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(coloredBox)

        let boxLabel = UILabel()
        boxLabel.text = "Colored Box"
        boxLabel.font = .preferredFont(forTextStyle: .caption1)
        boxLabel.textColor = .secondaryLabel
        boxLabel.accessibilityIdentifier = "edit_test_box_label"
        boxLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(boxLabel)

        // --- Title label ---
        titleLabel.accessibilityIdentifier = "edit_test_label"
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        let labelCaption = UILabel()
        labelCaption.text = "UILabel"
        labelCaption.font = .preferredFont(forTextStyle: .caption1)
        labelCaption.textColor = .secondaryLabel
        labelCaption.accessibilityIdentifier = "edit_test_label_caption"
        labelCaption.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(labelCaption)

        // --- Image view ---
        iconImageView.image = UIImage(systemName: "star.fill")
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.tintColor = .systemYellow
        iconImageView.accessibilityIdentifier = "edit_test_image"
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iconImageView)

        let imageCaption = UILabel()
        imageCaption.text = "UIImageView"
        imageCaption.font = .preferredFont(forTextStyle: .caption1)
        imageCaption.textColor = .secondaryLabel
        imageCaption.accessibilityIdentifier = "edit_test_image_caption"
        imageCaption.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageCaption)

        // --- Reset button ---
        resetButton.setTitle("Reset to Defaults", for: .normal)
        resetButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        resetButton.accessibilityIdentifier = "edit_test_reset_button"
        resetButton.addAction(UIAction { [weak self] _ in self?.applyDefaults() }, for: .touchUpInside)
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resetButton)

        // --- Layout ---
        NSLayoutConstraint.activate([
            // Box
            coloredBox.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
            coloredBox.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            coloredBox.widthAnchor.constraint(equalToConstant: 200),
            coloredBox.heightAnchor.constraint(equalToConstant: 80),

            boxLabel.topAnchor.constraint(equalTo: coloredBox.bottomAnchor, constant: 4),
            boxLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Label
            titleLabel.topAnchor.constraint(equalTo: boxLabel.bottomAnchor, constant: 32),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            labelCaption.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            labelCaption.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Image
            iconImageView.topAnchor.constraint(equalTo: labelCaption.bottomAnchor, constant: 32),
            iconImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 60),
            iconImageView.heightAnchor.constraint(equalToConstant: 60),

            imageCaption.topAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: 4),
            imageCaption.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Reset button
            resetButton.topAnchor.constraint(equalTo: imageCaption.bottomAnchor, constant: 48),
            resetButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    // MARK: - Reset

    private func applyDefaults() {
        coloredBox.backgroundColor      = Defaults.boxColor
        coloredBox.alpha                = Defaults.boxAlpha
        coloredBox.layer.cornerRadius   = Defaults.boxCornerRadius
        coloredBox.layer.borderWidth    = Defaults.boxBorderWidth
        coloredBox.layer.borderColor    = Defaults.boxBorderColor

        titleLabel.text                 = Defaults.labelText
        titleLabel.font                 = Defaults.labelFont
        titleLabel.textColor            = Defaults.labelColor

        iconImageView.isHidden          = Defaults.imageHidden

        print("[PepperTest] PropertyEdit: reset to defaults")
    }
}
