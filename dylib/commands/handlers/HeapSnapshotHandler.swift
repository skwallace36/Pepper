import Foundation
import ObjectiveC
import UIKit

/// Result entry from the C heap scanner.
struct PepperHeapEntry {
    var class_name: UnsafePointer<CChar>?
    var count: Int32
}

/// C function declaration — implemented in PepperHeapScan.c
@_silgen_name("pepper_heap_scan")
func pepper_heap_scan(
    _ out_entries: UnsafeMutablePointer<UnsafeMutablePointer<PepperHeapEntry>?>,
    _ out_count: UnsafeMutablePointer<Int32>,
    _ filter_prefixes: UnsafePointer<UnsafePointer<CChar>?>?,
    _ prefix_count: Int32
) -> Int32

/// Handles {"cmd": "heap_snapshot"} commands for memory leak detection.
///
/// Uses malloc zone enumeration (same technique as FLEX) to count ALL live
/// ObjC instances by class — not just ViewControllers. Catches leaked
/// ViewModels, services, managers, closures — anything that's an NSObject subclass.
///
/// Actions:
///   - "snapshot":  Save current instance counts as baseline.
///   - "diff":      Compare current counts to baseline. Shows growing classes.
///   - "baseline":  Alias for snapshot — capture reference counts as a named baseline.
///   - "check":     Compare current counts to baseline, classify growth by severity.
///   - "clear":     Clear saved snapshot.
///   - "status":    Show when the last snapshot was taken.
struct HeapSnapshotHandler: PepperHandler {
    let commandName = "heap_snapshot"

    private static var savedSnapshot: [String: Int]?
    private static var snapshotTime: Date?

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "snapshot"

        switch action {
        case "snapshot", "baseline":
            return handleSnapshot(command)
        case "diff":
            return handleDiff(command)
        case "check":
            return handleCheck(command)
        case "clear":
            Self.savedSnapshot = nil
            Self.snapshotTime = nil
            return .ok(id: command.id, data: ["cleared": AnyCodable(true)])
        case "status":
            if let time = Self.snapshotTime, let snap = Self.savedSnapshot {
                return .ok(
                    id: command.id,
                    data: [
                        "has_snapshot": AnyCodable(true),
                        "class_count": AnyCodable(snap.count),
                        "taken_at": AnyCodable(ISO8601DateFormatter().string(from: time)),
                        "seconds_ago": AnyCodable(Int(-time.timeIntervalSinceNow)),
                    ])
            }
            return .ok(id: command.id, data: ["has_snapshot": AnyCodable(false)])
        default:
            return .error(
                id: command.id,
                message: "Unknown heap_snapshot action '\(action)'. Use snapshot/baseline/diff/check/clear/status.")
        }
    }

    // MARK: - Snapshot

    private func handleSnapshot(_ command: PepperCommand) -> PepperResponse {
        let counts = scanHeap()
        Self.savedSnapshot = counts
        Self.snapshotTime = Date()

        let sorted = counts.sorted { $0.value > $1.value }.prefix(30)
        let topClasses = sorted.map { ["class": AnyCodable($0.key), "count": AnyCodable($0.value)] }

        return .ok(
            id: command.id,
            data: [
                "total_classes": AnyCodable(counts.count),
                "total_instances": AnyCodable(counts.values.reduce(0, +)),
                "top_30": AnyCodable(topClasses),
                "memory": AnyCodable(getMemoryInfo()),
            ])
    }

    // MARK: - Diff

    private func handleDiff(_ command: PepperCommand) -> PepperResponse {
        guard let baseline = Self.savedSnapshot, let baselineTime = Self.snapshotTime else {
            return .error(id: command.id, message: "No baseline snapshot. Run action:snapshot first.")
        }

        let current = scanHeap()
        let minGrowth = command.params?["min_growth"]?.intValue ?? 1

        var growing: [[String: AnyCodable]] = []
        var shrinking: [[String: AnyCodable]] = []

        for (cls, currentCount) in current {
            if HeapExclusions.isBenign(cls) { continue }
            let baseCount = baseline[cls] ?? 0
            let delta = currentCount - baseCount
            if delta >= minGrowth {
                growing.append([
                    "class": AnyCodable(cls),
                    "before": AnyCodable(baseCount),
                    "after": AnyCodable(currentCount),
                    "delta": AnyCodable("+\(delta)"),
                ])
            } else if delta < -minGrowth {
                shrinking.append([
                    "class": AnyCodable(cls),
                    "before": AnyCodable(baseCount),
                    "after": AnyCodable(currentCount),
                    "delta": AnyCodable("\(delta)"),
                ])
            }
        }

        // Classes that disappeared entirely
        for (cls, baseCount) in baseline where current[cls] == nil && !HeapExclusions.isBenign(cls) {
            shrinking.append([
                "class": AnyCodable(cls),
                "before": AnyCodable(baseCount),
                "after": AnyCodable(0),
                "delta": AnyCodable("-\(baseCount)"),
            ])
        }

        growing.sort { a, b in
            let deltaA = (a["after"]?.intValue ?? 0) - (a["before"]?.intValue ?? 0)
            let deltaB = (b["after"]?.intValue ?? 0) - (b["before"]?.intValue ?? 0)
            return deltaA > deltaB
        }

        let elapsed = Int(-baselineTime.timeIntervalSinceNow)

        return .ok(
            id: command.id,
            data: [
                "elapsed_seconds": AnyCodable(elapsed),
                "growing": AnyCodable(growing),
                "growing_count": AnyCodable(growing.count),
                "shrinking_count": AnyCodable(shrinking.count),
                "unchanged_count": AnyCodable(max(0, current.count - growing.count)),
                "memory": AnyCodable(getMemoryInfo()),
                "verdict": AnyCodable(
                    growing.isEmpty ? "No leaks detected" : "\(growing.count) class(es) growing — potential leaks"),
            ])
    }

    // MARK: - Check (automatic leak detection with severity classification)

    private func handleCheck(_ command: PepperCommand) -> PepperResponse {
        guard let baseline = Self.savedSnapshot, let baselineTime = Self.snapshotTime else {
            return .error(id: command.id, message: "No baseline snapshot. Run action:baseline first.")
        }

        let current = scanHeap()
        let threshold = command.params?["threshold"]?.intValue ?? 1
        let elapsed = Int(-baselineTime.timeIntervalSinceNow)
        let inWarmup = elapsed < HeapExclusions.warmupSeconds

        var leaks: [[String: AnyCodable]] = []

        for (cls, currentCount) in current {
            if HeapExclusions.isBenign(cls) { continue }
            let baseCount = baseline[cls] ?? 0
            let delta = currentCount - baseCount
            guard delta >= threshold else { continue }

            let severity = inWarmup ? "low" : classifySeverity(baseline: baseCount, current: currentCount, delta: delta)
            leaks.append([
                "class": AnyCodable(cls),
                "baseline": AnyCodable(baseCount),
                "current": AnyCodable(currentCount),
                "delta": AnyCodable(delta),
                "severity": AnyCodable(severity),
            ])
        }

        // Sort: high severity first, then by delta descending
        leaks.sort { a, b in
            let severityOrder = ["high": 0, "medium": 1, "low": 2]
            let sa = severityOrder[a["severity"]?.stringValue ?? "low"] ?? 2
            let sb = severityOrder[b["severity"]?.stringValue ?? "low"] ?? 2
            if sa != sb { return sa < sb }
            return (a["delta"]?.intValue ?? 0) > (b["delta"]?.intValue ?? 0)
        }

        let highCount = leaks.filter { $0["severity"]?.stringValue == "high" }.count
        let mediumCount = leaks.filter { $0["severity"]?.stringValue == "medium" }.count

        let verdict: String
        if inWarmup {
            verdict = "Warmup period (\(HeapExclusions.warmupSeconds)s) — growth not yet classified"
        } else if leaks.isEmpty {
            verdict = "No leaks detected"
        } else if highCount > 0 {
            verdict = "\(highCount) high-severity leak(s) detected — likely retain cycles"
        } else {
            verdict = "\(mediumCount) medium-severity growth(s) detected — review recommended"
        }

        var data: [String: AnyCodable] = [
            "leaks": AnyCodable(leaks),
            "leak_count": AnyCodable(leaks.count),
            "high_count": AnyCodable(highCount),
            "medium_count": AnyCodable(mediumCount),
            "elapsed_seconds": AnyCodable(elapsed),
            "verdict": AnyCodable(verdict),
            "memory": AnyCodable(getMemoryInfo()),
        ]
        if inWarmup {
            data["warmup"] = AnyCodable(true)
        }

        return .ok(id: command.id, data: data)
    }

    /// Classify growth severity based on delta and growth ratio.
    /// - high:   delta >= 5 or 5x+ growth from a non-zero baseline
    /// - medium: delta >= 2 or 2x+ growth from a non-zero baseline
    /// - low:    any other positive delta
    private func classifySeverity(baseline: Int, current: Int, delta: Int) -> String {
        let ratio = baseline > 0 ? Double(current) / Double(baseline) : Double.infinity
        if delta >= 5 || ratio >= 5.0 {
            return "high"
        } else if delta >= 2 || ratio >= 2.0 {
            return "medium"
        }
        return "low"
    }

    // MARK: - Heap Scan (via C bridge)

    private func scanHeap() -> [String: Int] {
        // Build prefix filter from app config
        let prefixes =
            [Bundle.main.infoDictionary?["CFBundleName"] as? String ?? ""]
            + PepperAppConfig.shared.classLookupPrefixes

        // Convert to C string array
        var cPrefixes: [UnsafePointer<CChar>?] = []
        var cStrings: [UnsafeMutablePointer<CChar>] = []  // Keep alive

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

            // Strip module prefix for cleaner output
            if let dotIdx = name.lastIndex(of: ".") {
                name = String(name[name.index(after: dotIdx)...])
            }

            counts[name, default: 0] += Int(entry.count)
        }

        return counts
    }

    // MARK: - Memory Info

    private func getMemoryInfo() -> [String: AnyCodable] {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return [:] }

        return [
            "resident_mb": AnyCodable(Double(info.resident_size) / 1_048_576.0),
            "virtual_mb": AnyCodable(Double(info.virtual_size) / 1_048_576.0),
        ]
    }
}
