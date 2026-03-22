import UIKit
import os

// MARK: - IOHIDEvent Private API Bindings
// Uses dlsym to load IOKit/BackBoardServices private functions at runtime.

@objc protocol PepperHIDEvent: NSObjectProtocol {}

@objc protocol PepperApplicationHIDPrivate: NSObjectProtocol {
    @objc(_enqueueHIDEvent:)
    func enqueueHIDEvent(_ event: PepperHIDEvent)
}

@objc protocol PepperWindowContextPrivate: NSObjectProtocol {
    @objc(_contextId)
    var contextId: UInt32 { get }
}

let kHIDEventOptionNone: CFOptionFlags = 0

/// Lazily-loaded function pointers into IOKit and BackBoardServices private frameworks.
struct HIDEventAPI {
    typealias CreateDigitizerEvent = @convention(c) (
        _ allocator: CFAllocator?, _ timestamp: UInt64,
        _ transducerType: UInt32, _ index: UInt32, _ identifier: UInt32,
        _ eventMask: UInt32, _ buttonEvent: UInt32,
        _ x: CGFloat, _ y: CGFloat, _ z: CGFloat,
        _ pressure: CGFloat, _ twist: CGFloat,
        _ isRange: Bool, _ isTouch: Bool, _ options: CFOptionFlags
    ) -> PepperHIDEvent

    typealias CreateDigitizerFingerEvent = @convention(c) (
        _ allocator: CFAllocator?, _ timestamp: UInt64,
        _ identifier: UInt32, _ fingerIndex: UInt32,
        _ eventMask: UInt32,
        _ x: CGFloat, _ y: CGFloat, _ z: CGFloat,
        _ pressure: CGFloat, _ twist: CGFloat,
        _ isRange: Bool, _ isTouch: Bool, _ options: CFOptionFlags
    ) -> PepperHIDEvent

    typealias EventAppendEvent = @convention(c) (
        _ event: PepperHIDEvent, _ subEvent: PepperHIDEvent, _ options: CFOptionFlags
    ) -> Void

    typealias EventSetIntegerValue = @convention(c) (
        _ event: PepperHIDEvent, _ field: UInt32, _ value: Int
    ) -> Void

    typealias EventSetFloatValue = @convention(c) (
        _ event: PepperHIDEvent, _ field: UInt32, _ value: CGFloat
    ) -> Void

    typealias EventSetSenderID = @convention(c) (
        _ event: PepperHIDEvent, _ senderID: UInt64
    ) -> Void

    typealias SetDigitizerInfo = @convention(c) (
        _ event: PepperHIDEvent, _ contextID: UInt32,
        _ systemGestureIsPossible: Bool, _ isSystemGestureStateChangeEvent: Bool,
        _ displayUUID: CFString?, _ initialTouchTimestamp: CFTimeInterval,
        _ maxForce: Float
    ) -> Void

    // Vendor-defined event for marker support (Feature 3: HID marker events)
    typealias CreateVendorDefinedEvent = @convention(c) (
        _ allocator: CFAllocator?, _ timestamp: UInt64,
        _ usagePage: UInt32, _ usage: UInt32,
        _ version: UInt32, _ data: UnsafePointer<UInt8>?, _ length: Int,
        _ options: CFOptionFlags
    ) -> PepperHIDEvent

    // Read integer field from an IOHIDEvent (used by marker event detection)
    typealias EventGetIntegerValue = @convention(c) (
        _ event: PepperHIDEvent, _ field: UInt32
    ) -> Int

    let createDigitizerEvent: CreateDigitizerEvent
    let createDigitizerFingerEvent: CreateDigitizerFingerEvent
    let eventAppendEvent: EventAppendEvent
    let eventSetIntegerValue: EventSetIntegerValue
    let eventSetFloatValue: EventSetFloatValue
    let eventSetSenderID: EventSetSenderID
    let setDigitizerInfo: SetDigitizerInfo

    // Optional: loaded separately so core functionality works even if unavailable
    var createVendorDefinedEvent: CreateVendorDefinedEvent?
    var eventGetIntegerValue: EventGetIntegerValue?

    private static var logger: Logger { PepperLogger.logger(category: "hid-api") }

    /// Whether the HID event API was successfully loaded.
    static var isAvailable: Bool { shared != nil }

    static let shared: HIDEventAPI? = {
        let iokitPath = "/System/Library/Frameworks/IOKit.framework/IOKit"
        let bbsPath = "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices"
        let iosVersion = UIDevice.current.systemVersion

        guard let iokitHandle = dlopen(iokitPath, RTLD_NOW) else {
            logger.error("Failed to dlopen IOKit (iOS \(iosVersion))")
            return nil
        }
        guard let bbsHandle = dlopen(bbsPath, RTLD_NOW) else {
            logger.error("Failed to dlopen BackBoardServices (iOS \(iosVersion))")
            return nil
        }

        let symbols: [(String, UnsafeMutableRawPointer?)] = [
            ("IOHIDEventCreateDigitizerEvent", dlsym(iokitHandle, "IOHIDEventCreateDigitizerEvent")),
            ("IOHIDEventCreateDigitizerFingerEvent", dlsym(iokitHandle, "IOHIDEventCreateDigitizerFingerEvent")),
            ("IOHIDEventAppendEvent", dlsym(iokitHandle, "IOHIDEventAppendEvent")),
            ("IOHIDEventSetIntegerValue", dlsym(iokitHandle, "IOHIDEventSetIntegerValue")),
            ("IOHIDEventSetFloatValue", dlsym(iokitHandle, "IOHIDEventSetFloatValue")),
            ("IOHIDEventSetSenderID", dlsym(iokitHandle, "IOHIDEventSetSenderID")),
            ("BKSHIDEventSetDigitizerInfo", dlsym(bbsHandle, "BKSHIDEventSetDigitizerInfo")),
        ]

        for (name, ptr) in symbols {
            guard ptr != nil else {
                logger.error("Failed to resolve \(name)")
                return nil
            }
        }

        var api = HIDEventAPI(
            createDigitizerEvent: unsafeBitCast(symbols[0].1!, to: CreateDigitizerEvent.self),
            createDigitizerFingerEvent: unsafeBitCast(symbols[1].1!, to: CreateDigitizerFingerEvent.self),
            eventAppendEvent: unsafeBitCast(symbols[2].1!, to: EventAppendEvent.self),
            eventSetIntegerValue: unsafeBitCast(symbols[3].1!, to: EventSetIntegerValue.self),
            eventSetFloatValue: unsafeBitCast(symbols[4].1!, to: EventSetFloatValue.self),
            eventSetSenderID: unsafeBitCast(symbols[5].1!, to: EventSetSenderID.self),
            setDigitizerInfo: unsafeBitCast(symbols[6].1!, to: SetDigitizerInfo.self)
        )

        // Optional: vendor-defined event + integer getter for marker support.
        // If these can't be loaded, marker events are skipped (graceful degradation).
        if let vendorSym = dlsym(iokitHandle, "IOHIDEventCreateVendorDefinedEvent") {
            api.createVendorDefinedEvent = unsafeBitCast(vendorSym, to: CreateVendorDefinedEvent.self)
        }
        if let getSym = dlsym(iokitHandle, "IOHIDEventGetIntegerValue") {
            api.eventGetIntegerValue = unsafeBitCast(getSym, to: EventGetIntegerValue.self)
        }

        return api
    }()

    // Digitizer field constants (from IOKit headers)
    static let digitizerTransducerTypeHand: UInt32 = 3
    static let fieldIsDisplayIntegrated: UInt32 = 0xB0019
    static let fieldMajorRadius: UInt32 = 0xB0014
    static let fieldMinorRadius: UInt32 = 0xB0015

    // Vendor-defined event field constants (for marker events)
    static let fieldVendorDefinedUsagePage: UInt32 = 0x00220001
    static let fieldVendorDefinedUsage: UInt32 = 0x00220002
    static let fieldVendorDefinedDataLength: UInt32 = 0x00220005
    // IOHIDEvent type for vendor-defined events
    static let eventTypeVendorDefined: UInt32 = 22

    // Event masks for digitizer events
    struct EventMask: OptionSet {
        let rawValue: UInt32
        static let range = EventMask(rawValue: 1 << 0)
        static let touch = EventMask(rawValue: 1 << 1)
        static let position = EventMask(rawValue: 1 << 2)
    }
}

// MARK: - HID Event Synthesizer

/// Synthesizes touch events at the IOHIDEvent layer via _enqueueHIDEvent.
/// This enters the touch pipeline before UIKit, making it work for both
/// UIKit controls and SwiftUI views — the system creates proper UITouch
/// objects from the HID event, identical to real hardware input.
final class PepperHIDEventSynthesizer {
    static let shared = PepperHIDEventSynthesizer()
    var logger: Logger { PepperLogger.logger(category: "hid-synth") }

    var nextEventId: UInt32 = 100
    let senderID: UInt64 = 0x0000000123456789
    let fingerRadius: CGFloat = 5
    let fingerIndex: UInt32 = 2  // rightIndex

    // Marker event infrastructure (Feature 3: deterministic event delivery)
    var markerCallbacks: [UInt32: () -> Void] = [:]
    var nextMarkerID: UInt32 = 1
    static let markerUsagePage: UInt32 = 0xFF00  // Vendor-defined usage page

    /// One-time protocol conformance setup.
    static let setup: Void = {
        class_addProtocol(UIApplication.self, PepperApplicationHIDPrivate.self)
        class_addProtocol(UIWindow.self, PepperWindowContextPrivate.self)
    }()

    /// Perform a tap at a point via IOHIDEvent injection.
    /// Sends touch-began then touch-ended through the HID pipeline.
    /// Must be called on the main thread.
    func performTap(at point: CGPoint, in window: UIWindow, duration: TimeInterval = 0.1) -> Bool {
        _ = PepperHIDEventSynthesizer.setup

        guard let api = HIDEventAPI.shared else {
            logger.error("HID event APIs not available — dlsym failed")
            return false
        }

        guard let windowPrivate = window as? PepperWindowContextPrivate else {
            logger.error("Cannot access window _contextId")
            return false
        }

        guard let appPrivate = UIApplication.shared as? PepperApplicationHIDPrivate else {
            logger.error("Cannot access UIApplication _enqueueHIDEvent:")
            return false
        }

        let contextId = windowPrivate.contextId
        let identifier = nextEventId
        nextEventId += 1

        // Pre-tap settle: flush pending layout passes, gesture recognizer setup,
        // and animation callbacks. After a navigation transition (pop/push/modal
        // dismiss), UIKit needs extra time to rewire gesture recognizers and
        // finalize the responder chain. The standard 16ms (1 frame) is enough for
        // stable UI, but post-transition settling needs ~100ms.
        let timeSinceTransition = PepperState.shared.timeSinceLastTransition
        let settleTime: TimeInterval = timeSinceTransition < PepperDefaults.transitionRecencyWindow ? PepperDefaults.postTransitionSettleTime : 0.016
        RunLoop.current.run(until: Date(timeIntervalSinceNow: settleTime))

        logger.info("HID tap at (\(point.x), \(point.y)), contextId=\(contextId), id=\(identifier)")

        // === Touch Began ===
        sendFingerEvent(
            api: api, app: appPrivate, contextId: contextId,
            point: point, identifier: identifier, phase: .began
        )

        // Hold for specified duration (default 100ms — matches real human tap timing,
        // ensures gesture recognizers have time to evaluate the touch).
        // For long presses (>0.3s), send periodic stationary events to keep
        // UILongPressGestureRecognizer alive. Stationary events use .position mask
        // (not .touch/.range) — they report "finger is still here" rather than
        // "touch state changed." This matches Hammer/EarlGrey behavior.
        if duration > 0.3 {
            let holdEnd = Date(timeIntervalSinceNow: duration)
            let stationaryInterval: TimeInterval = 0.05
            while Date() < holdEnd {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: stationaryInterval))
                if Date() < holdEnd {
                    sendFingerEvent(
                        api: api, app: appPrivate, contextId: contextId,
                        point: point, identifier: identifier,
                        phase: .stationary
                    )
                }
            }
        } else {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: duration))
        }

        // === Touch Ended ===
        sendFingerEvent(
            api: api, app: appPrivate, contextId: contextId,
            point: point, identifier: identifier, phase: .ended
        )

        // Wait for HID event delivery confirmation via marker, fall back to fixed timing
        if !waitForMarker(timeout: 0.5, in: window) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        // Invalidate introspect cache — UI state may have changed
        PepperSwiftUIBridge.shared.invalidateCache()

        logger.info("HID tap completed")
        return true
    }

    /// Perform a double-tap at a point via IOHIDEvent injection.
    /// Two rapid taps with a short gap — triggers UITapGestureRecognizer with numberOfTapsRequired=2.
    /// Must be called on the main thread.
    func performDoubleTap(at point: CGPoint, in window: UIWindow) -> Bool {
        _ = PepperHIDEventSynthesizer.setup

        guard let api = HIDEventAPI.shared else {
            logger.error("HID event APIs not available — dlsym failed")
            return false
        }

        guard let windowPrivate = window as? PepperWindowContextPrivate else {
            logger.error("Cannot access window _contextId")
            return false
        }

        guard let appPrivate = UIApplication.shared as? PepperApplicationHIDPrivate else {
            logger.error("Cannot access UIApplication _enqueueHIDEvent:")
            return false
        }

        let contextId = windowPrivate.contextId

        // Pre-tap settle
        let timeSinceTransition = PepperState.shared.timeSinceLastTransition
        let settleTime: TimeInterval = timeSinceTransition < PepperDefaults.transitionRecencyWindow ? PepperDefaults.postTransitionSettleTime : 0.016
        RunLoop.current.run(until: Date(timeIntervalSinceNow: settleTime))

        logger.info("HID double-tap at (\(point.x), \(point.y)), contextId=\(contextId)")

        // First tap
        let id1 = nextEventId
        nextEventId += 1
        sendFingerEvent(api: api, app: appPrivate, contextId: contextId,
                        point: point, identifier: id1, phase: .began)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.04))
        sendFingerEvent(api: api, app: appPrivate, contextId: contextId,
                        point: point, identifier: id1, phase: .ended)

        // Inter-tap gap (40ms — fast enough for double-tap recognition, matches real hardware)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.04))

        // Second tap
        let id2 = nextEventId
        nextEventId += 1
        sendFingerEvent(api: api, app: appPrivate, contextId: contextId,
                        point: point, identifier: id2, phase: .began)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.04))
        sendFingerEvent(api: api, app: appPrivate, contextId: contextId,
                        point: point, identifier: id2, phase: .ended)

        // Wait for delivery
        if !waitForMarker(timeout: 0.5, in: window) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        PepperSwiftUIBridge.shared.invalidateCache()
        logger.info("HID double-tap completed")
        return true
    }

    /// Perform a swipe/drag gesture from one point to another via IOHIDEvent injection.
    /// Sends touch-began → moved × N → touch-ended through the HID pipeline.
    /// Same event path as performTap — works for UIKit and SwiftUI scroll views.
    /// Must be called on the main thread. Blocks until complete.
    func performSwipe(
        from start: CGPoint,
        to end: CGPoint,
        duration: TimeInterval = 0.3,
        in window: UIWindow
    ) -> Bool {
        _ = PepperHIDEventSynthesizer.setup

        guard let api = HIDEventAPI.shared else {
            logger.error("HID event APIs not available — dlsym failed")
            return false
        }

        guard let windowPrivate = window as? PepperWindowContextPrivate else {
            logger.error("Cannot access window _contextId")
            return false
        }

        guard let appPrivate = UIApplication.shared as? PepperApplicationHIDPrivate else {
            logger.error("Cannot access UIApplication _enqueueHIDEvent:")
            return false
        }

        let contextId = windowPrivate.contextId
        let identifier = nextEventId
        nextEventId += 1

        let fps = Double(UIScreen.main.maximumFramesPerSecond)
        let steps = max(Int(duration * fps), 10)
        let stepDuration = duration / Double(steps)

        logger.info("HID swipe (\(start.x),\(start.y)) → (\(end.x),\(end.y)), \(steps) steps, duration=\(duration)s")

        // Pre-swipe settle (transition-aware, same logic as tap)
        let timeSinceTransition = PepperState.shared.timeSinceLastTransition
        let settleTime: TimeInterval = timeSinceTransition < PepperDefaults.transitionRecencyWindow ? PepperDefaults.postTransitionSettleTime : 0.016
        RunLoop.current.run(until: Date(timeIntervalSinceNow: settleTime))

        // === Touch Began ===
        sendFingerEvent(
            api: api, app: appPrivate, contextId: contextId,
            point: start, identifier: identifier, phase: .began
        )

        // Small delay for gesture recognizer setup
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))

        // === Touch Moved (intermediate points) ===
        for i in 1..<steps {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: stepDuration))

            let t = CGFloat(i) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            sendFingerEvent(
                api: api, app: appPrivate, contextId: contextId,
                point: point, identifier: identifier, phase: .moved
            )
        }

        // === Touch Ended ===
        RunLoop.current.run(until: Date(timeIntervalSinceNow: stepDuration))
        sendFingerEvent(
            api: api, app: appPrivate, contextId: contextId,
            point: end, identifier: identifier, phase: .ended
        )

        // Wait for HID event delivery confirmation via marker, fall back to fixed timing
        if !waitForMarker(timeout: 0.5, in: window) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        }

        // Invalidate introspect cache — UI state may have changed
        PepperSwiftUIBridge.shared.invalidateCache()

        logger.info("HID swipe completed")
        return true
    }

    enum TouchPhase {
        case began      // Finger touched screen
        case moved      // Finger moved (position changed)
        case stationary // Finger is still down (same position)
        case ended      // Finger lifted
    }

    func sendFingerEvent(
        api: HIDEventAPI, app: PepperApplicationHIDPrivate, contextId: UInt32,
        point: CGPoint, identifier: UInt32, phase: TouchPhase
    ) {
        let machTime = mach_absolute_time()

        // Event masks describe WHAT CHANGED in this event:
        // - .touch/.range = touch/range state changed (began/ended)
        // - .position = position update only (stationary/moved)
        // isRange/isTouch describe CURRENT STATE of the finger.
        let fingerMask: HIDEventAPI.EventMask
        let handMask: HIDEventAPI.EventMask
        let isRange: Bool
        let isTouch: Bool

        switch phase {
        case .began:
            fingerMask = [.touch, .range]
            handMask = [.touch]
            isRange = true
            isTouch = true
        case .moved, .stationary:
            fingerMask = [.position]
            handMask = []  // .position ∩ [.touch, .attribute] = ∅
            isRange = true
            isTouch = true
        case .ended:
            fingerMask = [.touch, .range]
            handMask = [.touch]
            isRange = false
            isTouch = false
        }

        // Parent digitizer event (hand container)
        let event = api.createDigitizerEvent(
            kCFAllocatorDefault, machTime,
            HIDEventAPI.digitizerTransducerTypeHand, 0, 0,
            handMask.rawValue, 0,
            0, 0, 0, 0, 0,
            false, isTouch,
            kHIDEventOptionNone
        )

        api.eventSetIntegerValue(event, HIDEventAPI.fieldIsDisplayIntegrated, 1)
        api.eventSetSenderID(event, senderID)

        // Finger sub-event
        let finger = api.createDigitizerFingerEvent(
            kCFAllocatorDefault, machTime,
            identifier, fingerIndex,
            fingerMask.rawValue,
            point.x, point.y, 0,
            0, 0,  // pressure, twist
            isRange, isTouch,
            kHIDEventOptionNone
        )

        api.eventSetFloatValue(finger, HIDEventAPI.fieldMajorRadius, fingerRadius)
        api.eventSetFloatValue(finger, HIDEventAPI.fieldMinorRadius, fingerRadius)
        api.eventAppendEvent(event, finger, 0)

        // Stamp with window context and enqueue into HID pipeline
        api.setDigitizerInfo(event, contextId, false, false, nil, 0, 0)
        app.enqueueHIDEvent(event)
    }
}
