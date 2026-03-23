import UIKit
import os

// MARK: - HID Marker Events
// Vendor-defined IOHIDEvents used for deterministic event delivery confirmation.
// A marker event round-trips through UIKit's HID pipeline. When the swizzled
// _handleHIDEvent: intercepts it, we know all preceding touch events have been
// processed. This replaces fixed timing waits with event-driven confirmation.

extension PepperHIDEventSynthesizer {

    /// One-time swizzle of UIApplication._handleHIDEvent: to intercept marker events.
    /// Safe to call multiple times — the setup closure only executes once.
    static let markerSwizzleSetup: Void = {
        let sel = NSSelectorFromString("_handleHIDEvent:")
        guard let originalMethod = class_getInstanceMethod(UIApplication.self, sel) else {
            let log = PepperLogger.logger(category: "hid-marker")
            log.warning("Cannot swizzle _handleHIDEvent: — marker events disabled")
            return
        }

        let originalIMP = method_getImplementation(originalMethod)
        typealias HandleHIDFunc = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let original = unsafeBitCast(originalIMP, to: HandleHIDFunc.self)

        let block: @convention(block) (AnyObject, AnyObject) -> Void = { _self, event in
            // Call original first so UIKit processes the event
            original(_self, sel, event)
            // Then check if this is our marker event
            PepperHIDEventSynthesizer.shared.checkForMarkerEvent(event)
        }

        let newIMP = imp_implementationWithBlock(block)
        method_setImplementation(originalMethod, newIMP)
    }()

    /// Check if an incoming HID event is one of our marker events.
    /// Called from the swizzled _handleHIDEvent: after UIKit processes the event.
    /// If it matches, fires and removes the corresponding callback.
    func checkForMarkerEvent(_ event: AnyObject) {
        guard let api = HIDEventAPI.shared,
            let getInt = api.eventGetIntegerValue,
            let hidEvent = event as? PepperHIDEvent
        else { return }

        // Check if this is a vendor-defined event on our usage page
        let usagePage = getInt(hidEvent, HIDEventAPI.fieldVendorDefinedUsagePage)
        guard usagePage == Int(Self.markerUsagePage) else { return }

        // Extract marker ID from the usage field (we encode it there)
        let markerID = UInt32(getInt(hidEvent, HIDEventAPI.fieldVendorDefinedUsage))
        guard markerID > 0 else { return }

        // Fire and remove the callback
        if let callback = markerCallbacks.removeValue(forKey: markerID) {
            callback()
            logger.debug("Marker \(markerID) confirmed — HID events delivered")
        }
    }

    /// Send a vendor-defined marker event and wait for it to round-trip through UIKit.
    /// When the marker arrives back via _handleHIDEvent:, all preceding touch events
    /// are guaranteed to have been processed.
    ///
    /// Returns true if the marker was delivered within the timeout, false if:
    /// - Vendor-defined event API is not available (graceful degradation)
    /// - The marker wasn't delivered within the timeout
    ///
    /// Falls back to the caller using fixed timing when this returns false.
    func waitForMarker(timeout: TimeInterval = 0.5, in window: UIWindow) -> Bool {
        guard let api = HIDEventAPI.shared,
            let createVendor = api.createVendorDefinedEvent
        else {
            return false
        }

        // Ensure swizzle is set up (no-op after first call)
        _ = Self.markerSwizzleSetup

        let markerID = nextMarkerID
        nextMarkerID += 1

        var delivered = false
        markerCallbacks[markerID] = { delivered = true }

        // Create vendor-defined event with marker ID encoded in the usage field.
        // We use usagePage=0xFF00 (vendor-defined) and usage=markerID for identification.
        // The data buffer carries the marker ID as well for redundancy.
        var idBytes = markerID.littleEndian
        let event: PepperHIDEvent = withUnsafePointer(to: &idBytes) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 4) { bytePtr in
                createVendor(
                    kCFAllocatorDefault, mach_absolute_time(),
                    Self.markerUsagePage, markerID,
                    0, bytePtr, 4,
                    kHIDEventOptionNone
                )
            }
        }

        // Enqueue the marker event into the HID pipeline
        guard let app = UIApplication.shared as? PepperApplicationHIDPrivate else {
            markerCallbacks.removeValue(forKey: markerID)
            return false
        }
        app.enqueueHIDEvent(event)

        // Spin RunLoop until callback fires or timeout expires.
        // 5ms poll interval keeps latency low without busy-spinning.
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !delivered && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }

        // Clean up in case of timeout
        markerCallbacks.removeValue(forKey: markerID)

        if !delivered {
            logger.warning("Marker \(markerID) timed out after \(timeout)s — falling back to fixed timing")
        }

        return delivered
    }
}
