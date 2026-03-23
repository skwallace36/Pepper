import Foundation
import ObjectiveC
import os

/// Tracks NSNotificationCenter observer registrations via ObjC method swizzling.
///
/// When installed, intercepts addObserver/removeObserver calls on NSNotificationCenter.default
/// to maintain a live table of registered observers. Supports listing, filtering by name,
/// counting observers per notification, and posting arbitrary notifications.
///
/// Install/uninstall follows the same start/stop pattern as PepperNetworkInterceptor.
final class PepperNotificationTracker {
    static let shared = PepperNotificationTracker()

    private var logger: Logger { PepperLogger.logger(category: "notifications") }
    private let queue = DispatchQueue(label: "com.pepper.notifications", attributes: .concurrent)

    /// Whether tracking is active.
    private var isActive = false

    /// Whether swizzles have been applied (never reversed).
    private var swizzleApplied = false

    /// Tracked observer registrations keyed by a unique ID.
    private var observers: [String: ObserverRecord] = [:]

    /// Monotonically increasing ID for each registration.
    private var nextId: Int = 1

    /// History of add/remove events for time-based tracking.
    private var events: [ObserverEvent] = []
    private let maxEvents = 2000

    /// Total observers tracked since install.
    private(set) var totalTracked: Int = 0

    var isTracking: Bool {
        queue.sync { isActive }
    }

    struct ObserverRecord {
        let id: String
        let notificationName: String?
        let observerClass: String
        let observerAddress: String
        let selector: String?
        let isBlock: Bool
        let timestamp: Int64
    }

    struct ObserverEvent {
        let action: String  // "add" or "remove"
        let notificationName: String?
        let observerClass: String
        let timestamp: Int64
    }

    private init() {}

    // MARK: - Lifecycle

    func install() {
        queue.async(flags: .barrier) {
            if self.isActive { return }

            if !self.swizzleApplied {
                self.applySwizzles()
                self.swizzleApplied = true
            }

            self.isActive = true
            self.logger.info("NotificationCenter tracking started")
        }
    }

    func uninstall() {
        queue.async(flags: .barrier) {
            self.isActive = false
            self.logger.info("NotificationCenter tracking stopped")
        }
    }

    // MARK: - Recording (called from swizzled methods)

    func recordAddObserver(observer: AnyObject, name: NSNotification.Name?, selector: Selector?) {
        queue.async(flags: .barrier) {
            guard self.isActive else { return }

            let id = "obs_\(self.nextId)"
            self.nextId += 1
            self.totalTracked += 1

            let record = ObserverRecord(
                id: id,
                notificationName: name?.rawValue,
                observerClass: String(describing: type(of: observer)),
                observerAddress: String(format: "%p", unsafeBitCast(observer, to: Int.self)),
                selector: selector.map { NSStringFromSelector($0) },
                isBlock: false,
                timestamp: Int64(Date().timeIntervalSince1970 * 1000)
            )
            self.observers[id] = record

            let event = ObserverEvent(
                action: "add",
                notificationName: name?.rawValue,
                observerClass: record.observerClass,
                timestamp: record.timestamp
            )
            self.appendEvent(event)
        }
    }

    func recordAddBlockObserver(name: NSNotification.Name?, observerRef: AnyObject) {
        queue.async(flags: .barrier) {
            guard self.isActive else { return }

            let id = "obs_\(self.nextId)"
            self.nextId += 1
            self.totalTracked += 1

            let record = ObserverRecord(
                id: id,
                notificationName: name?.rawValue,
                observerClass: String(describing: type(of: observerRef)),
                observerAddress: String(format: "%p", unsafeBitCast(observerRef, to: Int.self)),
                selector: nil,
                isBlock: true,
                timestamp: Int64(Date().timeIntervalSince1970 * 1000)
            )
            self.observers[id] = record

            let event = ObserverEvent(
                action: "add",
                notificationName: name?.rawValue,
                observerClass: record.observerClass,
                timestamp: record.timestamp
            )
            self.appendEvent(event)
        }
    }

    func recordRemoveObserver(observer: AnyObject, name: NSNotification.Name?) {
        queue.async(flags: .barrier) {
            guard self.isActive else { return }

            let address = String(format: "%p", unsafeBitCast(observer, to: Int.self))
            let now = Int64(Date().timeIntervalSince1970 * 1000)

            // Remove matching records
            var removedClass = String(describing: type(of: observer))
            let keysToRemove = self.observers.filter { _, record in
                if record.observerAddress == address {
                    if let name = name {
                        return record.notificationName == name.rawValue
                    }
                    return true  // removeObserver: without name removes all
                }
                return false
            }.map { $0.key }

            if let first = keysToRemove.first, let record = self.observers[first] {
                removedClass = record.observerClass
            }

            for key in keysToRemove {
                self.observers.removeValue(forKey: key)
            }

            let event = ObserverEvent(
                action: "remove",
                notificationName: name?.rawValue,
                observerClass: removedClass,
                timestamp: now
            )
            self.appendEvent(event)
        }
    }

    private func appendEvent(_ event: ObserverEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    // MARK: - Queries

    /// List all tracked observers, optionally filtered by notification name pattern.
    func listObservers(filter: String? = nil, limit: Int = 100) -> [[String: Any]] {
        queue.sync {
            var records = Array(observers.values)

            if let filter = filter, !filter.isEmpty {
                let lower = filter.lowercased()
                records = records.filter { record in
                    (record.notificationName?.lowercased().contains(lower) ?? false)
                    || record.observerClass.lowercased().contains(lower)
                }
            }

            records.sort { $0.timestamp > $1.timestamp }

            return Array(records.prefix(limit)).map { record in
                var dict: [String: Any] = [
                    "id": record.id,
                    "observer_class": record.observerClass,
                    "address": record.observerAddress,
                    "is_block": record.isBlock,
                    "timestamp_ms": record.timestamp,
                ]
                if let name = record.notificationName {
                    dict["notification_name"] = name
                }
                if let sel = record.selector {
                    dict["selector"] = sel
                }
                return dict
            }
        }
    }

    /// Count observers grouped by notification name.
    func countsByName(filter: String? = nil) -> [[String: Any]] {
        queue.sync {
            var counts: [String: Int] = [:]
            for record in observers.values {
                let name = record.notificationName ?? "(unnamed)"
                if let filter = filter, !filter.isEmpty {
                    if !name.lowercased().contains(filter.lowercased()) { continue }
                }
                counts[name, default: 0] += 1
            }

            return counts.sorted { $0.value > $1.value }.map { name, count in
                ["notification_name": name as Any, "observer_count": count as Any]
            }
        }
    }

    /// Get recent add/remove events for time-based tracking.
    func recentEvents(limit: Int = 50, filter: String? = nil) -> [[String: Any]] {
        queue.sync {
            var filtered = events
            if let filter = filter, !filter.isEmpty {
                let lower = filter.lowercased()
                filtered = filtered.filter { event in
                    (event.notificationName?.lowercased().contains(lower) ?? false)
                    || event.observerClass.lowercased().contains(lower)
                }
            }

            return Array(filtered.suffix(limit)).reversed().map { event in
                var dict: [String: Any] = [
                    "action": event.action,
                    "observer_class": event.observerClass,
                    "timestamp_ms": event.timestamp,
                ]
                if let name = event.notificationName {
                    dict["notification_name"] = name
                }
                return dict
            }
        }
    }

    /// Current number of tracked observers.
    var observerCount: Int {
        queue.sync { observers.count }
    }

    /// Current number of tracked events.
    var eventCount: Int {
        queue.sync { events.count }
    }

    func clear() {
        queue.async(flags: .barrier) {
            self.observers.removeAll()
            self.events.removeAll()
            self.totalTracked = 0
            self.nextId = 1
        }
    }

    // MARK: - Post Notification

    func postNotification(name: String, userInfo: [String: Any]?) {
        NotificationCenter.default.post(
            name: NSNotification.Name(name),
            object: nil,
            userInfo: userInfo
        )
    }

    // MARK: - Swizzling

    // Store original IMPs so swizzle is stable.
    private static var origAddObserverIMP: IMP?
    private static var origAddBlockObserverIMP: IMP?
    private static var origRemoveObserverIMP: IMP?
    private static var origRemoveObserverNameIMP: IMP?

    private func applySwizzles() {
        let cls: AnyClass = NotificationCenter.self

        // 1. Swizzle addObserver:selector:name:object:
        let addSel = NSSelectorFromString("addObserver:selector:name:object:")
        if let method = class_getInstanceMethod(cls, addSel) {
            let origIMP = method_getImplementation(method)
            PepperNotificationTracker.origAddObserverIMP = origIMP

            typealias AddFunc = @convention(c) (AnyObject, Selector, AnyObject, Selector, NSNotification.Name?, AnyObject?) -> Void
            let original = unsafeBitCast(origIMP, to: AddFunc.self)

            let block: @convention(block) (AnyObject, AnyObject, Selector, NSNotification.Name?, AnyObject?) -> Void = { center, observer, selector, name, object in
                original(center, addSel, observer, selector, name, object)
                PepperNotificationTracker.shared.recordAddObserver(
                    observer: observer,
                    name: name,
                    selector: selector
                )
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        // 2. Swizzle addObserverForName:object:queue:usingBlock:
        let addBlockSel = NSSelectorFromString("addObserverForName:object:queue:usingBlock:")
        if let method = class_getInstanceMethod(cls, addBlockSel) {
            let origIMP = method_getImplementation(method)
            PepperNotificationTracker.origAddBlockObserverIMP = origIMP

            typealias AddBlockFunc = @convention(c) (AnyObject, Selector, NSNotification.Name?, AnyObject?, OperationQueue?, @escaping (Notification) -> Void) -> AnyObject
            let original = unsafeBitCast(origIMP, to: AddBlockFunc.self)

            let block: @convention(block) (AnyObject, NSNotification.Name?, AnyObject?, OperationQueue?, @escaping (Notification) -> Void) -> AnyObject = { center, name, object, queue, usingBlock in
                let obsRef = original(center, addBlockSel, name, object, queue, usingBlock)
                PepperNotificationTracker.shared.recordAddBlockObserver(
                    name: name,
                    observerRef: obsRef
                )
                return obsRef
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        // 3. Swizzle removeObserver:
        let removeSel = NSSelectorFromString("removeObserver:")
        if let method = class_getInstanceMethod(cls, removeSel) {
            let origIMP = method_getImplementation(method)
            PepperNotificationTracker.origRemoveObserverIMP = origIMP

            typealias RemoveFunc = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            let original = unsafeBitCast(origIMP, to: RemoveFunc.self)

            let block: @convention(block) (AnyObject, AnyObject) -> Void = { center, observer in
                PepperNotificationTracker.shared.recordRemoveObserver(
                    observer: observer,
                    name: nil
                )
                original(center, removeSel, observer)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        // 4. Swizzle removeObserver:name:object:
        let removeNameSel = NSSelectorFromString("removeObserver:name:object:")
        if let method = class_getInstanceMethod(cls, removeNameSel) {
            let origIMP = method_getImplementation(method)
            PepperNotificationTracker.origRemoveObserverNameIMP = origIMP

            typealias RemoveNameFunc = @convention(c) (AnyObject, Selector, AnyObject, NSNotification.Name?, AnyObject?) -> Void
            let original = unsafeBitCast(origIMP, to: RemoveNameFunc.self)

            let block: @convention(block) (AnyObject, AnyObject, NSNotification.Name?, AnyObject?) -> Void = { center, observer, name, object in
                PepperNotificationTracker.shared.recordRemoveObserver(
                    observer: observer,
                    name: name
                )
                original(center, removeNameSel, observer, name, object)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        logger.info("Swizzled NotificationCenter observer methods")
    }
}
