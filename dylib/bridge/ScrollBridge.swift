import UIKit

// MARK: - Scroll Helpers

extension PepperSwiftUIBridge {

    /// Attempt to make a SwiftUI element visible by scrolling its containing scroll view.
    ///
    /// SwiftUI's lazy containers (List, LazyVStack, LazyHStack) only render views
    /// that are on-screen. This method finds the parent scroll view and scrolls
    /// until the target element appears.
    ///
    /// - Returns: `true` if the element was found (possibly after scrolling).
    @discardableResult
    func scrollToElement(id: String, maxAttempts: Int = 10) -> Bool {
        // First check if element is already visible
        if findElement(id: id) != nil {
            return true
        }

        // Find scroll views in the current screen
        guard let rootView = UIWindow.pepper_keyWindow?.rootViewController?.view else { return false }
        let scrollViews = rootView.pepper_findElements(where: { $0 is UIScrollView })

        for scrollViewElement in scrollViews {
            guard let scrollView = scrollViewElement as? UIScrollView else { continue }

            // Try scrolling down in increments
            let pageHeight = scrollView.bounds.height * 0.8
            var attempt = 0

            while attempt < maxAttempts {
                let newY = scrollView.contentOffset.y + pageHeight
                guard newY < scrollView.contentSize.height else { break }

                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newY), animated: false)

                // Give the run loop a chance to lay out
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

                if findElement(id: id) != nil {
                    pepperLog.debug("Found element \(id) after scrolling \(attempt + 1) pages", category: .bridge)
                    return true
                }

                attempt += 1
            }
        }

        pepperLog.warning("Element \(id) not found after scrolling", category: .bridge)
        return false
    }

}
