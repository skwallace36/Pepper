import AVFoundation
import AppTrackingTransparency
import Contacts
import CoreLocation
import EventKit
import Photos
import UIKit
import UserNotifications

/// Handles {"cmd": "swizzle_check"} — verifies each authorization swizzle
/// actually intercepts the real API call.
///
/// For each swizzled method, calls the API and checks whether the completion
/// handler fired synchronously with the expected auto-grant value.
/// A swizzle that was "installed" but fails to intercept will leave the
/// completion unfired (real API is async and shows a system dialog).
///
/// Returns structured pass/fail results per swizzle.
struct SwizzleCheckHandler: PepperHandler {
    let commandName = "swizzle_check"
    let timeout: TimeInterval = 5.0

    func handle(_ command: PepperCommand) throws -> PepperResponse {
        // If permission swizzles were skipped, report that instead of failing
        if ProcessInfo.processInfo.environment["PEPPER_SKIP_PERMISSIONS"] == "1" {
            return .result(id: command.id, [
                "pass": AnyCodable(true),
                "skipped": AnyCodable(true),
                "reason": AnyCodable("Authorization swizzles disabled (PEPPER_SKIP_PERMISSIONS=1)"),
            ])
        }

        var results: [[String: AnyCodable]] = []

        results.append(checkNotifications())
        results.append(checkPhotos())
        results.append(checkTracking())
        results.append(checkCamera())
        results.append(checkContacts())
        results.append(checkLocation())
        results.append(checkEventKitEvents())
        results.append(checkEventKitReminders())

        let passed = results.filter { ($0["pass"]?.value as? Bool) == true }.count
        let failed = results.count - passed

        return .result(id: command.id, [
            "pass": AnyCodable(failed == 0),
            "passed": AnyCodable(passed),
            "failed": AnyCodable(failed),
            "total": AnyCodable(results.count),
            "results": AnyCodable(results.map { AnyCodable($0) }),
        ])
    }

    // MARK: - Individual Checks

    /// Calls requestAuthorization and checks completion fires synchronously with granted=true.
    private func checkNotifications() -> [String: AnyCodable] {
        var granted: Bool?
        var err: Error?
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { g, e in
            granted = g
            err = e
        }
        if granted == true && err == nil {
            return passed("notifications", detail: "requestAuthorization auto-granted")
        }
        return failed("notifications",
                       reason: "Completion not called synchronously — swizzle did not intercept",
                       detail: "granted=\(granted.map(String.init(describing:)) ?? "nil")")
    }

    /// Calls requestAuthorization(for:handler:) and checks .authorized returned synchronously.
    private func checkPhotos() -> [String: AnyCodable] {
        var status: PHAuthorizationStatus?
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
            status = s
        }
        if status == .authorized {
            return passed("photos", detail: "requestAuthorization auto-granted")
        }
        return failed("photos",
                       reason: "Completion not called synchronously — swizzle did not intercept",
                       detail: "status=\(status.map { String($0.rawValue) } ?? "nil")")
    }

    /// Calls requestTrackingAuthorization and checks .authorized returned synchronously.
    private func checkTracking() -> [String: AnyCodable] {
        var status: ATTrackingManager.AuthorizationStatus?
        ATTrackingManager.requestTrackingAuthorization { s in
            status = s
        }
        if status == .authorized {
            return passed("tracking", detail: "ATT auto-granted")
        }
        return failed("tracking",
                       reason: "Completion not called synchronously — swizzle did not intercept",
                       detail: "status=\(status.map { String($0.rawValue) } ?? "nil")")
    }

    /// Calls requestAccess(for:completionHandler:) and checks true returned synchronously.
    private func checkCamera() -> [String: AnyCodable] {
        var granted: Bool?
        AVCaptureDevice.requestAccess(for: .video) { g in
            granted = g
        }
        if granted == true {
            return passed("camera", detail: "Camera access auto-granted")
        }
        return failed("camera",
                       reason: "Completion not called synchronously — swizzle did not intercept",
                       detail: "granted=\(granted.map(String.init(describing:)) ?? "nil")")
    }

    /// Calls requestAccess(for:completionHandler:) and checks true returned synchronously.
    private func checkContacts() -> [String: AnyCodable] {
        var granted: Bool?
        var err: Error?
        CNContactStore().requestAccess(for: .contacts) { g, e in
            granted = g
            err = e
        }
        if granted == true && err == nil {
            return passed("contacts", detail: "Contacts access auto-granted")
        }
        return failed("contacts",
                       reason: "Completion not called synchronously — swizzle did not intercept",
                       detail: "granted=\(granted.map(String.init(describing:)) ?? "nil")")
    }

    /// Checks location swizzle — the swizzle is a no-op that suppresses the system dialog.
    /// We verify the method IMP differs from the original selector's default, confirming
    /// the swizzle was applied. We can't test via callback since the API is void-returning.
    private func checkLocation() -> [String: AnyCodable] {
        let cls: AnyClass = CLLocationManager.self
        let originalSel = NSSelectorFromString("requestWhenInUseAuthorization")
        let swizzledSel = #selector(CLLocationManager.pepper_requestWhenInUseAuthorization)

        guard let originalMethod = class_getInstanceMethod(cls, originalSel),
              let swizzledMethod = class_getInstanceMethod(cls, swizzledSel)
        else {
            return failed("location", reason: "Could not resolve method selectors")
        }

        let originalIMP = method_getImplementation(originalMethod)
        let swizzledIMP = method_getImplementation(swizzledMethod)

        // After method_setImplementation, the original selector's IMP should point
        // to our replacement. If they match, the swizzle is installed.
        if originalIMP == swizzledIMP {
            return passed("location", detail: "requestWhenInUseAuthorization replaced with no-op")
        }
        return failed("location",
                       reason: "IMP mismatch — swizzle may not have been applied")
    }

    /// Calls requestFullAccessToEvents and checks true returned synchronously.
    private func checkEventKitEvents() -> [String: AnyCodable] {
        var granted: Bool?
        var err: Error?
        EKEventStore().requestFullAccessToEvents { g, e in
            granted = g
            err = e
        }
        if granted == true && err == nil {
            return passed("eventkit_events", detail: "Full events access auto-granted")
        }
        return failed("eventkit_events",
                       reason: "Completion not called synchronously — swizzle did not intercept",
                       detail: "granted=\(granted.map(String.init(describing:)) ?? "nil")")
    }

    /// Calls requestFullAccessToReminders and checks true returned synchronously.
    private func checkEventKitReminders() -> [String: AnyCodable] {
        var granted: Bool?
        var err: Error?
        EKEventStore().requestFullAccessToReminders { g, e in
            granted = g
            err = e
        }
        if granted == true && err == nil {
            return passed("eventkit_reminders", detail: "Full reminders access auto-granted")
        }
        return failed("eventkit_reminders",
                       reason: "Completion not called synchronously — swizzle did not intercept",
                       detail: "granted=\(granted.map(String.init(describing:)) ?? "nil")")
    }

    // MARK: - Result Helpers

    private func passed(_ name: String, detail: String) -> [String: AnyCodable] {
        [
            "name": AnyCodable(name),
            "pass": AnyCodable(true),
            "detail": AnyCodable(detail),
        ]
    }

    private func failed(_ name: String, reason: String, detail: String? = nil) -> [String: AnyCodable] {
        var result: [String: AnyCodable] = [
            "name": AnyCodable(name),
            "pass": AnyCodable(false),
            "reason": AnyCodable(reason),
        ]
        if let detail = detail {
            result["detail"] = AnyCodable(detail)
        }
        return result
    }
}
