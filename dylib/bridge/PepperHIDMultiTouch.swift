import UIKit
import os

// MARK: - Multi-Touch Gesture Synthesis
// Two-finger gestures (pinch, rotate) via IOHIDEvent injection.
// Uses the same HID pipeline as single-finger tap/swipe — creates a parent
// hand event with two finger sub-events appended.

extension PepperHIDEventSynthesizer {

    /// Finger indices for two-finger gestures.
    /// Same hand (right index + right middle) — matches real two-finger pinch anatomy.
    /// Cross-hand indices (e.g. rightIndex + leftIndex) can confuse gesture recognizers
    /// that validate anatomical plausibility.
    private static let fingerIndex1: UInt32 = 2  // rightIndex
    private static let fingerIndex2: UInt32 = 3  // rightMiddle

    // MARK: - Pinch Gesture

    /// Perform a pinch gesture with two fingers moving toward/away from center.
    /// - Parameters:
    ///   - center: Center point of the pinch gesture
    ///   - startDistance: Initial distance between fingers (points)
    ///   - endDistance: Final distance between fingers (points). Less than start = pinch in, greater = pinch out.
    ///   - duration: Gesture duration in seconds
    ///   - window: Target window for event injection
    /// - Returns: true if the gesture was synthesized successfully
    func performPinch(
        center: CGPoint,
        startDistance: CGFloat,
        endDistance: CGFloat,
        duration: TimeInterval = 0.5,
        in window: UIWindow
    ) -> Bool {
        _ = Self.setup

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
        let id1 = nextEventId; nextEventId += 1
        let id2 = nextEventId; nextEventId += 1

        let fps = Double(UIScreen.main.maximumFramesPerSecond)
        let steps = max(Int(duration * fps), 10)
        let stepDuration = duration / Double(steps)

        logger.info("HID pinch at (\(center.x),\(center.y)) dist \(startDistance)→\(endDistance), \(steps) steps")

        // Calculate finger positions at interpolation parameter t (0..1).
        // Fingers move horizontally, symmetric around center.
        func positions(at t: CGFloat) -> (CGPoint, CGPoint) {
            let dist = startDistance + (endDistance - startDistance) * t
            return (
                CGPoint(x: center.x - dist / 2, y: center.y),
                CGPoint(x: center.x + dist / 2, y: center.y)
            )
        }

        let (start1, start2) = positions(at: 0)

        // Transition-aware settle (same logic as tap — gesture recognizers need
        // extra time after navigation transitions to rewire).
        let timeSinceTransition = PepperState.shared.timeSinceLastTransition
        let settleTime: TimeInterval = timeSinceTransition < PepperDefaults.transitionRecencyWindow ? PepperDefaults.postTransitionSettleTime : 0.016
        RunLoop.current.run(until: Date(timeIntervalSinceNow: settleTime))

        // === Touch Began (both fingers simultaneously) ===
        sendTwoFingerEvent(
            api: api, app: appPrivate, contextId: contextId,
            point1: start1, point2: start2,
            id1: id1, id2: id2,
            fingerIndex1: Self.fingerIndex1, fingerIndex2: Self.fingerIndex2,
            phase: .began
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))

        // === Touch Moved (intermediate positions) ===
        for i in 1..<steps {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: stepDuration))
            let t = CGFloat(i) / CGFloat(steps)
            let (p1, p2) = positions(at: t)
            sendTwoFingerEvent(
                api: api, app: appPrivate, contextId: contextId,
                point1: p1, point2: p2,
                id1: id1, id2: id2,
                fingerIndex1: Self.fingerIndex1, fingerIndex2: Self.fingerIndex2,
                phase: .moved
            )
        }

        // === Touch Ended ===
        let (end1, end2) = positions(at: 1)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: stepDuration))
        sendTwoFingerEvent(
            api: api, app: appPrivate, contextId: contextId,
            point1: end1, point2: end2,
            id1: id1, id2: id2,
            fingerIndex1: Self.fingerIndex1, fingerIndex2: Self.fingerIndex2,
            phase: .ended
        )

        // Wait for delivery confirmation or fall back to fixed timing
        if !waitForMarker(timeout: 0.5, in: window) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        }

        PepperSwiftUIBridge.shared.invalidateCache()
        logger.info("HID pinch completed")
        return true
    }

    // MARK: - Rotate Gesture

    /// Perform a rotation gesture with two fingers rotating around center.
    /// - Parameters:
    ///   - center: Center point of the rotation
    ///   - angle: Rotation angle in degrees (positive = clockwise)
    ///   - radius: Distance from center to each finger (points)
    ///   - duration: Gesture duration in seconds
    ///   - window: Target window for event injection
    /// - Returns: true if the gesture was synthesized successfully
    func performRotate(
        center: CGPoint,
        angle: CGFloat,
        radius: CGFloat,
        duration: TimeInterval = 0.5,
        in window: UIWindow
    ) -> Bool {
        _ = Self.setup

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
        let id1 = nextEventId; nextEventId += 1
        let id2 = nextEventId; nextEventId += 1

        let fps = Double(UIScreen.main.maximumFramesPerSecond)
        let steps = max(Int(duration * fps), 10)
        let stepDuration = duration / Double(steps)
        let angleRadians = angle * .pi / 180

        logger.info("HID rotate at (\(center.x),\(center.y)) angle=\(angle)° radius=\(radius), \(steps) steps")

        // Calculate finger positions at interpolation parameter t (0..1).
        // Two fingers sit on opposite sides of the center, rotating together.
        // Finger 1 starts at angle 0 (right), finger 2 at angle pi (left).
        func positions(at t: CGFloat) -> (CGPoint, CGPoint) {
            let currentAngle = angleRadians * t
            let p1 = CGPoint(
                x: center.x + radius * cos(currentAngle),
                y: center.y + radius * sin(currentAngle)
            )
            let p2 = CGPoint(
                x: center.x + radius * cos(currentAngle + .pi),
                y: center.y + radius * sin(currentAngle + .pi)
            )
            return (p1, p2)
        }

        let (start1, start2) = positions(at: 0)

        // Transition-aware settle (same logic as tap)
        let timeSinceTransition = PepperState.shared.timeSinceLastTransition
        let rotateSettleTime: TimeInterval = timeSinceTransition < PepperDefaults.transitionRecencyWindow ? PepperDefaults.postTransitionSettleTime : 0.016
        RunLoop.current.run(until: Date(timeIntervalSinceNow: rotateSettleTime))

        // === Touch Began ===
        sendTwoFingerEvent(
            api: api, app: appPrivate, contextId: contextId,
            point1: start1, point2: start2,
            id1: id1, id2: id2,
            fingerIndex1: Self.fingerIndex1, fingerIndex2: Self.fingerIndex2,
            phase: .began
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))

        // === Touch Moved ===
        for i in 1..<steps {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: stepDuration))
            let t = CGFloat(i) / CGFloat(steps)
            let (p1, p2) = positions(at: t)
            sendTwoFingerEvent(
                api: api, app: appPrivate, contextId: contextId,
                point1: p1, point2: p2,
                id1: id1, id2: id2,
                fingerIndex1: Self.fingerIndex1, fingerIndex2: Self.fingerIndex2,
                phase: .moved
            )
        }

        // === Touch Ended ===
        let (end1, end2) = positions(at: 1)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: stepDuration))
        sendTwoFingerEvent(
            api: api, app: appPrivate, contextId: contextId,
            point1: end1, point2: end2,
            id1: id1, id2: id2,
            fingerIndex1: Self.fingerIndex1, fingerIndex2: Self.fingerIndex2,
            phase: .ended
        )

        // Wait for delivery confirmation or fall back to fixed timing
        if !waitForMarker(timeout: 0.5, in: window) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        }

        PepperSwiftUIBridge.shared.invalidateCache()
        logger.info("HID rotate completed")
        return true
    }

    // MARK: - Two-Finger Event Helper

    /// Send a two-finger HID event (parent hand event with two finger sub-events).
    /// Used by both pinch and rotate gestures.
    ///
    /// Key differences from single-finger sendFingerEvent:
    /// - Parent hand event carries centroid position of both fingers
    /// - Hand event mask includes .position during .moved phase (required for
    ///   multi-touch gesture recognizers like UIPinchGestureRecognizer to see updates)
    /// - Finger events include non-zero pressure (some gesture recognizers, notably
    ///   Google Maps' GMSMapView, validate pressure to distinguish real touches)
    func sendTwoFingerEvent(
        api: HIDEventAPI, app: PepperApplicationHIDPrivate, contextId: UInt32,
        point1: CGPoint, point2: CGPoint,
        id1: UInt32, id2: UInt32,
        fingerIndex1: UInt32, fingerIndex2: UInt32,
        phase: TouchPhase
    ) {
        let machTime = mach_absolute_time()

        // Centroid of both fingers — the parent hand event should report the
        // aggregate position so gesture recognizers can track the gesture center.
        let centroid = CGPoint(
            x: (point1.x + point2.x) / 2,
            y: (point1.y + point2.y) / 2
        )

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
            // Critical for multi-touch: parent hand event MUST include .position
            // during moves. Without it, UIKit's multi-touch routing doesn't propagate
            // position changes to compound gesture recognizers (pinch, rotate).
            // Single-finger events get away with handMask=[] because UIKit reads the
            // single child directly, but multi-touch aggregates from the parent.
            fingerMask = [.position]
            handMask = [.position]
            isRange = true
            isTouch = true
        case .ended:
            fingerMask = [.touch, .range]
            handMask = [.touch]
            isRange = false
            isTouch = false
        }

        // Parent hand event — container for both finger sub-events.
        // Carries centroid position so gesture recognizers can track the gesture.
        let event = api.createDigitizerEvent(
            kCFAllocatorDefault, machTime,
            HIDEventAPI.digitizerTransducerTypeHand, 0, 0,
            handMask.rawValue, 0,
            centroid.x, centroid.y, 0,
            0, 0,
            isRange, isTouch,
            kHIDEventOptionNone
        )

        api.eventSetIntegerValue(event, HIDEventAPI.fieldIsDisplayIntegrated, 1)
        api.eventSetSenderID(event, senderID)

        // Non-zero pressure for finger events. Some gesture recognizers (notably
        // Google Maps' GMSMapView) check pressure to validate real touch contact.
        // Zero pressure signals "synthetic" and may cause gesture rejection.
        let pressure: CGFloat = isTouch ? 0.1 : 0

        // Finger 1 sub-event
        let finger1 = api.createDigitizerFingerEvent(
            kCFAllocatorDefault, machTime,
            id1, fingerIndex1,
            fingerMask.rawValue,
            point1.x, point1.y, 0,
            pressure, 0,
            isRange, isTouch,
            kHIDEventOptionNone
        )
        api.eventSetFloatValue(finger1, HIDEventAPI.fieldMajorRadius, fingerRadius)
        api.eventSetFloatValue(finger1, HIDEventAPI.fieldMinorRadius, fingerRadius)
        api.eventAppendEvent(event, finger1, 0)

        // Finger 2 sub-event
        let finger2 = api.createDigitizerFingerEvent(
            kCFAllocatorDefault, machTime,
            id2, fingerIndex2,
            fingerMask.rawValue,
            point2.x, point2.y, 0,
            pressure, 0,
            isRange, isTouch,
            kHIDEventOptionNone
        )
        api.eventSetFloatValue(finger2, HIDEventAPI.fieldMajorRadius, fingerRadius)
        api.eventSetFloatValue(finger2, HIDEventAPI.fieldMinorRadius, fingerRadius)
        api.eventAppendEvent(event, finger2, 0)

        // Stamp with window context and enqueue
        api.setDigitizerInfo(event, contextId, false, false, nil, 0, 0)
        app.enqueueHIDEvent(event)
    }
}
