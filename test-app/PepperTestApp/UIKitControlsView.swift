import SwiftUI
import UIKit

struct UIKitControlsWrapper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIKitControlsViewController {
        UIKitControlsViewController()
    }

    func updateUIViewController(_ uiViewController: UIKitControlsViewController, context: Context) {}
}

class UIKitControlsViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "UIKit Controls"
        view.backgroundColor = .systemBackground

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // UIButton
        let button = UIButton(type: .system)
        button.setTitle("UIKit Button", for: .normal)
        button.accessibilityIdentifier = "uikit_button"
        button.addAction(UIAction { _ in
            print("[PepperTest] UIKit button tapped")
        }, for: .touchUpInside)
        stack.addArrangedSubview(button)

        // UITextField
        let textField = UITextField()
        textField.placeholder = "UIKit text field"
        textField.borderStyle = .roundedRect
        textField.accessibilityIdentifier = "uikit_text_field"
        stack.addArrangedSubview(textField)

        // UISwitch
        let switchRow = UIStackView()
        switchRow.axis = .horizontal
        switchRow.spacing = 8
        let switchLabel = UILabel()
        switchLabel.text = "UIKit Switch"
        let uiSwitch = UISwitch()
        uiSwitch.accessibilityIdentifier = "uikit_switch"
        uiSwitch.addAction(UIAction { action in
            let s = action.sender as! UISwitch
            print("[PepperTest] UIKit switch: \(s.isOn)")
        }, for: .valueChanged)
        switchRow.addArrangedSubview(switchLabel)
        switchRow.addArrangedSubview(uiSwitch)
        stack.addArrangedSubview(switchRow)

        // UISegmentedControl
        let segment = UISegmentedControl(items: ["Alpha", "Beta", "Gamma"])
        segment.selectedSegmentIndex = 0
        segment.accessibilityIdentifier = "uikit_segment"
        segment.addAction(UIAction { action in
            let s = action.sender as! UISegmentedControl
            print("[PepperTest] UIKit segment: \(s.selectedSegmentIndex)")
        }, for: .valueChanged)
        stack.addArrangedSubview(segment)

        // UISlider
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 100
        slider.value = 50
        slider.accessibilityIdentifier = "uikit_slider"
        stack.addArrangedSubview(slider)

        // UIProgressView
        let progress = UIProgressView(progressViewStyle: .default)
        progress.progress = 0.65
        progress.accessibilityIdentifier = "uikit_progress"
        stack.addArrangedSubview(progress)

        // UIActivityIndicatorView
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        spinner.accessibilityIdentifier = "uikit_spinner"
        stack.addArrangedSubview(spinner)

        // UILabel
        let label = UILabel()
        label.text = "UIKit Label"
        label.accessibilityIdentifier = "uikit_label"
        stack.addArrangedSubview(label)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }
}
