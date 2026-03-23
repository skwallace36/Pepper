import Foundation
import ObjectiveC
import QuartzCore
import os

/// Tracks NSTimer and CADisplayLink instances via ObjC method swizzling.
///
/// When installed, intercepts timer/display-link factory methods to maintain a live
/// table of active instances. Supports listing, filtering, and invalidation.
///
/// Install/uninstall follows the same start/stop pattern as PepperNotificationTracker.
final class PepperTimerTracker {
    static let shared = PepperTimerTracker()

    private var logger: Logger { PepperLogger.logger(category: "timers") }
    private let queue = DispatchQueue(label: "com.pepper.timers", attributes: .concurrent)

    /// Whether tracking is active.
    private var isActive = false

    /// Whether swizzles have been applied (never reversed).
    private var swizzleApplied = false

    /// Tracked timer registrations keyed by unique ID.
    private var timers: [String: TimerRecord] = [:]

    /// Tracked display link registrations keyed by unique ID.
    private var displayLinks: [String: DisplayLinkRecord] = [:]

    /// Monotonically increasing ID for each registration.
    private var nextId: Int = 1

    /// Total items tracked since install.
    private(set) var totalTracked: Int = 0

    struct TimerRecord {
        let id: String
        let address: String
        weak var timer: Timer?
        let targetClass: String
        let selector: String?
        let timeInterval: TimeInterval
        let repeats: Bool
        let isBlock: Bool
        let createdAt: Int64
    }

    struct DisplayLinkRecord {
        let id: String
        let address: String
        weak var displayLink: CADisplayLink?
        let targetClass: String
        let selector: String
        let createdAt: Int64
    }

    private init() {}

    var isTracking: Bool {
        queue.sync { isActive }
    }

    // MARK: - Lifecycle

    func install() {
        queue.async(flags: .barrier) {
            if self.isActive { return }

            if !self.swizzleApplied {
                self.applySwizzles()
                self.swizzleApplied = true
            }

            self.isActive = true
            self.logger.info("Timer tracking started")
        }
    }

    func uninstall() {
        queue.async(flags: .barrier) {
            self.isActive = false
            self.logger.info("Timer tracking stopped")
        }
    }

    // MARK: - Recording (called from swizzled methods)

    func recordTimerCreated(
        _ timer: Timer, targetClass: String, selector: String?,
        repeats: Bool, isBlock: Bool
    ) {
        queue.async(flags: .barrier) {
            guard self.isActive else { return }

            let id = "timer_\(self.nextId)"
            self.nextId += 1
            self.totalTracked += 1

            let address = String(format: "%p", unsafeBitCast(timer, to: Int.self))
            let record = TimerRecord(
                id: id,
                address: address,
                timer: timer,
                targetClass: targetClass,
                selector: selector,
                timeInterval: timer.timeInterval,
                repeats: repeats,
                isBlock: isBlock,
                createdAt: Int64(Date().timeIntervalSince1970 * 1000)
            )
            self.timers[id] = record
        }
    }

    func recordDisplayLinkCreated(
        _ link: CADisplayLink, targetClass: String, selector: String
    ) {
        queue.async(flags: .barrier) {
            guard self.isActive else { return }

            let id = "dlink_\(self.nextId)"
            self.nextId += 1
            self.totalTracked += 1

            let address = String(format: "%p", unsafeBitCast(link, to: Int.self))
            let record = DisplayLinkRecord(
                id: id,
                address: address,
                displayLink: link,
                targetClass: targetClass,
                selector: selector,
                createdAt: Int64(Date().timeIntervalSince1970 * 1000)
            )
            self.displayLinks[id] = record
        }
    }

    // MARK: - Queries

    /// List all tracked active timers, optionally filtered by target class or selector.
    func listTimers(filter: String? = nil, limit: Int = 100) -> [[String: Any]] {
        queue.sync {
            var results: [[String: Any]] = []

            for (_, record) in timers {
                guard let timer = record.timer, timer.isValid else { continue }

                if let filter = filter, !filter.isEmpty {
                    let lower = filter.lowercased()
                    let matchesTarget = record.targetClass.lowercased().contains(lower)
                    let matchesSelector = record.selector?.lowercased().contains(lower) ?? false
                    if !matchesTarget && !matchesSelector { continue }
                }

                var dict: [String: Any] = [
                    "id": record.id,
                    "type": "NSTimer",
                    "address": record.address,
                    "target_class": record.targetClass,
                    "interval": record.timeInterval,
                    "repeats": record.repeats,
                    "is_block": record.isBlock,
                    "is_valid": true,
                    "fire_date": ISO8601DateFormatter().string(from: timer.fireDate),
                    "fire_date_ms": Int64(timer.fireDate.timeIntervalSince1970 * 1000),
                    "created_at_ms": record.createdAt,
                ]
                if let sel = record.selector {
                    dict["selector"] = sel
                }
                if timer.tolerance > 0 {
                    dict["tolerance"] = timer.tolerance
                }
                results.append(dict)
            }

            results.sort { ($0["created_at_ms"] as? Int64 ?? 0) > ($1["created_at_ms"] as? Int64 ?? 0) }
            return Array(results.prefix(limit))
        }
    }

    /// List all tracked active display links, optionally filtered by target class or selector.
    func listDisplayLinks(filter: String? = nil, limit: Int = 100) -> [[String: Any]] {
        queue.sync {
            var results: [[String: Any]] = []

            for (_, record) in displayLinks {
                guard let link = record.displayLink else { continue }

                if let filter = filter, !filter.isEmpty {
                    let lower = filter.lowercased()
                    let matchesTarget = record.targetClass.lowercased().contains(lower)
                    let matchesSelector = record.selector.lowercased().contains(lower)
                    if !matchesTarget && !matchesSelector { continue }
                }

                let dict: [String: Any] = [
                    "id": record.id,
                    "type": "CADisplayLink",
                    "address": record.address,
                    "target_class": record.targetClass,
                    "selector": record.selector,
                    "is_paused": link.isPaused,
                    "preferred_fps": link.preferredFramesPerSecond,
                    "timestamp": link.timestamp,
                    "duration": link.duration,
                    "created_at_ms": record.createdAt,
                ]
                results.append(dict)
            }

            results.sort { ($0["created_at_ms"] as? Int64 ?? 0) > ($1["created_at_ms"] as? Int64 ?? 0) }
            return Array(results.prefix(limit))
        }
    }

    /// Find a tracked timer by ID.
    func findTimer(id: String) -> Timer? {
        queue.sync { timers[id]?.timer }
    }

    /// Find a tracked display link by ID.
    func findDisplayLink(id: String) -> CADisplayLink? {
        queue.sync { displayLinks[id]?.displayLink }
    }

    /// Count of currently valid tracked timers.
    var timerCount: Int {
        queue.sync { timers.values.filter { $0.timer?.isValid == true }.count }
    }

    /// Count of currently alive tracked display links.
    var displayLinkCount: Int {
        queue.sync { displayLinks.values.filter { $0.displayLink != nil }.count }
    }

    func clear() {
        queue.async(flags: .barrier) {
            self.timers.removeAll()
            self.displayLinks.removeAll()
            self.totalTracked = 0
            self.nextId = 1
        }
    }

    /// Remove stale entries (deallocated or invalidated).
    func cleanup() {
        queue.async(flags: .barrier) {
            self.timers = self.timers.filter { $0.value.timer?.isValid == true }
            self.displayLinks = self.displayLinks.filter { $0.value.displayLink != nil }
        }
    }

    // MARK: - Swizzling

    private static var origScheduledTimerTargetIMP: IMP?
    private static var origScheduledTimerBlockIMP: IMP?
    private static var origDisplayLinkCreateIMP: IMP?

    private func applySwizzles() {
        swizzleScheduledTimerTarget()
        swizzleScheduledTimerBlock()
        swizzleDisplayLinkCreate()
        logger.info("Swizzled NSTimer and CADisplayLink factory methods")
    }

    /// Swizzle +[NSTimer scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:]
    private func swizzleScheduledTimerTarget() {
        let cls: AnyClass = Timer.self
        let sel = NSSelectorFromString("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:")
        guard let method = class_getClassMethod(cls, sel) else { return }

        let origIMP = method_getImplementation(method)
        PepperTimerTracker.origScheduledTimerTargetIMP = origIMP

        typealias OrigFunc = @convention(c) (
            AnyObject, Selector, TimeInterval, AnyObject, Selector, AnyObject?, Bool
        ) -> Timer
        let original = unsafeBitCast(origIMP, to: OrigFunc.self)

        let block: @convention(block) (
            AnyObject, TimeInterval, AnyObject, Selector, AnyObject?, Bool
        ) -> Timer = { metaSelf, interval, target, selector, userInfo, repeats in
            let timer = original(metaSelf, sel, interval, target, selector, userInfo, repeats)
            let targetClass = String(describing: type(of: target))
            let selectorName = NSStringFromSelector(selector)
            PepperTimerTracker.shared.recordTimerCreated(
                timer, targetClass: targetClass, selector: selectorName,
                repeats: repeats, isBlock: false
            )
            return timer
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// Swizzle +[NSTimer scheduledTimerWithTimeInterval:repeats:block:]
    private func swizzleScheduledTimerBlock() {
        let cls: AnyClass = Timer.self
        let sel = NSSelectorFromString("scheduledTimerWithTimeInterval:repeats:block:")
        guard let method = class_getClassMethod(cls, sel) else { return }

        let origIMP = method_getImplementation(method)
        PepperTimerTracker.origScheduledTimerBlockIMP = origIMP

        typealias OrigFunc = @convention(c) (
            AnyObject, Selector, TimeInterval, Bool, @escaping (Timer) -> Void
        ) -> Timer
        let original = unsafeBitCast(origIMP, to: OrigFunc.self)

        let block: @convention(block) (
            AnyObject, TimeInterval, Bool, @escaping (Timer) -> Void
        ) -> Timer = { metaSelf, interval, repeats, closure in
            let timer = original(metaSelf, sel, interval, repeats, closure)
            PepperTimerTracker.shared.recordTimerCreated(
                timer, targetClass: "(block)", selector: nil,
                repeats: repeats, isBlock: true
            )
            return timer
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// Swizzle +[CADisplayLink displayLinkWithTarget:selector:]
    private func swizzleDisplayLinkCreate() {
        let cls: AnyClass = CADisplayLink.self
        let sel = NSSelectorFromString("displayLinkWithTarget:selector:")
        guard let method = class_getClassMethod(cls, sel) else { return }

        let origIMP = method_getImplementation(method)
        PepperTimerTracker.origDisplayLinkCreateIMP = origIMP

        typealias OrigFunc = @convention(c) (
            AnyObject, Selector, AnyObject, Selector
        ) -> CADisplayLink
        let original = unsafeBitCast(origIMP, to: OrigFunc.self)

        let block: @convention(block) (
            AnyObject, AnyObject, Selector
        ) -> CADisplayLink = { metaSelf, target, selector in
            let link = original(metaSelf, sel, target, selector)
            let targetClass = String(describing: type(of: target))
            let selectorName = NSStringFromSelector(selector)
            PepperTimerTracker.shared.recordDisplayLinkCreated(
                link, targetClass: targetClass, selector: selectorName
            )
            return link
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
