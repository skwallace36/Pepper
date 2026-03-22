import Foundation
import Security
import UserNotifications

enum AppSeeding {
    static func seedAll() {
        seedUserDefaults()
        seedKeychain()
        requestNotificationPermission()
    }

    // MARK: - UserDefaults

    static func seedUserDefaults() {
        let defaults = UserDefaults.standard
        let seededKey = "pepper_defaults_seeded"
        guard !defaults.bool(forKey: seededKey) else { return }

        defaults.set("pepper-user", forKey: "pepper_username")
        defaults.set(42, forKey: "pepper_score")
        defaults.set(true, forKey: "pepper_onboarded")
        defaults.set(["red", "green", "blue"], forKey: "pepper_colors")
        defaults.set(seededKey, forKey: seededKey)

        print("[PepperTest] UserDefaults seeded")
    }

    // MARK: - Keychain

    static func seedKeychain() {
        let service = "com.pepper.testapp"
        let account = "pepper-test-token"
        let tokenData = "sk-pepper-test-12345".data(using: .utf8)!

        // Check if already seeded
        let checkQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let checkStatus = SecItemCopyMatching(checkQuery as CFDictionary, nil)
        guard checkStatus == errSecItemNotFound else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: tokenData,
            kSecAttrLabel as String: "Pepper Test Token",
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            print("[PepperTest] Keychain entry seeded")
        } else {
            print("[PepperTest] Keychain seed failed: \(status)")
        }
    }

    // MARK: - Notifications

    static func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                print("[PepperTest] Notification permission granted")
            } else if let error {
                print("[PepperTest] Notification permission error: \(error)")
            }
        }
    }
}
