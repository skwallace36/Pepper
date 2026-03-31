import CryptoKit
import Foundation

/// Tracks heap instance counts per screen and detects growth (potential leaks).
///
/// On every introspect map call, the monitor:
/// 1. Builds a screen key from the screen ID + element fingerprint
/// 2. Runs a heap scan (via C bridge, ~10-50ms)
/// 3. If returning to a previously-seen screen, diffs and reports growing classes
/// 4. Saves the current snapshot
///
/// Significance filtering: minor per-frame jitter (e.g., CString +5) is suppressed.
/// A class is reported only when:
/// - Single-observation spike: delta >= 20
/// - Sustained growth: positive delta on 3+ consecutive observations for the same screen
///
/// All data is still collected — only the reporting is filtered.
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

    /// Per-screen observation count: screen_key → number of snapshots taken
    private var screenObservations: [String: Int] = [:]

    /// Consecutive growth counter: (screen_key, class_name) → count of consecutive positive deltas
    private var growthStreaks: [String: Int] = [:]

    /// Minimum delta for a single-observation spike to be reported
    private let spikeThreshold = 20

    /// Number of consecutive positive-delta observations before sustained growth is reported
    private let sustainedGrowthCount = 3

    /// Accumulated leak warnings (ring buffer, newest first)
    private var warnings: [LeakWarning] = []
    private let maxWarnings = 50

    /// Async scan: heap scans run on a background queue and results
    /// are attached to the next look response. Never blocks main thread.
    private var pendingScan = false
    private var latestScanResult: [String: Int] = [:]
    private let scanQueue = DispatchQueue(label: "com.pepper.control.heap-scan", qos: .utility)

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
        // (e.g., "home_view", "settings_view", "menu_view")
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
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Kick off an async heap scan if one isn't already running.
    /// Results appear in the next scanAndDiff call.
    private func triggerAsyncScan() {
        guard !pendingScan else { return }
        pendingScan = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let result = self.runHeapScan()
            self.queue.sync {
                self.latestScanResult = result
                self.pendingScan = false
            }
        }
    }

    /// Diff against the previous snapshot for this screen key using the
    /// most recent async scan result. Never blocks main thread.
    /// Kicks off a new async scan for future calls.
    func scanAndDiff(screenKey: String) -> [[String: AnyCodable]] {
        triggerAsyncScan()
        let current = latestScanResult
        guard !current.isEmpty else { return [] }

        return queue.sync {
            var leaks: [[String: AnyCodable]] = []

            screenObservations[screenKey, default: 0] += 1
            let observations = screenObservations[screenKey] ?? 1
            let inWarmup = observations <= HeapExclusions.warmupObservations

            if let previous = screenSnapshots[screenKey] {
                for (cls, currentCount) in current {
                    if HeapExclusions.isBenign(cls) { continue }
                    let prevCount = previous[cls] ?? 0
                    let delta = currentCount - prevCount
                    let streakKey = "\(screenKey)|\(cls)"

                    // Track consecutive growth streaks
                    if delta > 0 {
                        growthStreaks[streakKey, default: 0] += 1
                    } else {
                        growthStreaks[streakKey] = 0
                    }

                    // During warmup, only track — don't report
                    if inWarmup { continue }

                    // Report if: large single spike OR sustained growth over multiple observations
                    let isSpike = delta >= spikeThreshold
                    let isSustained = (growthStreaks[streakKey] ?? 0) >= sustainedGrowthCount && delta > 0
                    guard isSpike || isSustained else { continue }

                    var entry: [String: AnyCodable] = [
                        "class": AnyCodable(cls),
                        "before": AnyCodable(prevCount),
                        "after": AnyCodable(currentCount),
                        "delta": AnyCodable(delta),
                    ]
                    if isSustained && !isSpike {
                        entry["sustained"] = AnyCodable(true)
                        entry["streak"] = AnyCodable(growthStreaks[streakKey] ?? 0)
                    }
                    leaks.append(entry)

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
                    "seconds_ago": AnyCodable(Int(-w.timestamp.timeIntervalSinceNow)),
                ]
            }
        }
    }

    /// Clear all snapshots and warnings (e.g., on redeploy).
    func reset() {
        queue.sync {
            screenSnapshots.removeAll()
            screenObservations.removeAll()
            growthStreaks.removeAll()
            warnings.removeAll()
            latestScanResult.removeAll()
        }
    }

    // MARK: - Heap scan via C bridge

    private func runHeapScan() -> [String: Int] {
        let prefixes =
            [Bundle.main.infoDictionary?["CFBundleName"] as? String ?? ""]
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
