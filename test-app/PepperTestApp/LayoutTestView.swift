import SwiftUI
import UIKit

struct LayoutTestWrapper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> LayoutTestViewController {
        LayoutTestViewController()
    }

    func updateUIViewController(_ uiViewController: LayoutTestViewController, context: Context) {}
}

// MARK: - LayoutTestViewController

/// UIKit view controller with intentional AutoLayout scenarios:
/// well-constrained, ambiguous, conflicting, and complex nested layouts.
class LayoutTestViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Layout Test"
        view.backgroundColor = .systemBackground

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let content = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])

        let wellSection = makeWellConstrainedSection()
        let ambiguousSection = makeAmbiguousSection()
        let conflictingSection = makeConflictingSection()
        let nestedSection = makeNestedSection()

        [wellSection, ambiguousSection, conflictingSection, nestedSection].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }

        NSLayoutConstraint.activate([
            wellSection.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            wellSection.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            wellSection.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            ambiguousSection.topAnchor.constraint(equalTo: wellSection.bottomAnchor, constant: 24),
            ambiguousSection.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            ambiguousSection.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            conflictingSection.topAnchor.constraint(equalTo: ambiguousSection.bottomAnchor, constant: 24),
            conflictingSection.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            conflictingSection.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            nestedSection.topAnchor.constraint(equalTo: conflictingSection.bottomAnchor, constant: 24),
            nestedSection.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            nestedSection.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            nestedSection.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
    }

    // MARK: - Well-constrained section

    private func makeWellConstrainedSection() -> UIView {
        let container = makeSectionContainer(title: "Well-Constrained")

        let label1 = makeLabel("Label A", id: "layout_label_a", color: .systemBlue)
        let label2 = makeLabel("Label B", id: "layout_label_b", color: .systemGreen)
        let label3 = makeLabel("Label C", id: "layout_label_c", color: .systemOrange)

        [label1, label2, label3].forEach { container.addSubview($0) }

        NSLayoutConstraint.activate([
            label1.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            label1.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label1.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label1.heightAnchor.constraint(equalToConstant: 32),

            label2.topAnchor.constraint(equalTo: label1.bottomAnchor, constant: 8),
            label2.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label2.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label2.heightAnchor.constraint(equalToConstant: 32),

            label3.topAnchor.constraint(equalTo: label2.bottomAnchor, constant: 8),
            label3.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label3.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label3.heightAnchor.constraint(equalToConstant: 32),
            label3.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        return container
    }

    // MARK: - Ambiguous section

    private func makeAmbiguousSection() -> UIView {
        let container = makeSectionContainer(title: "Ambiguous Layout")

        // This view has leading + top + height but NO width or trailing constraint —
        // its horizontal size is ambiguous; flagged by `constraints ambiguous_only`.
        let ambiguousView = UIView()
        ambiguousView.backgroundColor = .systemRed.withAlphaComponent(0.3)
        ambiguousView.accessibilityIdentifier = "layout_ambiguous_view"
        ambiguousView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(ambiguousView)

        let label = makeLabel("Ambiguous width (no trailing)", id: "layout_ambiguous_label", color: .systemRed)
        container.addSubview(label)

        NSLayoutConstraint.activate([
            ambiguousView.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            ambiguousView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            // intentionally omitting trailingAnchor and widthAnchor — ambiguous!
            ambiguousView.heightAnchor.constraint(equalToConstant: 44),

            label.topAnchor.constraint(equalTo: ambiguousView.bottomAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.heightAnchor.constraint(equalToConstant: 20),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        return container
    }

    // MARK: - Conflicting section

    private func makeConflictingSection() -> UIView {
        let container = makeSectionContainer(title: "Conflicting Constraints")

        let conflictView = UIView()
        conflictView.backgroundColor = .systemPurple.withAlphaComponent(0.3)
        conflictView.accessibilityIdentifier = "layout_conflict_view"
        conflictView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(conflictView)

        let label = makeLabel("Two conflicting width constraints", id: "layout_conflict_label", color: .systemPurple)
        container.addSubview(label)

        // Two required width constraints that can't both be satisfied simultaneously.
        let widthConstraint100 = conflictView.widthAnchor.constraint(equalToConstant: 100)
        widthConstraint100.priority = .required
        widthConstraint100.identifier = "conflict_width_100"

        let widthConstraint200 = conflictView.widthAnchor.constraint(equalToConstant: 200)
        widthConstraint200.priority = .required
        widthConstraint200.identifier = "conflict_width_200"

        NSLayoutConstraint.activate([
            conflictView.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            conflictView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            conflictView.heightAnchor.constraint(equalToConstant: 44),
            widthConstraint100,
            widthConstraint200,

            label.topAnchor.constraint(equalTo: conflictView.bottomAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.heightAnchor.constraint(equalToConstant: 20),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        return container
    }

    // MARK: - Complex nested section

    private func makeNestedSection() -> UIView {
        let container = makeSectionContainer(title: "Complex Nested Layout")

        let outer = UIView()
        outer.backgroundColor = .systemTeal.withAlphaComponent(0.15)
        outer.layer.cornerRadius = 8
        outer.accessibilityIdentifier = "layout_outer_view"
        outer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(outer)

        let mid1 = makeNestedBox(color: .systemBlue, id: "layout_mid_left")
        let mid2 = makeNestedBox(color: .systemGreen, id: "layout_mid_right")
        [mid1, mid2].forEach { outer.addSubview($0) }

        let inner1 = makeNestedBox(color: .systemOrange, id: "layout_inner_1")
        let inner2 = makeNestedBox(color: .systemPink, id: "layout_inner_2")
        mid1.addSubview(inner1)
        mid1.addSubview(inner2)

        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            outer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            outer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            outer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            mid1.topAnchor.constraint(equalTo: outer.topAnchor, constant: 8),
            mid1.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: 8),
            mid1.bottomAnchor.constraint(equalTo: outer.bottomAnchor, constant: -8),
            mid1.widthAnchor.constraint(equalTo: outer.widthAnchor, multiplier: 0.5, constant: -12),

            mid2.topAnchor.constraint(equalTo: outer.topAnchor, constant: 8),
            mid2.leadingAnchor.constraint(equalTo: mid1.trailingAnchor, constant: 8),
            mid2.trailingAnchor.constraint(equalTo: outer.trailingAnchor, constant: -8),
            mid2.bottomAnchor.constraint(equalTo: outer.bottomAnchor, constant: -8),
            mid2.heightAnchor.constraint(equalToConstant: 100),

            inner1.topAnchor.constraint(equalTo: mid1.topAnchor, constant: 6),
            inner1.leadingAnchor.constraint(equalTo: mid1.leadingAnchor, constant: 6),
            inner1.trailingAnchor.constraint(equalTo: mid1.trailingAnchor, constant: -6),
            inner1.heightAnchor.constraint(equalToConstant: 30),

            inner2.topAnchor.constraint(equalTo: inner1.bottomAnchor, constant: 6),
            inner2.leadingAnchor.constraint(equalTo: mid1.leadingAnchor, constant: 6),
            inner2.trailingAnchor.constraint(equalTo: mid1.trailingAnchor, constant: -6),
            inner2.heightAnchor.constraint(equalToConstant: 30),
            inner2.bottomAnchor.constraint(equalTo: mid1.bottomAnchor, constant: -6),
        ])

        return container
    }

    // MARK: - Helpers

    private func makeSectionContainer(title: String) -> UIView {
        let container = UIView()
        container.backgroundColor = .secondarySystemBackground
        container.layer.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
        ])

        return container
    }

    private func makeLabel(_ text: String, id: String, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = color
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.accessibilityIdentifier = id
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeNestedBox(color: UIColor, id: String) -> UIView {
        let box = UIView()
        box.backgroundColor = color.withAlphaComponent(0.3)
        box.layer.cornerRadius = 6
        box.accessibilityIdentifier = id
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }
}
