import SwiftUI
import UIKit

// MARK: - SwiftUI Wrapper

struct DynamicTypeWrapper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DynamicTypeViewController {
        DynamicTypeViewController()
    }

    func updateUIViewController(_ vc: DynamicTypeViewController, context: Context) {}
}

// MARK: - View Controller

/// Showcases all 11 `UIFont.TextStyle` values for `dynamic_type` command testing.
/// Mixes UIKit labels (UIFontMetrics) and SwiftUI text to validate both scaling paths.
final class DynamicTypeViewController: UIViewController {

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let sizeCategoryLabel = UILabel()

    /// Text styles in display order, paired with their names.
    private let textStyles: [(name: String, style: UIFont.TextStyle)] = [
        ("largeTitle", .largeTitle),
        ("title1", .title1),
        ("title2", .title2),
        ("title3", .title3),
        ("headline", .headline),
        ("subheadline", .subheadline),
        ("body", .body),
        ("callout", .callout),
        ("footnote", .footnote),
        ("caption1", .caption1),
        ("caption2", .caption2),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Dynamic Type"
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "dynamic_type_view"
        buildUI()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
    }

    // MARK: - UI Construction

    private func buildUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
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

        // Current size category
        sizeCategoryLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        sizeCategoryLabel.adjustsFontForContentSizeCategory = true
        sizeCategoryLabel.numberOfLines = 0
        sizeCategoryLabel.accessibilityIdentifier = "dt_current_category"
        updateSizeCategoryLabel()
        stack.addArrangedSubview(sizeCategoryLabel)

        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeSectionLabel("UIKit Labels (UIFontMetrics)"))

        // UIKit labels — all use preferredFont and adjustsFontForContentSizeCategory
        for item in textStyles {
            let row = makeUIKitRow(name: item.name, style: item.style, adjusts: true)
            stack.addArrangedSubview(row)
        }

        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeSectionLabel("UIKit Fixed Labels (no scaling)"))

        // Two fixed-font labels that intentionally don't scale — for audit detection
        let fixedBody = makeUIKitRow(name: "body-fixed", style: .body, adjusts: false)
        stack.addArrangedSubview(fixedBody)

        let fixedCaption = makeUIKitRow(name: "caption1-fixed", style: .caption1, adjusts: false)
        stack.addArrangedSubview(fixedCaption)

        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeSectionLabel("SwiftUI Text"))

        // SwiftUI text labels hosted via UIHostingController
        let swiftUISection = makeSwiftUISection()
        addChild(swiftUISection)
        swiftUISection.view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(swiftUISection.view)
        swiftUISection.didMove(toParent: self)
    }

    // MARK: - UIKit Row

    private func makeUIKitRow(name: String, style: UIFont.TextStyle, adjusts: Bool) -> UIView {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 2

        let font = UIFont.preferredFont(forTextStyle: style)

        let textLabel = UILabel()
        textLabel.text = ".\(name)"
        if adjusts {
            textLabel.font = font
            textLabel.adjustsFontForContentSizeCategory = true
        } else {
            // Intentionally use fixed size — won't respond to Dynamic Type changes
            textLabel.font = UIFont.systemFont(ofSize: font.pointSize)
        }
        textLabel.numberOfLines = 0
        textLabel.accessibilityIdentifier = "dt_\(name)"
        container.addArrangedSubview(textLabel)

        let sizeLabel = UILabel()
        sizeLabel.text = "\(String(format: "%.1f", font.pointSize))pt\(adjusts ? "" : " (fixed)")"
        sizeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabel
        sizeLabel.accessibilityIdentifier = "dt_\(name)_size"
        container.addArrangedSubview(sizeLabel)

        return container
    }

    // MARK: - SwiftUI Section

    private func makeSwiftUISection() -> UIHostingController<DynamicTypeSwiftUILabels> {
        let hosting = UIHostingController(rootView: DynamicTypeSwiftUILabels())
        hosting.view.backgroundColor = .clear
        return hosting
    }

    // MARK: - Helpers

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

    private func updateSizeCategoryLabel() {
        let category = UIApplication.shared.preferredContentSizeCategory.rawValue
        sizeCategoryLabel.text = "Size category: \(category)"
    }

    @objc private func contentSizeCategoryDidChange() {
        updateSizeCategoryLabel()
    }
}

// MARK: - SwiftUI Labels

/// SwiftUI text using `.font()` modifiers — validates SwiftUI-side Dynamic Type scaling.
struct DynamicTypeSwiftUILabels: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let styles: [(name: String, font: Font)] = [
        ("title", .title),
        ("title2", .title2),
        ("title3", .title3),
        ("headline", .headline),
        ("body", .body),
        ("callout", .callout),
        ("footnote", .footnote),
        ("caption", .caption),
        ("caption2", .caption2),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(styles, id: \.name) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(".\(item.name)")
                        .font(item.font)
                        .accessibilityIdentifier("dt_swiftui_\(item.name)")

                    Text("Dynamic type: \(dynamicTypeSize.description)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("dt_swiftui_\(item.name)_info")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - DynamicTypeSize description

extension DynamicTypeSize: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .xSmall: return "xSmall"
        case .small: return "small"
        case .medium: return "medium"
        case .large: return "large"
        case .xLarge: return "xLarge"
        case .xxLarge: return "xxLarge"
        case .xxxLarge: return "xxxLarge"
        case .accessibility1: return "accessibility1"
        case .accessibility2: return "accessibility2"
        case .accessibility3: return "accessibility3"
        case .accessibility4: return "accessibility4"
        case .accessibility5: return "accessibility5"
        @unknown default: return "unknown"
        }
    }
}
