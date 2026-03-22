import SwiftUI
import UserNotifications

@main
struct PepperTestApp: App {
    @State private var appState = AppState()
    @State private var deeplinkRoute: String?
    @State private var deeplinkParams: [String: String] = [:]

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
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
        deeplinkRoute = url.host ?? url.path
        var params: [String: String] = [:]
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for item in components.queryItems ?? [] {
                params[item.name] = item.value ?? ""
            }
        }
        deeplinkParams = params
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

// MARK: - App Delegate (notifications + seeding)

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        AppSeeding.seedAll()
        return true
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
