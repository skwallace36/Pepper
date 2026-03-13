import UIKit
import os

/// Handles {"cmd": "read", "element": "id"} commands.
/// Finds an element by accessibility identifier and reads its current value,
/// type, and state information.
struct ReadHandler: PepperHandler {
    let commandName = "read"
    private var logger: Logger { PepperLogger.logger(category: "read") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let elementID = command.params?["element"]?.value as? String else {
            return .error(id: command.id, message: "Missing required param: element")
        }

        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window available")
        }

        guard let view = window.pepper_findElement(id: elementID) else {
            return .error(id: command.id, message: "Element not found: \(elementID)")
        }

        logger.info("Reading element: \(elementID)")
        let data = readElement(view, id: elementID)
        return .ok(id: command.id, data: data)
    }

    // MARK: - Element Reading

    private func readElement(_ view: UIView, id: String) -> [String: AnyCodable] {
        var data: [String: AnyCodable] = [
            "id": AnyCodable(id),
            "type": AnyCodable(elementType(for: view)),
            "visible": AnyCodable(!view.isHidden && view.alpha > 0),
            "frame": AnyCodable([
                "x": AnyCodable(Double(view.frame.origin.x)),
                "y": AnyCodable(Double(view.frame.origin.y)),
                "width": AnyCodable(Double(view.frame.size.width)),
                "height": AnyCodable(Double(view.frame.size.height))
            ])
        ]

        if let label = view.accessibilityLabel, !label.isEmpty {
            data["label"] = AnyCodable(label)
        }

        switch view {
        case let label as UILabel:
            data["value"] = AnyCodable(label.text ?? "")
            data["numberOfLines"] = AnyCodable(label.numberOfLines)

        case let button as UIButton:
            data["value"] = AnyCodable(button.currentTitle ?? "")
            data["enabled"] = AnyCodable(button.isEnabled)
            data["selected"] = AnyCodable(button.isSelected)

        case let field as UITextField:
            data["value"] = AnyCodable(field.text ?? "")
            data["placeholder"] = AnyCodable(field.placeholder ?? "")
            data["enabled"] = AnyCodable(field.isEnabled)
            data["editing"] = AnyCodable(field.isEditing)
            data["secureEntry"] = AnyCodable(field.isSecureTextEntry)

        case let textView as UITextView:
            data["value"] = AnyCodable(textView.text ?? "")
            data["editable"] = AnyCodable(textView.isEditable)

        case let toggle as UISwitch:
            data["value"] = AnyCodable(toggle.isOn)
            data["enabled"] = AnyCodable(toggle.isEnabled)

        case let slider as UISlider:
            data["value"] = AnyCodable(Double(slider.value))
            data["min"] = AnyCodable(Double(slider.minimumValue))
            data["max"] = AnyCodable(Double(slider.maximumValue))
            data["enabled"] = AnyCodable(slider.isEnabled)

        case let segment as UISegmentedControl:
            data["value"] = AnyCodable(segment.selectedSegmentIndex)
            data["segmentCount"] = AnyCodable(segment.numberOfSegments)
            var titles: [AnyCodable] = []
            for i in 0..<segment.numberOfSegments {
                titles.append(AnyCodable(segment.titleForSegment(at: i) ?? ""))
            }
            data["segmentTitles"] = AnyCodable(titles)
            data["enabled"] = AnyCodable(segment.isEnabled)

        case let progress as UIProgressView:
            data["value"] = AnyCodable(Double(progress.progress))

        case let activityIndicator as UIActivityIndicatorView:
            data["value"] = AnyCodable(activityIndicator.isAnimating)

        case let imageView as UIImageView:
            data["hasImage"] = AnyCodable(imageView.image != nil)
            data["highlighted"] = AnyCodable(imageView.isHighlighted)

        case let datePicker as UIDatePicker:
            let formatter = ISO8601DateFormatter()
            data["value"] = AnyCodable(formatter.string(from: datePicker.date))
            data["enabled"] = AnyCodable(datePicker.isEnabled)

        default:
            if let accessValue = view.accessibilityValue {
                data["value"] = AnyCodable(accessValue)
            }
        }

        return data
    }

    // MARK: - Type Detection

    private func elementType(for view: UIView) -> String {
        switch view {
        case is UIButton: return "button"
        case is UITextField: return "textField"
        case is UITextView: return "textView"
        case is UISwitch: return "switch"
        case is UISlider: return "slider"
        case is UISegmentedControl: return "segmentedControl"
        case is UIStepper: return "stepper"
        case is UIDatePicker: return "datePicker"
        case is UIProgressView: return "progressView"
        case is UIActivityIndicatorView: return "activityIndicator"
        case is UIPageControl: return "pageControl"
        case is UILabel: return "label"
        case is UIImageView: return "image"
        case is UITableView: return "tableView"
        case is UICollectionView: return "collectionView"
        case is UIScrollView: return "scrollView"
        default: return "view"
        }
    }

}
