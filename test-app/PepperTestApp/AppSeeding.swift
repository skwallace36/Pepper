import Foundation
import Security
import UserNotifications
import SQLite3

enum AppSeeding {
    static func seedAll() {
        seedUserDefaults()
        seedKeychain()
        seedSandboxFiles()
        seedSQLiteDatabase()
        CoreDataStack.seedIfNeeded()
        IntrospectionSingleton.shared.initialize()
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
        guard let tokenData = "pepper-test-12345".data(using: .utf8) else { return }

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

    // MARK: - SQLite Database

    /// Seeds a pre-populated SQLite database at Library/Application Support/pepper_test.db.
    /// Tables: users (TEXT/INTEGER/REAL), posts (TEXT/INTEGER/BLOB), settings (TEXT/INTEGER).
    /// ~10 rows per table. Used by the `db` command test surface.
    static func seedSQLiteDatabase() {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbURL = appSupport.appendingPathComponent("pepper_test.db")
        guard !FileManager.default.fileExists(atPath: dbURL.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            print("[PepperTest] SQLite open failed")
            return
        }
        defer { sqlite3_close(db) }

        let schema = """
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY,
                username TEXT NOT NULL,
                email TEXT,
                score REAL,
                active INTEGER,
                avatar_data BLOB
            );
            CREATE TABLE IF NOT EXISTS posts (
                id INTEGER PRIMARY KEY,
                user_id INTEGER,
                title TEXT NOT NULL,
                body TEXT,
                likes INTEGER,
                created_at TEXT
            );
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT,
                type TEXT,
                updated_at INTEGER
            );
        """
        sqlite3_exec(db, schema, nil, nil, nil)

        let users = """
            INSERT INTO users (id, username, email, score, active, avatar_data) VALUES
            (1, 'alice', 'alice@example.com', 98.5, 1, X'89504E47'),
            (2, 'bob', 'bob@example.com', 72.0, 1, NULL),
            (3, 'carol', 'carol@example.com', 55.3, 0, NULL),
            (4, 'dave', 'dave@example.com', 88.1, 1, X'FFD8FFE0'),
            (5, 'eve', 'eve@example.com', 44.9, 1, NULL),
            (6, 'frank', 'frank@example.com', 61.7, 0, NULL),
            (7, 'grace', 'grace@example.com', 93.2, 1, NULL),
            (8, 'henry', 'henry@example.com', 37.5, 1, NULL),
            (9, 'iris', 'iris@example.com', 79.8, 0, NULL),
            (10, 'jack', 'jack@example.com', 50.0, 1, NULL);
        """
        sqlite3_exec(db, users, nil, nil, nil)

        let posts = """
            INSERT INTO posts (id, user_id, title, body, likes, created_at) VALUES
            (1, 1, 'Hello World', 'My first post', 42, '2026-01-01T10:00:00Z'),
            (2, 1, 'SQLite is fast', 'Benchmarks inside', 18, '2026-01-05T12:00:00Z'),
            (3, 2, 'Testing tips', 'Use real data', 7, '2026-01-08T09:00:00Z'),
            (4, 3, 'Pepper rocks', 'Best iOS tool', 33, '2026-01-10T14:00:00Z'),
            (5, 2, 'Core Data vs SQLite', 'Comparison post', 55, '2026-01-12T16:00:00Z'),
            (6, 4, 'SwiftUI tricks', NULL, 11, '2026-01-15T08:00:00Z'),
            (7, 5, 'Debugging in 2026', 'AI-first approach', 29, '2026-01-20T11:00:00Z'),
            (8, 1, 'Draft post', NULL, 0, '2026-02-01T09:00:00Z'),
            (9, 7, 'Accessibility guide', 'For iOS devs', 47, '2026-02-10T13:00:00Z'),
            (10, 10, 'Short post', 'Just a test', 3, '2026-03-01T10:00:00Z');
        """
        sqlite3_exec(db, posts, nil, nil, nil)

        let settings = """
            INSERT INTO settings (key, value, type, updated_at) VALUES
            ('theme', 'dark', 'string', 1740000000),
            ('font_size', '14', 'integer', 1740000100),
            ('auto_save', '1', 'boolean', 1740000200),
            ('sync_enabled', '0', 'boolean', 1740000300),
            ('last_sync', '2026-03-20T12:00:00Z', 'string', 1740000400),
            ('max_retries', '3', 'integer', 1740000500),
            ('timeout_ms', '5000', 'integer', 1740000600),
            ('api_version', 'v2', 'string', 1740000700),
            ('debug_mode', '0', 'boolean', 1740000800),
            ('cache_ttl', '3600', 'integer', 1740000900);
        """
        sqlite3_exec(db, settings, nil, nil, nil)

        print("[PepperTest] Seeded SQLite database at \(dbURL.lastPathComponent): users(10), posts(10), settings(10)")
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
