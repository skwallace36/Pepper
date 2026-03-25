import XCTest
@testable import PepperCore

final class TraitClassificationTests: XCTestCase {

    // MARK: - classifyAccessibilityTraits (priority order)

    func test_button_trait_returns_button() {
        XCTAssertEqual(classifyAccessibilityTraits(.button), "button")
    }

    func test_link_trait_returns_link() {
        XCTAssertEqual(classifyAccessibilityTraits(.link), "link")
    }

    func test_searchField_trait_returns_searchField() {
        XCTAssertEqual(classifyAccessibilityTraits(.searchField), "searchField")
    }

    func test_image_trait_returns_image() {
        XCTAssertEqual(classifyAccessibilityTraits(.image), "image")
    }

    func test_header_trait_returns_header() {
        XCTAssertEqual(classifyAccessibilityTraits(.header), "header")
    }

    func test_adjustable_trait_returns_adjustable() {
        XCTAssertEqual(classifyAccessibilityTraits(.adjustable), "adjustable")
    }

    func test_staticText_trait_returns_staticText() {
        XCTAssertEqual(classifyAccessibilityTraits(.staticText), "staticText")
    }

    func test_tabBar_trait_returns_tabBar() {
        XCTAssertEqual(classifyAccessibilityTraits(.tabBar), "tabBar")
    }

    func test_keyboardKey_trait_returns_keyboardKey() {
        XCTAssertEqual(classifyAccessibilityTraits(.keyboardKey), "keyboardKey")
    }

    func test_no_traits_returns_element() {
        XCTAssertEqual(classifyAccessibilityTraits(AccessibilityTraits(rawValue: 0)), "element")
    }

    func test_button_wins_over_staticText() {
        // When element has both button and staticText, button takes priority
        let traits: AccessibilityTraits = [.button, .staticText]
        XCTAssertEqual(classifyAccessibilityTraits(traits), "button")
    }

    func test_link_wins_over_image() {
        let traits: AccessibilityTraits = [.link, .image]
        XCTAssertEqual(classifyAccessibilityTraits(traits), "link")
    }

    func test_button_wins_over_header() {
        let traits: AccessibilityTraits = [.button, .header]
        XCTAssertEqual(classifyAccessibilityTraits(traits), "button")
    }

    // MARK: - describeTraits

    func test_describe_single_trait() {
        XCTAssertEqual(describeTraits(.button), ["button"])
    }

    func test_describe_multiple_traits() {
        let traits: AccessibilityTraits = [.button, .selected]
        let result = describeTraits(traits)
        XCTAssertTrue(result.contains("button"))
        XCTAssertTrue(result.contains("selected"))
        XCTAssertEqual(result.count, 2)
    }

    func test_describe_no_traits_returns_empty() {
        XCTAssertEqual(describeTraits(AccessibilityTraits(rawValue: 0)), [])
    }

    func test_describe_all_traits() {
        let all: AccessibilityTraits = [
            .button, .link, .image, .selected, .staticText, .header,
            .searchField, .adjustable, .notEnabled, .updatesFrequently,
            .tabBar, .keyboardKey,
        ]
        let result = describeTraits(all)
        XCTAssertEqual(result.count, 12)
        XCTAssertTrue(result.contains("button"))
        XCTAssertTrue(result.contains("link"))
        XCTAssertTrue(result.contains("image"))
        XCTAssertTrue(result.contains("selected"))
        XCTAssertTrue(result.contains("staticText"))
        XCTAssertTrue(result.contains("header"))
        XCTAssertTrue(result.contains("searchField"))
        XCTAssertTrue(result.contains("adjustable"))
        XCTAssertTrue(result.contains("notEnabled"))
        XCTAssertTrue(result.contains("updatesFrequently"))
        XCTAssertTrue(result.contains("tabBar"))
        XCTAssertTrue(result.contains("keyboardKey"))
    }

    func test_describe_traits_order_matches_production() {
        // Production code appends in a fixed order — verify
        let traits: AccessibilityTraits = [.button, .staticText, .selected]
        let result = describeTraits(traits)
        XCTAssertEqual(result, ["button", "selected", "staticText"])
    }

    // MARK: - PepperClassFilter

    func test_pepper_prefix_is_internal() {
        XCTAssertTrue(PepperClassFilter.isInternalClass("PepperOverlayView"))
        XCTAssertTrue(PepperClassFilter.isInternalClass("PepperTouchVisualizer"))
        XCTAssertTrue(PepperClassFilter.isInternalClass("PepperConsoleInterceptor"))
    }

    func test_floatingbar_prefix_is_internal() {
        XCTAssertTrue(PepperClassFilter.isInternalClass("FloatingBarController"))
        XCTAssertTrue(PepperClassFilter.isInternalClass("FloatingBarView"))
    }

    func test_regular_classes_not_internal() {
        XCTAssertFalse(PepperClassFilter.isInternalClass("UIButton"))
        XCTAssertFalse(PepperClassFilter.isInternalClass("UILabel"))
        XCTAssertFalse(PepperClassFilter.isInternalClass("MyCustomView"))
    }

    func test_substring_match_does_not_trigger() {
        // "Pepper" must be a prefix, not a substring
        XCTAssertFalse(PepperClassFilter.isInternalClass("DrPepperView"))
        XCTAssertFalse(PepperClassFilter.isInternalClass("MyPepperWidget"))
    }

    func test_empty_string_not_internal() {
        XCTAssertFalse(PepperClassFilter.isInternalClass(""))
    }

    // MARK: - LabelSourceClassifier

    func test_button_with_title_is_text() {
        XCTAssertEqual(
            LabelSourceClassifier.classify(isButtonWithTitle: true),
            "text")
    }

    func test_label_is_text() {
        XCTAssertEqual(LabelSourceClassifier.classify(isLabel: true), "text")
    }

    func test_textfield_is_text() {
        XCTAssertEqual(LabelSourceClassifier.classify(isTextField: true), "text")
    }

    func test_textview_is_text() {
        XCTAssertEqual(LabelSourceClassifier.classify(isTextView: true), "text")
    }

    func test_segmented_control_is_text() {
        XCTAssertEqual(LabelSourceClassifier.classify(isSegmentedControl: true), "text")
    }

    func test_className_containing_UILabel_is_text() {
        XCTAssertEqual(
            LabelSourceClassifier.classify(className: "SwiftUI.UILabel"),
            "text")
    }

    func test_className_containing_TextField_is_text() {
        XCTAssertEqual(
            LabelSourceClassifier.classify(className: "CustomTextField"),
            "text")
    }

    func test_generic_view_is_a11y() {
        XCTAssertEqual(
            LabelSourceClassifier.classify(className: "UIImageView"),
            "a11y")
    }

    func test_map_view_is_a11y() {
        XCTAssertEqual(
            LabelSourceClassifier.classify(className: "MKMapView"),
            "a11y")
    }

    func test_no_signals_is_a11y() {
        XCTAssertEqual(LabelSourceClassifier.classify(), "a11y")
    }
}
