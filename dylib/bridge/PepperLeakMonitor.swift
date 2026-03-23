import Foundation
import CommonCrypto

/// Tracks heap instance counts per screen and detects growth (potential leaks).
///
/// On every introspect map call, the monitor:
/// 1. Builds a screen key from the screen ID + element fingerprint
/// 2. Runs a heap scan (via C bridge, ~10-50ms)
/// 3. If returning to a previously-seen screen, diffs and reports growing classes
/// 4. Saves the current snapshot
///
/// The element fingerprint solves the type-erased screen problem:
/// when multiple screens share the same VC class (common in SwiftUI),
/// the fingerprint distinguishes them by their content.
final class PepperLeakMonitor {

    static let shared = PepperLeakMonitor()
    private init() {}

    /// Serial queue for synchronizing all mutable state access.
    private let queue = DispatchQueue(label: "com.pepper.control.leak-monitor")

    /// Per-screen snapshots: screen_key → (class_name → instance_count)
    private var screenSnapshots: [String: [String: Int]] = [:]

    /// Accumulated leak warnings (ring buffer, newest first)
    private var warnings: [LeakWarning] = []
    private let maxWarnings = 50

    struct LeakWarning {
        let screenKey: String
        let className: String
        let before: Int
        let after: Int
        let timestamp: Date
    }

    /// Build a screen key that uniquely identifies a screen by its content,
    /// not just its VC class name. Uses the screen ID + a fingerprint
    /// derived from the first few interactive element labels.
    ///
    /// This is generic — works for any app architecture. The labels
    /// parameter is the first N element labels from the introspect pipeline.
    static func buildScreenKey(screenID: String, elementLabels: [String]) -> String {
        // If the screen ID is already specific enough, use it directly
        // (e.g., "home_view", "rankings_tab_view", "menu_view")
        let genericIDs = ["view", "hosting", "content", "any_view"]
        let isGeneric = genericIDs.contains(screenID) || screenID.count <= 3

        guard isGeneric else { return screenID }
        guard !elementLabels.isEmpty else { return screenID }

        // Hash the labels to a short stable key
        let fingerprint = elementLabels.prefix(5).joined(separator: "|")
        let hash = shortHash(fingerprint)
        return "\(screenID):\(hash)"
    }

    /// 8-char hash for fingerprinting
    private static func shortHash(_ input: String) -> String {
        let data = Data(input.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { buf in
            _ = CC_MD5(buf.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Run a heap scan and diff against the previous snapshot for this screen key.
    /// Returns any growing classes as leak warnings.
    func scanAndDiff(screenKey: String) -> [[String: AnyCodable]] {
        // Run heap scan outside lock — it's CPU-bound (~10-50ms)
        let current = runHeapScan()
        guard !current.isEmpty else { return [] }

        return queue.sync {
            var leaks: [[String: AnyCodable]] = []

            if let previous = screenSnapshots[screenKey] {
                for (cls, currentCount) in current {
                    let prevCount = previous[cls] ?? 0
                    let delta = currentCount - prevCount
                    if delta >= 2 {
                        leaks.append([
                            "class": AnyCodable(cls),
                            "before": AnyCodable(prevCount),
                            "after": AnyCodable(currentCount),
                            "delta": AnyCodable(delta)
                        ])

                        let warning = LeakWarning(
                            screenKey: screenKey,
                            className: cls,
                            before: prevCount,
                            after: currentCount,
                            timestamp: Date()
                        )
                        warnings.insert(warning, at: 0)
                        if warnings.count > maxWarnings {
                            warnings.removeLast()
                        }
                    }
                }

                leaks.sort { a, b in
                    (a["delta"]?.intValue ?? 0) > (b["delta"]?.intValue ?? 0)
                }
            }

            screenSnapshots[screenKey] = current

            return leaks
        }
    }

    /// Get recent leak warnings (for telemetry/status queries).
    func recentWarnings(limit: Int = 10) -> [[String: AnyCodable]] {
        return queue.sync {
            warnings.prefix(limit).map { w in
                [
                    "screen": AnyCodable(w.screenKey),
                    "class": AnyCodable(w.className),
                    "before": AnyCodable(w.before),
                    "after": AnyCodable(w.after),
                    "delta": AnyCodable(w.after - w.before),
                    "seconds_ago": AnyCodable(Int(-w.timestamp.timeIntervalSinceNow))
                ]
            }
        }
    }

    /// Clear all snapshots and warnings (e.g., on redeploy).
    func reset() {
        queue.sync {
            screenSnapshots.removeAll()
            warnings.removeAll()
        }
    }

    // MARK: - Heap scan via C bridge

    private func runHeapScan() -> [String: Int] {
        let prefixes = [Bundle.main.infoDictionary?["CFBundleName"] as? String ?? ""]
            + PepperAppConfig.shared.classLookupPrefixes

        var cPrefixes: [UnsafePointer<CChar>?] = []
        var cStrings: [UnsafeMutablePointer<CChar>] = []

        for prefix in prefixes where !prefix.isEmpty {
            // swiftlint:disable:next force_unwrapping
            let cStr = strdup(prefix)!
            cStrings.append(cStr)
            cPrefixes.append(UnsafePointer(cStr))
        }
        defer { cStrings.forEach { free($0) } }

        var entriesPtr: UnsafeMutablePointer<PepperHeapEntry>?
        var count: Int32 = 0

        let result = cPrefixes.withUnsafeBufferPointer { buf in
            pepper_heap_scan(&entriesPtr, &count, buf.baseAddress, Int32(buf.count))
        }

        guard result == 0, let entries = entriesPtr else { return [:] }
        defer { free(entries) }

        var counts: [String: Int] = [:]
        for i in 0..<Int(count) {
            let entry = entries[i]
            guard let namePtr = entry.class_name else { continue }
            var name = String(cString: namePtr)
            if let dotIdx = name.lastIndex(of: ".") {
                name = String(name[name.index(after: dotIdx)...])
            }
            counts[name, default: 0] += Int(entry.count)
        }

        return counts
    }
}
