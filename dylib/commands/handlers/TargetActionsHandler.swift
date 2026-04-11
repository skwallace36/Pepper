import UIKit

/// Handles {"cmd": "target_actions", ...} commands.
///
/// Walks the view hierarchy and lists all UIControl target-action pairs.
/// For each control, enumerates `allTargets` and `actions(forTarget:forControlEvent:)`
/// to produce a structured listing of how the app is wired together.
///
/// Param formats:
///   {"cmd": "target_actions"}                                    — all controls in all windows
///   {"cmd": "target_actions", "params": {"element": "myBtn"}}   — single control by ID
///   {"cmd": "target_actions", "params": {"text": "Submit"}}     — single control by text
///   {"cmd": "target_actions", "params": {"class": "UISwitch"}}  — filter by control class
struct TargetActionsHandler: PepperHandler {
    let commandName = "target_actions"

    func handle(_ command: PepperCommand) throws -> PepperResponse {
        let windows = UIWindow.pepper_allVisibleWindows
        guard !windows.isEmpty else {
            return .error(id: command.id, message: "No visible windows")
        }

        let params = command.params
        let classFilter = params?["class"]?.stringValue

        // If targeting a specific element, resolve it
        if params?["element"] != nil || params?["text"] != nil || params?["label"] != nil {
            return handleSingleElement(command: command, params: params, windows: windows)
        }

        // Walk all windows and collect controls
        var items: [AnyCodable] = []
        for window in windows {
            collectControls(in: window, classFilter: classFilter, items: &items)
        }

        return .list(id: command.id, "controls", items)
    }

    // MARK: - Single Element

    private func handleSingleElement(
        command: PepperCommand, params: [String: AnyCodable]?, windows: [UIWindow]
    ) -> PepperResponse {
        for window in windows {
            let (result, _) = PepperElementResolver.resolve(params: params, in: window)
            if let result = result {
                guard let control = result.view as? UIControl else {
                    return .error(
                        id: command.id,
                        message: "Element is \(type(of: result.view)), not a UIControl subclass"
                    )
                }
                let entry = describeControl(control)
                return .result(id: command.id, entry)
            }
        }
        return .elementNotFound(
            id: command.id,
            message: "Element not found",
            query: params?["element"]?.stringValue ?? params?["text"]?.stringValue
        )
    }

    // MARK: - Tree Walk

    private func collectControls(
        in view: UIView, classFilter: String?, items: inout [AnyCodable]
    ) {
        if let control = view as? UIControl {
            let className = String(describing: type(of: control))
            if classFilter == nil || className.contains(classFilter!) {
                let targets = control.allTargets
                // Only include controls that have at least one target-action pair
                if !targets.isEmpty {
                    items.append(AnyCodable(describeControl(control)))
                }
            }
        }
        for subview in view.subviews {
            collectControls(in: subview, classFilter: classFilter, items: &items)
        }
    }

    // MARK: - Control Description

    private func describeControl(_ control: UIControl) -> [String: AnyCodable] {
        var info: [String: AnyCodable] = [
            "class": AnyCodable(String(describing: type(of: control))),
            "enabled": AnyCodable(control.isEnabled),
            "state": AnyCodable(controlStateName(control.state)),
        ]

        // Identity
        if let id = control.accessibilityIdentifier, !id.isEmpty {
            info["id"] = AnyCodable(id)
        }
        if let label = control.accessibilityLabel, !label.isEmpty {
            info["label"] = AnyCodable(label)
        }
        if let title = (control as? UIButton)?.currentTitle, !title.isEmpty {
            info["title"] = AnyCodable(title)
        }

        // Frame in window coordinates
        let frame = control.convert(control.bounds, to: nil)
        info["frame"] = AnyCodable([
            "x": AnyCodable(Double(frame.origin.x)),
            "y": AnyCodable(Double(frame.origin.y)),
            "width": AnyCodable(Double(frame.size.width)),
            "height": AnyCodable(Double(frame.size.height)),
        ])

        // Target-action pairs
        var actions: [AnyCodable] = []
        for target in control.allTargets {
            for event in Self.allEvents {
                if let selectors = control.actions(forTarget: target, forControlEvent: event) {
                    let targetClass: String
                    if target is NSNull {
                        targetClass = "nil (responder chain)"
                    } else {
                        targetClass = String(describing: type(of: target))
                    }

                    for selector in selectors {
                        actions.append(
                            AnyCodable([
                                "target": AnyCodable(targetClass),
                                "action": AnyCodable(selector),
                                "events": AnyCodable(eventNames(event)),
                            ]))
                    }
                }
            }
        }
        info["actions"] = AnyCodable(actions)

        return info
    }

    // MARK: - Event Helpers

    private static let allEvents: [UIControl.Event] = [
        .touchDown, .touchDownRepeat, .touchDragInside, .touchDragOutside,
        .touchDragEnter, .touchDragExit, .touchUpInside, .touchUpOutside,
        .touchCancel, .valueChanged, .menuActionTriggered, .editingDidBegin,
        .editingChanged, .editingDidEnd, .editingDidEndOnExit,
        .primaryActionTriggered,
    ]

    private func eventNames(_ event: UIControl.Event) -> String {
        var names: [String] = []
        if event.contains(.touchDown) { names.append("touchDown") }
        if event.contains(.touchDownRepeat) { names.append("touchDownRepeat") }
        if event.contains(.touchDragInside) { names.append("touchDragInside") }
        if event.contains(.touchDragOutside) { names.append("touchDragOutside") }
        if event.contains(.touchDragEnter) { names.append("touchDragEnter") }
        if event.contains(.touchDragExit) { names.append("touchDragExit") }
        if event.contains(.touchUpInside) { names.append("touchUpInside") }
        if event.contains(.touchUpOutside) { names.append("touchUpOutside") }
        if event.contains(.touchCancel) { names.append("touchCancel") }
        if event.contains(.valueChanged) { names.append("valueChanged") }
        if event.contains(.menuActionTriggered) { names.append("menuActionTriggered") }
        if event.contains(.editingDidBegin) { names.append("editingDidBegin") }
        if event.contains(.editingChanged) { names.append("editingChanged") }
        if event.contains(.editingDidEnd) { names.append("editingDidEnd") }
        if event.contains(.editingDidEndOnExit) { names.append("editingDidEndOnExit") }
        if event.contains(.primaryActionTriggered) { names.append("primaryActionTriggered") }
        return names.joined(separator: ", ")
    }

    private func controlStateName(_ state: UIControl.State) -> String {
        var names: [String] = []
        if state.contains(.highlighted) { names.append("highlighted") }
        if state.contains(.disabled) { names.append("disabled") }
        if state.contains(.selected) { names.append("selected") }
        if state.contains(.focused) { names.append("focused") }
        if names.isEmpty { names.append("normal") }
        return names.joined(separator: ", ")
    }
}
