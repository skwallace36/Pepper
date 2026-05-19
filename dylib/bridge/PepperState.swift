import Foundation
import UIKit

/// Observes navigation changes and tracks the current screen stack.
/// Broadcasts screen_appeared / screen_disappeared events to subscribed clients.
final class PepperState {

    static let shared = PepperState()

    /// Callback for broadcasting events to connected clients.
    /// Set by PepperPlane once the server is running.
    var eventSink: ((PepperEvent) -> Void)?

    /// Current screen stack (most recent last).
    private(set) var screenStack: [String] = []

    /// Lock for thread-safe access to screenStack.
    private let lock = NSLock()

    /// Timestamp of the most recent screen transition. Used by HID tap
    /// synthesis to extend pre-tap settle time when navigation is still in flight.
    /// Access via `timeSinceLastTransition` for thread-safe reads.
    private var _lastScreenTransitionTime: Date = .distantPast

    /// Thread-safe read of time since last screen transition (seconds).
    var timeSinceLastTransition: TimeInterval {
        lock.lock()
        let t = -_lastScreenTransitionTime.timeIntervalSinceNow
        lock.unlock()
        return t
    }

    /// Debounce timer for rapid state changes.
    private var debounceWorkItem: DispatchWorkItem?

    /// Debounce interval in seconds.
    private static let debounceInterval: TimeInterval = PepperDefaults.screenDebounceInterval

    /// Whether swizzling has been installed.
    private static var swizzled = false

    private init() {}

    // MARK: - Setup

    /// Install method swizzling to observe viewDidAppear / viewDidDisappear.
    /// Must be called once on the main thread.
    ///
    /// Uses IMP chaining (method_setImplementation), not method_exchangeImplementations.
    /// Exchange renames the selector on the shared IMP, which breaks instrumentation
    /// agents (NRMA, Sentry, etc.) that assume `_cmd` equals the selector their handler
    /// was attached to — NRMA throws NRInvalidArgumentException in that case.
    func install() {
        guard !Self.swizzled else { return }
        Self.swizzled = true

        PepperVCLifecycleSwizzle.install(
            selector: #selector(UIViewController.viewDidAppear(_:))
        ) { vc, _ in
            PepperState.shared.screenAppeared(vc)
            PepperIdleMonitor.shared.vcDidAppear(vc)
            PepperVarRegistry.shared.discoverFromViewController(vc)
            PepperAccessibilityObserver.shared.signalScreenChanged()

            // Auto-tag interactive elements with accessibility IDs after layout settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak vc] in
                guard let vc else { return }
                PepperAccessibility.shared.tagElements(in: vc)
            }
        }

        PepperVCLifecycleSwizzle.install(
            selector: #selector(UIViewController.viewDidDisappear(_:))
        ) { vc, _ in
            PepperState.shared.screenDisappeared(vc)
            PepperIdleMonitor.shared.vcDidDisappear(vc)
        }

        pepperLog.info("State observation installed", category: .bridge)
    }

    // MARK: - Screen Tracking

    func screenAppeared(_ viewController: UIViewController) {
        let screenID = viewController.pepperScreenID

        // Skip container VCs (nav, tab, etc.) to avoid noise
        if viewController is UINavigationController || viewController is UITabBarController
            || viewController is UISplitViewController
            || (PepperAppConfig.shared.tabBarProvider?.isTabBarContainer(viewController) == true)
        {
            return
        }

        lock.lock()
        // Remove if already in stack (reappearing), then add at the end
        screenStack.removeAll { $0 == screenID }
        screenStack.append(screenID)
        _lastScreenTransitionTime = Date()
        let currentStack = screenStack
        lock.unlock()

        pepperLog.debug("Screen appeared: \(screenID)", category: .bridge)

        // Record to flight recorder
        let vcType = String(describing: Swift.type(of: viewController))
        let depth = viewController.pepper_effectiveNavController?.pepper_effectiveDepth ?? 0
        PepperFlightRecorder.shared.record(type: .screen, summary: "\u{2192} \(screenID) (\(vcType), depth: \(depth))")

        let data = buildScreenEventData(for: viewController, screenID: screenID, stack: currentStack)

        debouncedBroadcast(event: "screen_change", data: data)
    }

    func screenDisappeared(_ viewController: UIViewController) {
        let screenID = viewController.pepperScreenID

        if viewController is UINavigationController || viewController is UITabBarController
            || viewController is UISplitViewController
            || (PepperAppConfig.shared.tabBarProvider?.isTabBarContainer(viewController) == true)
        {
            return
        }

        lock.lock()
        screenStack.removeAll { $0 == screenID }
        let currentStack = screenStack
        lock.unlock()

        pepperLog.debug("Screen disappeared: \(screenID)", category: .bridge)

        // Record to flight recorder
        PepperFlightRecorder.shared.record(type: .screen, summary: "\u{2190} \(screenID)")

        debouncedBroadcast(
            event: "screen_disappeared",
            data: [
                "screen": AnyCodable(screenID),
                "stack": AnyCodable(currentStack.map { AnyCodable($0) }),
            ])
    }

    // MARK: - State Snapshot

    /// Returns the current state as a dictionary suitable for command responses.
    func currentSnapshot() -> [String: AnyCodable] {
        lock.lock()
        let stack = screenStack
        lock.unlock()

        var snapshot: [String: AnyCodable] = [
            "screenStack": AnyCodable(stack.map { AnyCodable($0) })
        ]

        if let topScreen = stack.last {
            snapshot["currentScreen"] = AnyCodable(topScreen)
        }

        return snapshot
    }

    // MARK: - Event Data Builder

    /// Build rich event data for a screen change, including class name, title,
    /// navigation stack depth, and tab info.
    private func buildScreenEventData(for viewController: UIViewController, screenID: String, stack: [String])
        -> [String: AnyCodable]
    {
        var data: [String: AnyCodable] = [
            "screen": AnyCodable(screenID),
            "type": AnyCodable(String(describing: Swift.type(of: viewController))),
            "title": AnyCodable(viewController.title ?? ""),
            "stack": AnyCodable(stack.map { AnyCodable($0) }),
        ]

        // Navigation stack depth
        if let nav = viewController.pepper_effectiveNavController {
            data["nav_stack_depth"] = AnyCodable(nav.pepper_effectiveDepth)
            data["can_go_back"] = AnyCodable(nav.pepper_canPop)
        } else {
            data["nav_stack_depth"] = AnyCodable(0)
            data["can_go_back"] = AnyCodable(viewController.presentingViewController != nil)
        }

        // Tab bar info
        if let customTabBar = viewController.pepper_tabBarController {
            data["tab"] = AnyCodable(customTabBar.pepper_selectedTabName)
            data["tab_count"] = AnyCodable(customTabBar.pepper_tabInfo.count)
        } else if let tabBar = viewController.tabBarController {
            data["tab_index"] = AnyCodable(tabBar.selectedIndex)
            data["tab_count"] = AnyCodable(tabBar.viewControllers?.count ?? 0)
        }

        // Is modal?
        data["is_modal"] = AnyCodable(viewController.presentingViewController != nil)

        return data
    }

    // MARK: - Debounced Broadcasting

    private func debouncedBroadcast(event: String, data: [String: AnyCodable]) {
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.eventSink?(PepperEvent(event: event, data: data))
        }
        debounceWorkItem = workItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.debounceInterval,
            execute: workItem
        )
    }

}
