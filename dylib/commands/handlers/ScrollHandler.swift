import UIKit
import os

/// Handles scroll commands:
///   {"cmd": "scroll", "params": {"text": "Settings"}}            -- scroll text into view (smart, nav-bar-aware)
///   {"cmd": "scroll", "params": {"element": "accessibility_id"}} -- scroll element into view by a11y ID
///   {"cmd": "scroll", "params": {"direction": "down", "distance": 300}}
///   {"cmd": "scroll", "params": {"position": "top"}}
///
/// Amount defaults to 200pt (~¼ screen on iPhone 16 Pro, 852pt tall).
/// Fine: 50–100pt. Coarse: 400–600pt. Full screen: ~750–850pt depending on device.
struct ScrollHandler: PepperHandler {
    let commandName = "scroll"
    private var logger: Logger { PepperLogger.logger(category: "scroll") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        do {
            return try performScroll(command)
        } catch {
            return .error(id: command.id, message: "[scroll] \(error.localizedDescription)")
        }
    }

    private func performScroll(_ command: PepperCommand) throws -> PepperResponse {
        guard let window = UIWindow.pepper_keyWindow else {
            throw PepperHandlerError.noKeyWindow
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

        throw PepperHandlerError.missingParam("position, element, or direction")
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

        return .action(
            id: command.id, action: "scroll", target: position,
            extra: [
                "description": AnyCodable("Scrolled to \(position)"),
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
            return .action(
                id: command.id, action: "scroll", target: "'\(text)' (already visible)",
                extra: [
                    "description": AnyCodable(
                        "'\(text)' already visible at (\(Int(elementCenter.x)),\(Int(elementCenter.y)))"),
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

        return .action(
            id: command.id, action: "scroll", target: "'\(text)'",
            extra: [
                "description": AnyCodable("Scrolled to '\(text)' at (\(Int(finalCenter.x)),\(Int(finalCenter.y)))"),
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
        guard let result = PepperElementResolver.resolveByID(elementID, in: window) else {
            return .error(id: command.id, message: "Element not found: \(elementID)")
        }
        if result.tapPoint != nil {
            return .error(
                id: command.id,
                message: "Element \(elementID) is a SwiftUI element without a UIView — scroll_to requires a UIKit view")
        }
        let element = result.view

        // Find the nearest ancestor scroll view
        guard let scrollView = findAncestorScrollView(of: element) else {
            return .error(id: command.id, message: "No scroll view ancestor found for: \(elementID)")
        }

        logger.info("Scrolling to element: \(elementID)")
        let frame = element.convert(element.bounds, to: scrollView)
        scrollView.scrollRectToVisible(frame, animated: false)

        return .action(
            id: command.id, action: "scroll", target: elementID,
            extra: [
                "description": AnyCodable("Scrolled to '\(elementID)'"),
                "scrollOffset": AnyCodable([
                    "x": AnyCodable(scrollView.contentOffset.x),
                    "y": AnyCodable(scrollView.contentOffset.y),
                ]),
            ])
    }

    // MARK: - Scroll by direction (touch synthesis)

    /// Resolve scroll view targeting params to the target scroll view and its center point.
    /// Returns nil if no targeting param matched (caller should use screen center with HID).
    private func resolveScrollTarget(
        command: PepperCommand, scrollViewID: String?, scrollViewClass: String?, in window: UIWindow
    ) -> (scrollView: UIScrollView, center: CGPoint)? {
        if let id = scrollViewID,
            let resolved = PepperElementResolver.resolveByID(id, in: window),
            resolved.tapPoint == nil,
            let scrollView = resolved.view as? UIScrollView
        {
            let center = scrollView.convert(
                CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: window)
            return (scrollView, center)
        }
        if let className = scrollViewClass,
            let scrollView = findScrollViewByClass(className, in: window)
        {
            let center = scrollView.convert(
                CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: window)
            return (scrollView, center)
        }
        if let parentText = command.params?["parent_of"]?.stringValue {
            let axis = command.params?["axis"]?.stringValue
            let (result, _) = PepperElementResolver.resolve(params: ["text": AnyCodable(parentText)], in: window)
            if let result = result,
                let sv = findAncestorScrollView(of: result.view, axis: axis)
            {
                let center = sv.convert(
                    CGPoint(x: sv.bounds.midX, y: sv.bounds.midY), to: window)
                return (sv, center)
            }
            logger.warning("parent_of '\(parentText)' — no matching scroll view found")
        }
        if let atY = command.params?["at_y"]?.doubleValue {
            let point = CGPoint(x: window.bounds.midX, y: CGFloat(atY))
            if let sv = findScrollViewAtPoint(point, in: window) {
                let center = sv.convert(
                    CGPoint(x: sv.bounds.midX, y: sv.bounds.midY), to: window)
                return (sv, center)
            }
            logger.warning("at_y \(atY) — no scroll view found at that position")
        }
        return nil
    }

    private func scrollByDirection(
        _ direction: String, amount: CGFloat, scrollViewID: String?, scrollViewClass: String?, in window: UIWindow,
        command: PepperCommand
    ) -> PepperResponse {
        let duration = command.params?["duration"]?.doubleValue ?? 0.4

        // Resolve targeted scroll view (if any scoping param was provided)
        let resolved = resolveScrollTarget(
            command: command, scrollViewID: scrollViewID, scrollViewClass: scrollViewClass, in: window)

        // When we have a resolved scroll view on a presented sheet, use direct contentOffset
        // manipulation to bypass HID hit-testing (which routes touches to the view behind the sheet).
        if let resolved = resolved, isViewOnPresentedSheet(resolved.scrollView) {
            return scrollDirectly(
                resolved.scrollView, direction: direction, amount: amount, command: command)
        }

        // Determine gesture start point — center of targeted scroll view, or screen center
        var startX = window.bounds.midX
        var startY = window.bounds.midY

        if let resolved = resolved {
            startX = resolved.center.x
            startY = resolved.center.y
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
            return .action(
                id: command.id, action: "scroll", target: "\(direction) \(Int(amount))pt",
                extra: [
                    "description": AnyCodable("Scrolled \(direction) \(Int(amount))pt"),
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

    /// Scroll a specific scroll view by manipulating contentOffset directly.
    /// Used when HID touch injection would be routed to a view behind a sheet.
    private func scrollDirectly(
        _ scrollView: UIScrollView, direction: String, amount: CGFloat, command: PepperCommand
    ) -> PepperResponse {
        let inset = scrollView.adjustedContentInset
        var newOffset = scrollView.contentOffset

        switch direction.lowercased() {
        case "down":
            let maxY = max(scrollView.contentSize.height - scrollView.bounds.height + inset.bottom, -inset.top)
            newOffset.y = min(newOffset.y + amount, maxY)
        case "up":
            newOffset.y = max(newOffset.y - amount, -inset.top)
        case "right":
            let maxX = max(scrollView.contentSize.width - scrollView.bounds.width + inset.right, -inset.left)
            newOffset.x = min(newOffset.x + amount, maxX)
        case "left":
            newOffset.x = max(newOffset.x - amount, -inset.left)
        default:
            return .error(id: command.id, message: "Invalid direction: \(direction). Use up/down/left/right")
        }

        logger.info(
            "Scroll \(direction) direct: offset (\(scrollView.contentOffset.x),\(scrollView.contentOffset.y)) → (\(newOffset.x),\(newOffset.y))"
        )
        scrollView.setContentOffset(newOffset, animated: true)

        return .action(
            id: command.id, action: "scroll", target: "\(direction) \(Int(amount))pt",
            extra: [
                "description": AnyCodable("Scrolled \(direction) \(Int(amount))pt (direct)"),
                "direction": AnyCodable(direction),
                "amount": AnyCodable(Double(amount)),
                "method": AnyCodable("direct"),
                "scrollOffset": AnyCodable([
                    "x": AnyCodable(Double(newOffset.x)),
                    "y": AnyCodable(Double(newOffset.y)),
                ]),
            ])
    }

    // MARK: - Presentation-aware helpers

    /// Check if a view is inside a presented sheet or modal (same logic as tap's Tier 1).
    private func isViewOnPresentedSheet(_ view: UIView) -> Bool {
        guard let vc = ElementDiscoveryBridge.shared.findOwningViewController(for: view) else { return false }
        let ctx = ElementDiscoveryBridge.shared.presentationContext(of: vc)
        return ctx == "sheet" || ctx == "modal" || ctx == "popover"
    }

    /// Get the view hierarchy root for the topmost presented view controller, if any.
    private func topmostPresentedView(in window: UIWindow) -> UIView? {
        var vc = window.rootViewController
        while let presented = vc?.presentedViewController {
            vc = presented
        }
        // Only return if it's actually presented (not the root)
        guard let top = vc, top.presentingViewController != nil else { return nil }
        return top.view
    }

    private func findAncestorScrollView(of view: UIView, axis: String? = nil) -> UIScrollView? {
        var current = view.superview
        while let parent = current {
            if let scrollView = parent as? UIScrollView {
                guard let axis = axis else { return scrollView }
                let scrollsH = scrollView.contentSize.width > scrollView.bounds.width + 1
                let scrollsV = scrollView.contentSize.height > scrollView.bounds.height + 1
                if axis == "horizontal" && scrollsH { return scrollView }
                if axis == "vertical" && scrollsV { return scrollView }
                // Doesn't match requested axis — continue walking up
            }
            current = parent.superview
        }
        return nil
    }

    private func findScrollViewAtPoint(_ point: CGPoint, in window: UIWindow) -> UIScrollView? {
        let scrollViews = ElementDiscoveryBridge.shared.collectScrollViews()
        var bestMatch: UIScrollView?
        var bestArea: CGFloat = .greatestFiniteMagnitude
        var bestOnSheet = false

        for info in scrollViews {
            if info.frameInWindow.contains(point) {
                let area = info.frameInWindow.width * info.frameInWindow.height
                let onSheet = isViewOnPresentedSheet(info.scrollView)
                // Prefer scroll views on presented sheets over background ones
                if onSheet && !bestOnSheet {
                    bestMatch = info.scrollView
                    bestArea = area
                    bestOnSheet = true
                } else if onSheet == bestOnSheet && area < bestArea {
                    bestMatch = info.scrollView
                    bestArea = area
                }
            }
        }
        return bestMatch
    }

    private func findScrollViewByClass(_ className: String, in window: UIWindow) -> UIScrollView? {
        // Search presented sheet hierarchy first
        if let presentedView = topmostPresentedView(in: window) {
            if let found = findScrollViewByClassRecursive(className, in: presentedView) {
                return found
            }
        }
        return findScrollViewByClassRecursive(className, in: window)
    }

    private func findScrollViewByClassRecursive(_ className: String, in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            let typeName = String(describing: type(of: scrollView))
            if typeName.contains(className) {
                return scrollView
            }
        }
        for subview in view.subviews {
            if let found = findScrollViewByClassRecursive(className, in: subview) {
                return found
            }
        }
        return nil
    }

    private func findFirstScrollView(in window: UIWindow) -> UIScrollView? {
        // If a sheet/modal is presented, search its view hierarchy first
        if let presentedView = topmostPresentedView(in: window) {
            if let found = findFirstScrollViewRecursive(in: presentedView) {
                return found
            }
        }
        return findFirstScrollViewRecursive(in: window)
    }

    private func findFirstScrollViewRecursive(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView, scrollView.contentSize.height > scrollView.bounds.height {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findFirstScrollViewRecursive(in: subview) {
                return found
            }
        }
        return nil
    }

}
