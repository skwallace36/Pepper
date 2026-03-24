import UIKit
import os

/// Handles scroll commands:
///   {"cmd": "scroll", "params": {"text": "Settings"}}            -- scroll text into view (smart, nav-bar-aware)
///   {"cmd": "scroll", "params": {"element": "accessibility_id"}} -- scroll element into view by a11y ID
///   {"cmd": "scroll", "params": {"direction": "down", "distance": 300}}
///   {"cmd": "scroll", "params": {"position": "top"}}
struct ScrollHandler: PepperHandler {
    let commandName = "scroll"
    private var logger: Logger { PepperLogger.logger(category: "scroll") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window available")
        }

        // Mode 1: Scroll to position (top/bottom)
        if let position = command.params?["position"]?.value as? String {
            return scrollToPosition(position, in: window, command: command)
        }

        // Mode 2a: Scroll to an element by text (uses same resolution as tap)
        if let text = command.params?["text"]?.stringValue {
            return scrollToText(text, in: window, command: command)
        }

        // Mode 2b: Scroll to an element by accessibility ID
        if let elementID = command.params?["element"]?.value as? String {
            return scrollToElement(elementID, in: window, command: command)
        }

        // Mode 3: Scroll by direction and amount
        if let direction = command.params?["direction"]?.value as? String {
            let amountInt = (command.params?["amount"]?.value as? Int).map { CGFloat($0) }
            let amountDbl = (command.params?["amount"]?.value as? Double).map { CGFloat($0) }
            let distInt = (command.params?["distance"]?.value as? Int).map { CGFloat($0) }
            let distDbl = (command.params?["distance"]?.value as? Double).map { CGFloat($0) }
            let amount: CGFloat = amountInt ?? amountDbl ?? distInt ?? distDbl ?? 200.0
            let scrollViewID = command.params?["scrollView"]?.value as? String
            let scrollViewClass = command.params?["class"]?.value as? String
            return scrollByDirection(
                direction, amount: amount, scrollViewID: scrollViewID, scrollViewClass: scrollViewClass, in: window,
                command: command)
        }

        return .error(id: command.id, message: "Missing required param: position, element, or direction")
    }

    // MARK: - Scroll to position

    private func scrollToPosition(_ position: String, in window: UIWindow, command: PepperCommand) -> PepperResponse {
        guard let scrollView = findFirstScrollView(in: window) else {
            return .error(id: command.id, message: "No scroll view found on screen")
        }

        let inset = scrollView.adjustedContentInset
        let newOffset: CGPoint
        switch position.lowercased() {
        case "top":
            newOffset = CGPoint(x: 0, y: -inset.top)
        case "bottom":
            let maxY = max(scrollView.contentSize.height - scrollView.bounds.height + inset.bottom, -inset.top)
            newOffset = CGPoint(x: 0, y: maxY)
        default:
            return .error(id: command.id, message: "Invalid position: \(position). Use top/bottom")
        }

        logger.info("Scroll to \(position): offset → (\(newOffset.x), \(newOffset.y))")
        scrollView.setContentOffset(newOffset, animated: false)

        return .ok(
            id: command.id,
            data: [
                "position": AnyCodable(position),
                "scrollOffset": AnyCodable([
                    "x": AnyCodable(Double(newOffset.x)),
                    "y": AnyCodable(Double(newOffset.y)),
                ]),
            ])
    }

    // MARK: - Scroll to text

    /// Find an element by visible text and scroll its ancestor scroll view so the element
    /// is on-screen and not behind the navigation bar or bottom safe area.
    private func scrollToText(_ text: String, in window: UIWindow, command: PepperCommand) -> PepperResponse {
        let (result, errorMsg) = PepperElementResolver.resolve(params: ["text": AnyCodable(text)], in: window)
        guard let result = result else {
            return .error(id: command.id, message: errorMsg ?? "Text not found: \(text)")
        }

        let element = result.view
        let elementCenter =
            result.tapPoint
            ?? element.convert(
                CGPoint(x: element.bounds.midX, y: element.bounds.midY), to: window
            )

        // Check if already visible in the safe area (not behind nav bar or toolbar)
        let screen = UIScreen.main.bounds
        let safeTop = window.safeAreaInsets.top
        let safeBottom = window.safeAreaInsets.bottom
        // Measure actual nav bar height instead of assuming 44pt
        let navBarHeight: CGFloat = {
            if let rootVC = window.rootViewController {
                let topVC = rootVC.pepper_topMostViewController
                if let navBar = topVC.navigationController?.navigationBar, !navBar.isHidden {
                    return navBar.frame.height
                }
            }
            return 44  // fallback for non-standard nav
        }()
        let visibleRect = CGRect(
            x: 0, y: safeTop + navBarHeight,
            width: screen.width,
            height: screen.height - safeTop - navBarHeight - safeBottom)

        if visibleRect.contains(elementCenter) {
            logger.info("Text '\(text)' already visible at (\(elementCenter.x), \(elementCenter.y))")
            return .ok(
                id: command.id,
                data: [
                    "text": AnyCodable(text),
                    "already_visible": AnyCodable(true),
                    "center": AnyCodable([
                        "x": AnyCodable(Double(elementCenter.x)),
                        "y": AnyCodable(Double(elementCenter.y)),
                    ]),
                ])
        }

        // Find the nearest ancestor scroll view
        guard let scrollView = findAncestorScrollView(of: element) else {
            return .error(id: command.id, message: "No scroll view ancestor for text: \(text)")
        }

        // Scroll the element into view — target the middle of the visible area
        let frameInScroll = element.convert(element.bounds, to: scrollView)
        let targetY = frameInScroll.midY - (visibleRect.height / 2)
        let maxOffsetY = max(
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom, 0)
        let clampedY = min(max(targetY, -scrollView.adjustedContentInset.top), maxOffsetY)

        logger.info("Scrolling to text '\(text)': offset.y → \(clampedY)")
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: clampedY), animated: false)

        // Verify final position
        let finalCenter = element.convert(
            CGPoint(x: element.bounds.midX, y: element.bounds.midY), to: window
        )

        return .ok(
            id: command.id,
            data: [
                "text": AnyCodable(text),
                "center": AnyCodable([
                    "x": AnyCodable(Double(finalCenter.x)),
                    "y": AnyCodable(Double(finalCenter.y)),
                ]),
                "scrollOffset": AnyCodable([
                    "x": AnyCodable(scrollView.contentOffset.x),
                    "y": AnyCodable(scrollView.contentOffset.y),
                ]),
            ])
    }

    // MARK: - Scroll to element

    private func scrollToElement(_ elementID: String, in window: UIWindow, command: PepperCommand) -> PepperResponse {
        guard let element = window.pepper_findElement(id: elementID) else {
            return .error(id: command.id, message: "Element not found: \(elementID)")
        }

        // Find the nearest ancestor scroll view
        guard let scrollView = findAncestorScrollView(of: element) else {
            return .error(id: command.id, message: "No scroll view ancestor found for: \(elementID)")
        }

        logger.info("Scrolling to element: \(elementID)")
        let frame = element.convert(element.bounds, to: scrollView)
        scrollView.scrollRectToVisible(frame, animated: false)

        return .ok(
            id: command.id,
            data: [
                "element": AnyCodable(elementID),
                "scrollOffset": AnyCodable([
                    "x": AnyCodable(scrollView.contentOffset.x),
                    "y": AnyCodable(scrollView.contentOffset.y),
                ]),
            ])
    }

    // MARK: - Scroll by direction (touch synthesis)

    private func scrollByDirection(
        _ direction: String, amount: CGFloat, scrollViewID: String?, scrollViewClass: String?, in window: UIWindow,
        command: PepperCommand
    ) -> PepperResponse {
        let duration = command.params?["duration"]?.doubleValue ?? 0.4

        // Determine gesture start point — center of targeted scroll view, or screen center
        var startX = window.bounds.midX
        var startY = window.bounds.midY

        if let id = scrollViewID,
            let scrollView = window.pepper_findElement(id: id) as? UIScrollView
        {
            let center = scrollView.convert(
                CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
                to: window
            )
            startX = center.x
            startY = center.y
        } else if let className = scrollViewClass,
            let scrollView = findScrollViewByClass(className, in: window)
        {
            let center = scrollView.convert(
                CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
                to: window
            )
            startX = center.x
            startY = center.y
        }

        // Allow explicit start point override
        if let fromDict = command.params?["from"]?.dictValue {
            if let fx = fromDict["x"]?.doubleValue { startX = CGFloat(fx) }
            if let fy = fromDict["y"]?.doubleValue { startY = CGFloat(fy) }
        } else {
            // Fallback: top-level x/y params
            if let fx = command.params?["x"]?.doubleValue { startX = CGFloat(fx) }
            if let fy = command.params?["y"]?.doubleValue { startY = CGFloat(fy) }
        }

        let from: CGPoint
        let to: CGPoint

        // Scroll direction is opposite to finger direction:
        // "scroll down" (see content below) = finger drags UP on screen
        switch direction.lowercased() {
        case "down":
            from = CGPoint(x: startX, y: startY)
            to = CGPoint(x: startX, y: startY - amount)
        case "up":
            from = CGPoint(x: startX, y: startY)
            to = CGPoint(x: startX, y: startY + amount)
        case "left":
            from = CGPoint(x: startX, y: startY)
            to = CGPoint(x: startX + amount, y: startY)
        case "right":
            from = CGPoint(x: startX, y: startY)
            to = CGPoint(x: startX - amount, y: startY)
        default:
            return .error(id: command.id, message: "Invalid direction: \(direction). Use up/down/left/right")
        }

        logger.info("Scroll \(direction) via touch: (\(from.x),\(from.y)) → (\(to.x),\(to.y)) duration=\(duration)s")

        // Visual feedback
        PepperTouchVisualizer.shared.showSwipe(from: from, to: to)

        // Synthesize real touch gesture
        let success = PepperHIDEventSynthesizer.shared.performSwipe(
            from: from, to: to, duration: duration, in: window
        )

        if success {
            return .ok(
                id: command.id,
                data: [
                    "direction": AnyCodable(direction),
                    "amount": AnyCodable(Double(amount)),
                    "duration": AnyCodable(duration),
                    "gesture": AnyCodable([
                        "from": AnyCodable(["x": AnyCodable(Double(from.x)), "y": AnyCodable(Double(from.y))]),
                        "to": AnyCodable(["x": AnyCodable(Double(to.x)), "y": AnyCodable(Double(to.y))]),
                    ]),
                ])
        } else {
            return .error(id: command.id, message: "Scroll gesture failed — touch synthesis unavailable")
        }
    }

    // MARK: - Helpers

    private func findAncestorScrollView(of view: UIView) -> UIScrollView? {
        var current = view.superview
        while let parent = current {
            if let scrollView = parent as? UIScrollView {
                return scrollView
            }
            current = parent.superview
        }
        return nil
    }

    private func findScrollViewByClass(_ className: String, in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            let typeName = String(describing: type(of: scrollView))
            if typeName.contains(className) {
                return scrollView
            }
        }
        for subview in view.subviews {
            if let found = findScrollViewByClass(className, in: subview) {
                return found
            }
        }
        return nil
    }

    private func findFirstScrollView(in view: UIView) -> UIScrollView? {
        // Look for the most prominent scroll view (usually the main content)
        if let scrollView = view as? UIScrollView, scrollView.contentSize.height > scrollView.bounds.height {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findFirstScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

}
