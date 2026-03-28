import UIKit
import os

/// Observes UIAccessibility and UIKit notifications for event-driven screen change detection.
///
/// Captures:
///   - screen_changed: view controller appeared (UIViewController.viewDidAppear swizzle)
///   - layout_changed: window became key (modals, alerts, sheets)
///   - announcement: VoiceOver announcement finished
///   - focus_changed: VoiceOver/AT element focus change
///
/// Maintains a ring buffer (up to 500 events). When active, `wait_for` uses the
/// `changeSemaphore` to wake immediately on events instead of sleeping the full
/// poll interval.
///
/// Usage:
///   PepperAccessibilityObserver.shared.start()
///   // ... trigger UI actions ...
///   let events = PepperAccessibilityObserver.shared.drainEvents()
///   PepperAccessibilityObserver.shared.stop()
final class PepperAccessibilityObserver {
    static let shared = PepperAccessibilityObserver()

    private let queue = DispatchQueue(label: "com.pepper.ax-observer", attributes: .concurrent)
    private var logger: Logger { PepperLogger.logger(category: "ax-observer") }

    // Ring buffer
    private var events: [AccessibilityEvent] = []
    private(set) var maxEvents = 500

    // State
    private var isActive = false
    private var tokens: [NSObjectProtocol] = []
    private(set) var totalReceived = 0
    private(set) var totalDropped = 0

    // Wake signal for wait_for integration — counting semaphore, signalled on each event.
    let changeSemaphore = DispatchSemaphore(value: 0)

    struct AccessibilityEvent {
        let type: String  // "screen_changed", "layout_changed", "announcement", "focus_changed"
        let timestampMs: Int64
        let announcement: String?  // Non-nil for announcement events
        let elementLabel: String?  // Focused element label (focus_changed events)
    }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        queue.async(flags: .barrier) { [self] in
            guard !isActive else { return }
            isActive = true
            DispatchQueue.main.async { self.registerObservers() }
            logger.info("Accessibility observer started")
        }
    }

    func stop() {
        queue.async(flags: .barrier) { [self] in
            guard isActive else { return }
            isActive = false
            DispatchQueue.main.async { self.unregisterObservers() }
            logger.info("Accessibility observer stopped")
        }
    }

    // MARK: - Observer Registration (main thread)

    private func registerObservers() {
        let nc = NotificationCenter.default

        // VoiceOver announcement finished — NSNotificationName const, goes through NotificationCenter.
        let announcementObs = nc.addObserver(
            forName: NSNotification.Name("UIAccessibilityAnnouncementDidFinishNotification"),
            object: nil, queue: nil
        ) { [weak self] notification in
            self?.recordAnnouncement(notification: notification)
        }

        // Assistive-technology element focus change — fires on VoiceOver/Switch Control navigation.
        let focusObs = nc.addObserver(
            forName: NSNotification.Name("UIAccessibilityElementFocusedNotification"),
            object: nil, queue: nil
        ) { [weak self] notification in
            self?.recordFocusChange(notification: notification)
        }

        // Window becoming key — fires when modals, alerts, or sheets are presented.
        let windowObs = nc.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.signalEvent(type: "layout_changed")
        }

        queue.async(flags: .barrier) { [self] in
            tokens = [announcementObs, focusObs, windowObs]
        }
    }

    private func unregisterObservers() {
        let tokensToRemove: [NSObjectProtocol] = queue.sync { tokens }
        tokensToRemove.forEach { NotificationCenter.default.removeObserver($0) }
        queue.async(flags: .barrier) { [self] in tokens = [] }
    }

    // MARK: - Recording (called from NotificationCenter callbacks and VC swizzle)

    /// Signal a screen_changed event — called from `pepper_viewDidAppear`.
    func signalScreenChanged() {
        signalEvent(type: "screen_changed")
    }

    private func signalEvent(type: String) {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        appendEvent(AccessibilityEvent(type: type, timestampMs: ts, announcement: nil, elementLabel: nil))
    }

    private func recordAnnouncement(notification: Notification) {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        // UIAccessibilityAnnouncementKeyStringValue is the user info key for the spoken string
        let text = notification.userInfo?["UIAccessibilityAnnouncementKeyStringValue"] as? String
        appendEvent(AccessibilityEvent(type: "announcement", timestampMs: ts, announcement: text, elementLabel: nil))
    }

    private func recordFocusChange(notification: Notification) {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        var label: String? = nil
        // UIAccessibilityFocusedElementKey carries the newly-focused element
        if let obj = notification.userInfo?["UIAccessibilityFocusedElementKey"] {
            if let view = obj as? UIView {
                label = view.accessibilityLabel
            } else if let ax = obj as? UIAccessibilityElement {
                label = ax.accessibilityLabel
            }
        }
        appendEvent(AccessibilityEvent(type: "focus_changed", timestampMs: ts, announcement: nil, elementLabel: label))
    }

    private func appendEvent(_ event: AccessibilityEvent) {
        queue.async(flags: .barrier) { [self] in
            guard isActive else { return }
            events.append(event)
            totalReceived += 1
            if events.count > maxEvents {
                let overflow = events.count - maxEvents
                totalDropped += overflow
                events.removeFirst(overflow)
            }
        }
        // Signal outside barrier so waiters don't re-enter the queue
        changeSemaphore.signal()
    }

    // MARK: - Queries

    var isRunning: Bool { queue.sync { isActive } }
    var eventCount: Int { queue.sync { events.count } }

    /// Drain recent events, newest last.
    func drainEvents(limit: Int = 100, sinceMs: Int64? = nil) -> [[String: Any]] {
        queue.sync {
            var filtered = events
            if let since = sinceMs {
                filtered = filtered.filter { $0.timestampMs > since }
            }
            return Array(filtered.suffix(limit)).map { event -> [String: Any] in
                var dict: [String: Any] = [
                    "type": event.type,
                    "timestamp_ms": Int(event.timestampMs),
                ]
                if let label = event.elementLabel { dict["element_label"] = label }
                if let text = event.announcement { dict["announcement"] = text }
                return dict
            }
        }
    }

    /// Update buffer size. If shrinking, oldest events are evicted.
    func setMaxEvents(_ size: Int) {
        guard size > 0 else { return }
        queue.async(flags: .barrier) { [self] in
            maxEvents = size
            if events.count > size {
                let overflow = events.count - size
                totalDropped += overflow
                events.removeFirst(overflow)
            }
        }
    }

    func clearEvents() {
        queue.async(flags: .barrier) { [self] in events.removeAll() }
    }

    /// Block until an accessibility event fires or `timeout` elapses.
    /// Returns `true` if an event arrived before the timeout.
    func waitForChange(timeout: TimeInterval) -> Bool {
        changeSemaphore.wait(timeout: .now() + timeout) == .success
    }
}
