import EventKit

/// Intercepts EKEventStore authorization requests and auto-grants
/// calendar/reminders access without showing system dialogs.
///
/// Swizzles:
/// - `requestFullAccessToEvents(completion:)` — iOS 17+
/// - `requestFullAccessToReminders(completion:)` — iOS 17+
/// - `requestAccess(to:completion:)` — legacy (pre-iOS 17)
final class PepperEventKitInterceptor {
    static let shared = PepperEventKitInterceptor()
    private var installed = false
    private init() {}

    func install() {
        guard !installed else { return }
        installed = true

        let cls: AnyClass = EKEventStore.self

        // iOS 17+: requestFullAccessToEvents(completion:)
        let eventsSel = NSSelectorFromString("requestFullAccessToEventsWithCompletion:")
        let eventsSwizzledSel = #selector(EKEventStore.pepper_requestFullAccessToEvents(completion:))
        if let original = class_getInstanceMethod(cls, eventsSel),
            let swizzled = class_getInstanceMethod(cls, eventsSwizzledSel)
        {
            method_exchangeImplementations(original, swizzled)
            pepperLog.info("EventKit full events authorization auto-grant installed", category: .lifecycle)
        }

        // iOS 17+: requestFullAccessToReminders(completion:)
        let remindersSel = NSSelectorFromString("requestFullAccessToRemindersWithCompletion:")
        let remindersSwizzledSel = #selector(EKEventStore.pepper_requestFullAccessToReminders(completion:))
        if let original = class_getInstanceMethod(cls, remindersSel),
            let swizzled = class_getInstanceMethod(cls, remindersSwizzledSel)
        {
            method_exchangeImplementations(original, swizzled)
            pepperLog.info("EventKit full reminders authorization auto-grant installed", category: .lifecycle)
        }

        // Legacy: requestAccess(to:completion:)
        let legacySel = NSSelectorFromString("requestAccessToEntityType:completion:")
        let legacySwizzledSel = #selector(EKEventStore.pepper_requestAccess(to:completion:))
        if let original = class_getInstanceMethod(cls, legacySel),
            let swizzled = class_getInstanceMethod(cls, legacySwizzledSel)
        {
            method_exchangeImplementations(original, swizzled)
            pepperLog.info("EventKit legacy authorization auto-grant installed", category: .lifecycle)
        }
    }
}

// MARK: - EKEventStore swizzle

extension EKEventStore {
    /// Swizzled requestFullAccessToEvents(completion:) — auto-grants access.
    @objc dynamic func pepper_requestFullAccessToEvents(
        completion: @escaping (Bool, Error?) -> Void
    ) {
        pepperLog.info("EventKit full events authorization auto-granted", category: .commands)
        completion(true, nil)
    }

    /// Swizzled requestFullAccessToReminders(completion:) — auto-grants access.
    @objc dynamic func pepper_requestFullAccessToReminders(
        completion: @escaping (Bool, Error?) -> Void
    ) {
        pepperLog.info("EventKit full reminders authorization auto-granted", category: .commands)
        completion(true, nil)
    }

    /// Swizzled legacy requestAccess(to:completion:) — auto-grants access.
    @objc dynamic func pepper_requestAccess(
        to entityType: EKEntityType,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        pepperLog.info(
            "EventKit legacy authorization auto-granted (entity: \(entityType.rawValue))", category: .commands)
        completion(true, nil)
    }
}
