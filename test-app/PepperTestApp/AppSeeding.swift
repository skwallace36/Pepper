import Foundation
import Security
import UserNotifications

enum AppSeeding {
    static func seedAll() {
        seedUserDefaults()
        seedKeychain()
        seedSandboxFiles()
        if ProcessInfo.processInfo.environment["PEPPER_SKIP_PERMISSIONS"] != "1" {
            requestNotificationPermission()
        }
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
        guard let tokenData = "sk-pepper-test-12345".data(using: .utf8) else { return }

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

    // MARK: - Sandbox Files

    static func seedSandboxFiles() {
        let fm = FileManager.default

        // documents/notes.json
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let notesURL = docs.appendingPathComponent("notes.json")
            if !fm.fileExists(atPath: notesURL.path) {
                let notes: [[String: String]] = [
                    ["id": "1", "title": "First Note", "body": "Hello from Pepper test app"],
                    ["id": "2", "title": "Second Note", "body": "Sandbox file I/O surface"],
                    ["id": "3", "title": "Third Note", "body": "Used for sandbox read/write tests"],
                ]
                if let data = try? JSONSerialization.data(withJSONObject: notes, options: .prettyPrinted) {
                    try? data.write(to: notesURL)
                    print("[PepperTest] Seeded documents/notes.json")
                }
            }

            // documents/settings.plist
            let settingsURL = docs.appendingPathComponent("settings.plist")
            if !fm.fileExists(atPath: settingsURL.path) {
                let settings: [String: Any] = [
                    "theme": "dark",
                    "fontSize": 14,
                    "autoSave": true,
                    "syncEnabled": false,
                    "lastOpened": "2026-03-23",
                ]
                let plistData = try? PropertyListSerialization.data(
                    fromPropertyList: settings, format: .xml, options: 0
                )
                try? plistData?.write(to: settingsURL)
                print("[PepperTest] Seeded documents/settings.plist")
            }
        }

        // caches/cached-image.txt
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let cachedImageURL = caches.appendingPathComponent("cached-image.txt")
            if !fm.fileExists(atPath: cachedImageURL.path) {
                let placeholder = "PLACEHOLDER_IMAGE_DATA: 1024x768 JPEG cached asset [pepper-test]"
                try? placeholder.write(to: cachedImageURL, atomically: true, encoding: .utf8)
                print("[PepperTest] Seeded caches/cached-image.txt")
            }
        }

        // tmp/temp-data.txt
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("temp-data.txt")
        if !fm.fileExists(atPath: tmpURL.path) {
            let content = "Temporary data seeded by PepperTestApp at launch.\nSession: pepper-test-session-001"
            try? content.write(to: tmpURL, atomically: true, encoding: .utf8)
            print("[PepperTest] Seeded tmp/temp-data.txt")
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
