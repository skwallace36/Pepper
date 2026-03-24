import UIKit
import UserNotifications
import os

/// Handles {"cmd": "push"} — inject push notifications into the app.
///
/// Commands:
///   {"cmd":"push","params":{"title":"Order update","body":"Your order has shipped!"}}
///     → Deliver a local notification that appears like a remote push
///
///   {"cmd":"push","params":{"title":"Test","body":"Hello","data":{"type":"order_detail","order_id":"123"}}}
///     → Deliver with custom userInfo payload (for deeplink/routing testing)
///
///   {"cmd":"push","params":{"action":"pending"}}
///     → List pending (scheduled) notifications
///
///   {"cmd":"push","params":{"action":"clear"}}
///     → Clear all delivered notifications
struct PushHandler: PepperHandler {
    let commandName = "push"
    private var logger: Logger { PepperLogger.logger(category: "push") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue

        if action == "pending" {
            return handlePending(command)
        } else if action == "clear" {
            return handleClear(command)
        } else {
            return handleDeliver(command)
        }
    }

    // MARK: - Deliver

    private func handleDeliver(_ command: PepperCommand) -> PepperResponse {
        let title = command.params?["title"]?.stringValue ?? "Pepper Test"
        let body = command.params?["body"]?.stringValue ?? ""
        let badge = command.params?["badge"]?.intValue

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        if let badge = badge {
            content.badge = NSNumber(value: badge)
        }

        // Custom data payload (for deeplink routing, etc.)
        if let dataDict = command.params?["data"]?.dictValue {
            var userInfo: [String: Any] = [:]
            for (key, value) in dataDict {
                if let str = value.stringValue {
                    userInfo[key] = str
                } else if let num = value.intValue {
                    userInfo[key] = num
                } else if let bool = value.boolValue {
                    userInfo[key] = bool
                }
            }
            content.userInfo = userInfo
        }

        // Deliver immediately (0.1s trigger)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let id = "pepper-push-\(UUID().uuidString.prefix(8))"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                self.logger.error("Failed to schedule notification: \(error)")
            }
        }

        return .ok(
            id: command.id,
            data: [
                "delivered": AnyCodable(true),
                "notification_id": AnyCodable(id),
                "title": AnyCodable(title),
                "body": AnyCodable(body),
            ])
    }

    // MARK: - Pending

    private func handlePending(_ command: PepperCommand) -> PepperResponse {
        // UNUserNotificationCenter.getPending is async — use semaphore for sync handler
        var pending: [UNNotificationRequest] = []
        let sem = DispatchSemaphore(value: 0)

        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            pending = requests
            sem.signal()
        }

        // Don't block main thread forever
        let result = sem.wait(timeout: .now() + 2)
        if result == .timedOut {
            return .error(id: command.id, message: "Timed out fetching pending notifications")
        }

        let entries = pending.map { req in
            AnyCodable(
                [
                    "id": AnyCodable(req.identifier),
                    "title": AnyCodable(req.content.title),
                    "body": AnyCodable(req.content.body),
                ] as [String: AnyCodable])
        }

        return .ok(
            id: command.id,
            data: [
                "count": AnyCodable(pending.count),
                "pending": AnyCodable(entries),
            ])
    }

    // MARK: - Clear

    private func handleClear(_ command: PepperCommand) -> PepperResponse {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()

        return .ok(id: command.id, data: ["cleared": AnyCodable(true)])
    }
}
