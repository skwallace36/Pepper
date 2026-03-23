import SwiftUI
import UserNotifications
import AVFoundation
import CoreLocation
import Contacts
import EventKit
import AppTrackingTransparency

@main
struct PepperTestApp: App {
    @State private var appState = AppState()
    @State private var selectedTab = "controls"
    @State private var deeplinkRoute: String?
    @State private var deeplinkParams: [String: String] = [:]

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Routes that map directly to a tab (no modal needed).
    private static let tabRoutes: Set<String> = ["controls", "list", "misc"]

    var body: some Scene {
        WindowGroup {
            ContentView(selectedTab: $selectedTab)
                .environment(appState)
                .onOpenURL { url in
                    handleDeeplink(url)
                }
                .sheet(item: $deeplinkRoute) { route in
                    NavigationStack {
                        DeeplinkView(route: route, params: deeplinkParams)
                    }
                }
        }
    }

    private func handleDeeplink(_ url: URL) {
        print("[PepperTest] Deeplink received: \(url)")
        guard url.scheme == "peppertest" else { return }

        let route = url.host ?? url.path
        var params: [String: String] = [:]
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for item in components.queryItems ?? [] {
                params[item.name] = item.value ?? ""
            }
        }

        // Tab routes switch the selected tab directly
        if Self.tabRoutes.contains(route) {
            selectedTab = route
            print("[PepperTest] Switched to tab: \(route)")
            return
        }

        // All other routes show a generic deep link modal
        deeplinkRoute = route
        deeplinkParams = params
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

// MARK: - App Delegate (notifications + seeding)

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let locationManager = CLLocationManager()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        AppSeeding.seedAll()
        // Skip permission requests in CI — system dialogs block headless sims.
        // Set PEPPER_SKIP_PERMISSIONS=1 via simctl launch env vars.
        if ProcessInfo.processInfo.environment["PEPPER_SKIP_PERMISSIONS"] == nil {
            requestAllPermissions()
        }
        return true
    }

    /// Request all permission types so Pepper's authorization swizzles can be tested.
    /// On a fresh simctl install, each of these triggers a system dialog.
    /// If Pepper's swizzles are working, the dialogs are auto-granted silently.
    private func requestAllPermissions() {
        // Notifications
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            print("[PepperTest] Notification auth: \(granted)")
        }

        // Camera
        AVCaptureDevice.requestAccess(for: .video) { granted in
            print("[PepperTest] Camera auth: \(granted)")
        }

        // Microphone
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            print("[PepperTest] Microphone auth: \(granted)")
        }

        // Location
        locationManager.requestWhenInUseAuthorization()

        // Contacts
        CNContactStore().requestAccess(for: .contacts) { granted, _ in
            print("[PepperTest] Contacts auth: \(granted)")
        }

        // Calendar
        if #available(iOS 17.0, *) {
            EKEventStore().requestFullAccessToEvents { granted, _ in
                print("[PepperTest] Calendar auth: \(granted)")
            }
        }

        // Tracking (must be called after a short delay — requires UI to be visible)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ATTrackingManager.requestTrackingAuthorization { status in
                print("[PepperTest] Tracking auth: \(status.rawValue)")
            }
        }
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        print("[PepperTest] Notification received in foreground: \(notification.request.content.title)")
        completionHandler([.banner, .sound])
    }

    // Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        print("[PepperTest] Notification tapped: \(response.notification.request.content.title)")
        completionHandler()
    }
}
