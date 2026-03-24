import Foundation
import UIKit

/// Handles {"cmd": "renders"} commands for SwiftUI render tracking and view tree inspection.
///
/// Actions:
///   - "start":    Install spike swizzles (updateRootView, didRender, setNeedsUpdate) with console logging.
///   - "stop":     Remove spike swizzles and return method call statistics.
///   - "status":   Report active/inactive state and event count.
///   - "log":      Return structured render events from the ring buffer with summary.
///   - "clear":    Clear the ring buffer.
///   - "counts":   Return current spike method call counts without stopping.
///   - "snapshot": Capture the current SwiftUI view tree for all hosting views.
///   - "diff":     Compare current view tree against previous snapshot, showing changes.
///   - "reset":    Clear all render tracking data (counts + ring buffer + snapshots).
///   - "ag_probe": Probe AttributeGraph private APIs — reports which are available.
///   - "ag_server": Start the AG debug server (if available).
///   - "ag_dump":  Dump the attribute graph to JSON via AGGraphArchiveJSON.
///   - "signpost": Install/drain os_signpost introspection hook for SwiftUI events.
///   - "why":      Experimental — attempt to determine which state triggered a re-render.
///
/// Usage:
///   {"cmd":"renders","params":{"action":"start"}}
///   {"cmd":"renders","params":{"action":"stop"}}
///   {"cmd":"renders","params":{"action":"status"}}
///   {"cmd":"renders","params":{"action":"log"}}
///   {"cmd":"renders","params":{"action":"log","limit":50,"since_ms":1711152000000}}
///   {"cmd":"renders","params":{"action":"log","filter":"HomeViewController"}}
///   {"cmd":"renders","params":{"action":"clear"}}
///   {"cmd":"renders","params":{"action":"counts"}}
///   {"cmd":"renders","params":{"action":"snapshot"}}
///   {"cmd":"renders","params":{"action":"diff"}}
///   {"cmd":"renders","params":{"action":"reset"}}
///   {"cmd":"renders","params":{"action":"ag_probe"}}
///   {"cmd":"renders","params":{"action":"ag_server"}}
///   {"cmd":"renders","params":{"action":"ag_dump","name":"my_snapshot"}}
///   {"cmd":"renders","params":{"action":"signpost","sub":"install"}}  // or "drain"
///   {"cmd":"renders","params":{"action":"why"}}
struct RendersHandler: PepperHandler {
    let commandName = "renders"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "status"

        switch action {
        case "start":
            return handleStart(command)
        case "stop":
            return handleStop(command)
        case "status":
            return handleStatus(command)
        case "log":
            return handleLog(command)
        case "clear":
            return handleClear(command)
        case "counts":
            return handleCounts(command)
        case "snapshot":
            return handleSnapshot(command)
        case "diff":
            return handleDiff(command)
        case "reset":
            return handleReset(command)
        case "ag_probe":
            return handleAGProbe(command)
        case "ag_server":
            return handleAGServer(command)
        case "ag_dump":
            return handleAGDump(command)
        case "signpost":
            return handleSignpost(command)
        case "why":
            return handleWhy(command)
        default:
            return .error(
                id: command.id,
                message: "Unknown action '\(action)'. Use start, stop, status, log, clear, counts, snapshot, diff, reset, ag_probe, ag_server, ag_dump, signpost, or why."
            )
        }
    }

    // MARK: - Start / Stop / Status / Log / Clear

    private func handleStart(_ command: PepperCommand) -> PepperResponse {
        let report = PepperRenderTracker.shared.start()
        let status = report["status"] as? String ?? "unknown"

        if status == "error" {
            return .error(id: command.id, message: report["message"] as? String ?? "Failed to start spike")
        }

        var data: [String: AnyCodable] = [
            "status": AnyCodable(status),
            "swizzles_installed": AnyCodable(report["swizzles_installed"] as? Int ?? 0),
            "classes_found": AnyCodable(report["classes_found"] as? Int ?? 0),
            "note": AnyCodable("Spike active. Interact with SwiftUI screens and watch console output. Call stop to remove swizzles and see stats."),
        ]

        if let details = report["details"] as? [[String: String]] {
            data["details"] = AnyCodable(details.map { dict in
                AnyCodable(dict.mapValues { AnyCodable($0) })
            })
        }

        return .ok(id: command.id, data: data)
    }

    private func handleStop(_ command: PepperCommand) -> PepperResponse {
        let report = PepperRenderTracker.shared.stop()
        let status = report["status"] as? String ?? "unknown"

        var data: [String: AnyCodable] = [
            "status": AnyCodable(status),
        ]

        if let removed = report["swizzles_removed"] as? Int {
            data["swizzles_removed"] = AnyCodable(removed)
        }

        if let counts = report["method_counts"] as? [String: Int] {
            data["method_counts"] = AnyCodable(counts.mapValues { AnyCodable($0) })

            // Summarize which methods fired
            let fired = counts.filter { $0.value > 0 }.keys.sorted()
            let silent = counts.filter { $0.value == 0 }.keys.sorted()
            data["methods_that_fired"] = AnyCodable(fired.map { AnyCodable($0) })
            if !silent.isEmpty {
                data["methods_silent"] = AnyCodable(silent.map { AnyCodable($0) })
            }
        }

        return .ok(id: command.id, data: data)
    }

    private func handleStatus(_ command: PepperCommand) -> PepperResponse {
        let tracker = PepperRenderTracker.shared
        return .ok(id: command.id, data: [
            "active": AnyCodable(tracker.spikeActive),
            "event_count": AnyCodable(tracker.totalEventCount),
            "render_counts": AnyCodable(tracker.currentCounts.mapValues { AnyCodable($0) }),
        ])
    }

    private func handleLog(_ command: PepperCommand) -> PepperResponse {
        let tracker = PepperRenderTracker.shared
        let limit = command.params?["limit"]?.intValue ?? 100
        let sinceMs: Int64 =
            (command.params?["since_ms"]?.value as? Int).map { Int64($0) }
            ?? (command.params?["since_ms"]?.value as? Int64)
            ?? 0
        let filter = command.params?["filter"]?.stringValue

        var events = tracker.recentEvents(limit: limit, sinceMs: sinceMs)
        if let filter = filter, !filter.isEmpty {
            events = events.filter {
                $0.viewControllerType.contains(filter) || $0.hostingViewAddress.contains(filter)
            }
        }

        let eventDicts = events.map { AnyCodable($0.toDict()) }

        // Build summary
        var perViewCounts: [String: (count: Int, vc: String)] = [:]
        for event in events {
            let key = event.hostingViewAddress
            let prev = perViewCounts[key]
            let newCount = (prev?.count ?? 0) + 1
            perViewCounts[key] = (count: newCount, vc: event.viewControllerType)
        }

        let totalRenders = events.count
        let hostingViewCount = perViewCounts.count

        var hottestAddress = ""
        var hottestCount = 0
        var hottestVC = ""
        for (addr, info) in perViewCounts {
            if info.count > hottestCount {
                hottestCount = info.count
                hottestAddress = addr
                hottestVC = info.vc
            }
        }

        var summaryDict: [String: AnyCodable] = [
            "total_renders": AnyCodable(totalRenders),
            "hosting_views": AnyCodable(hostingViewCount),
        ]
        if !hottestAddress.isEmpty {
            summaryDict["hottest_view"] = AnyCodable([
                "address": AnyCodable(hottestAddress),
                "count": AnyCodable(hottestCount),
                "view_controller": AnyCodable(hottestVC),
            ] as [String: AnyCodable])
        }

        return .ok(id: command.id, data: [
            "events": AnyCodable(eventDicts),
            "summary": AnyCodable(summaryDict),
        ])
    }

    private func handleClear(_ command: PepperCommand) -> PepperResponse {
        PepperRenderTracker.shared.clearEvents()
        return .ok(id: command.id, data: ["cleared": AnyCodable(true)])
    }

    private func handleCounts(_ command: PepperCommand) -> PepperResponse {
        let tracker = PepperRenderTracker.shared
        let spikeCounts = tracker.spikeMethodCounts
        let renderCounts = tracker.currentCounts

        return .ok(id: command.id, data: [
            "spike_active": AnyCodable(tracker.spikeActive),
            "method_counts": AnyCodable(spikeCounts.mapValues { AnyCodable($0) }),
            "layout_render_counts": AnyCodable(renderCounts.mapValues { AnyCodable($0) }),
        ])
    }

    // MARK: - Snapshot

    private func handleSnapshot(_ command: PepperCommand) -> PepperResponse {
        let hostingViews = findHostingViews()

        if hostingViews.isEmpty {
            return .ok(
                id: command.id,
                data: [
                    "hosting_views": AnyCodable([AnyCodable]()),
                    "note": AnyCodable("No SwiftUI hosting views found in the view hierarchy."),
                ])
        }

        var results: [[String: AnyCodable]] = []
        let tracker = PepperRenderTracker.shared

        for hostingView in hostingViews {
            let address = String(format: "0x%lx", unsafeBitCast(hostingView, to: Int.self))
            let renderCount = tracker.renderCount(for: hostingView)

            // Find the owning view controller for context
            let vcName = owningViewControllerName(for: hostingView)

            var entry: [String: AnyCodable] = [
                "address": AnyCodable(address),
                "render_count": AnyCodable(renderCount),
            ]
            if let vcName = vcName {
                entry["view_controller"] = AnyCodable(vcName)
            }

            // Try to capture view tree via makeViewDebugData()
            if let tree = tracker.captureSnapshot(for: hostingView, force: true) {
                entry["view_tree"] = AnyCodable(tree.toDict())
            } else {
                entry["view_tree_available"] = AnyCodable(false)
            }

            results.append(entry)
        }

        return .ok(
            id: command.id,
            data: [
                "hosting_views": AnyCodable(results.map { AnyCodable($0) }),
            ])
    }

    // MARK: - Diff

    private func handleDiff(_ command: PepperCommand) -> PepperResponse {
        let hostingViews = findHostingViews()

        if hostingViews.isEmpty {
            return .ok(
                id: command.id,
                data: [
                    "changes": AnyCodable([AnyCodable]()),
                    "note": AnyCodable("No SwiftUI hosting views found."),
                ])
        }

        let tracker = PepperRenderTracker.shared
        var allChanges: [[String: AnyCodable]] = []
        var viewResults: [[String: AnyCodable]] = []

        for hostingView in hostingViews {
            let address = String(format: "0x%lx", unsafeBitCast(hostingView, to: Int.self))
            let vcName = owningViewControllerName(for: hostingView)

            var viewEntry: [String: AnyCodable] = [
                "address": AnyCodable(address),
            ]
            if let vcName = vcName {
                viewEntry["view_controller"] = AnyCodable(vcName)
            }

            if let result = tracker.diffSnapshot(for: hostingView) {
                viewEntry["change_count"] = AnyCodable(result.changes.count)

                for change in result.changes {
                    var changeDict = change.toDict()
                    changeDict["hosting_view"] = AnyCodable(address)
                    allChanges.append(changeDict)
                }

                if let current = result.current {
                    viewEntry["view_tree"] = AnyCodable(current.toDict())
                }
            } else {
                viewEntry["diff_available"] = AnyCodable(false)
                viewEntry["note"] = AnyCodable(
                    "makeViewDebugData() unavailable. Render counts still tracked.")
            }

            viewResults.append(viewEntry)
        }

        return .ok(
            id: command.id,
            data: [
                "changes": AnyCodable(allChanges.map { AnyCodable($0) }),
                "hosting_views": AnyCodable(viewResults.map { AnyCodable($0) }),
            ])
    }

    // MARK: - Reset

    private func handleReset(_ command: PepperCommand) -> PepperResponse {
        PepperRenderTracker.shared.reset()
        return .ok(id: command.id, data: ["reset": AnyCodable(true)])
    }

    // MARK: - AttributeGraph Exploration

    private func handleAGProbe(_ command: PepperCommand) -> PepperResponse {
        let report = PepperAGExplorer.probeAPIs() as [String: Any]
        return .ok(id: command.id, data: ["ag_probe": AnyCodable(report)])
    }

    private func handleAGServer(_ command: PepperCommand) -> PepperResponse {
        if let url = PepperAGExplorer.startDebugServer() {
            return .ok(id: command.id, data: [
                "debug_server": AnyCodable(["status": AnyCodable("started"), "url": AnyCodable(url)]),
            ])
        }
        return .ok(id: command.id, data: [
            "debug_server": AnyCodable(["status": AnyCodable("unavailable"),
                "note": AnyCodable("AGDebugServerStart not found. Symbol may not be exported on this iOS version.")]),
        ])
    }

    private func handleAGDump(_ command: PepperCommand) -> PepperResponse {
        let name = command.params?["name"]?.stringValue ?? "pepper_ag_dump"
        let hostingViews = findHostingViews()
        guard let hostingView = hostingViews.first else {
            return .error(id: command.id, message: "No SwiftUI hosting views found.")
        }

        if let path = PepperAGExplorer.dumpGraphJSON(hostingView, name: name) {
            // Try to read the dumped JSON for inline response
            var result: [String: AnyCodable] = [
                "path": AnyCodable(path),
                "status": AnyCodable("dumped"),
            ]
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let json = try? JSONSerialization.jsonObject(with: data)
            {
                result["graph"] = AnyCodable(json)
            }
            return .ok(id: command.id, data: ["ag_dump": AnyCodable(result)])
        }
        return .ok(id: command.id, data: [
            "ag_dump": AnyCodable(["status": AnyCodable("unavailable"),
                "note": AnyCodable(
                    "AGGraphArchiveJSON not available or AGGraphRef extraction failed. " +
                    "Run ag_probe to check symbol availability.")]),
        ])
    }

    private func handleSignpost(_ command: PepperCommand) -> PepperResponse {
        let sub = command.params?["sub"]?.stringValue ?? "install"

        switch sub {
        case "install":
            let success = PepperAGExplorer.installSignpostHook()
            return .ok(id: command.id, data: [
                "signpost_hook": AnyCodable([
                    "installed": AnyCodable(success),
                    "note": AnyCodable(success
                        ? "Hook installed. SwiftUI signpost events will be captured. Use sub:drain to retrieve."
                        : "Signpost hook symbol not found on this OS version."),
                ]),
            ])
        case "drain":
            let events = PepperAGExplorer.drainSignpostEvents() as? [[String: Any]] ?? []
            return .ok(id: command.id, data: [
                "signpost_events": AnyCodable(events),
                "count": AnyCodable(events.count),
            ])
        default:
            return .error(id: command.id, message: "Unknown signpost sub-action '\(sub)'. Use install or drain.")
        }
    }

    /// Experimental: Attempt to determine *why* a view re-rendered by combining
    /// AG graph probing with view tree diffing and state inspection.
    private func handleWhy(_ command: PepperCommand) -> PepperResponse {
        let hostingViews = findHostingViews()
        guard !hostingViews.isEmpty else {
            return .error(id: command.id, message: "No SwiftUI hosting views found.")
        }

        var results: [[String: AnyCodable]] = []
        let tracker = PepperRenderTracker.shared

        for hostingView in hostingViews {
            let address = String(format: "0x%lx", unsafeBitCast(hostingView, to: Int.self))
            var entry: [String: AnyCodable] = ["address": AnyCodable(address)]

            // 1. View tree diff — what changed visually
            if let diffResult = tracker.diffSnapshot(for: hostingView) {
                entry["visual_changes"] = AnyCodable(diffResult.changes.map { AnyCodable($0.toDict()) })
                entry["change_count"] = AnyCodable(diffResult.changes.count)
            }

            // 2. AG graph ref extraction — can we reach the graph?
            let graphRef = PepperAGExplorer.extractGraphRef(hostingView)
            entry["ag_graph_ref_found"] = AnyCodable(graphRef != nil)

            // 3. Signpost events — any recent SwiftUI signpost activity?
            let signpostEvents = PepperAGExplorer.drainSignpostEvents() as? [[String: Any]] ?? []
            if !signpostEvents.isEmpty {
                entry["signpost_events"] = AnyCodable(signpostEvents)
            }

            // 4. Summary — best-effort explanation
            var hints: [String] = []

            if let diffResult = tracker.diffSnapshot(for: hostingView) {
                let modifiedViews = diffResult.changes
                    .filter { $0.type == .modified }
                    .map { $0.viewType }
                let addedViews = diffResult.changes
                    .filter { $0.type == .added }
                    .map { $0.viewType }

                if !modifiedViews.isEmpty {
                    hints.append("Modified views: \(Set(modifiedViews).joined(separator: ", "))")
                }
                if !addedViews.isEmpty {
                    hints.append("Added views: \(Set(addedViews).joined(separator: ", "))")
                }
            }

            if graphRef != nil {
                hints.append("AGGraphRef extracted — deeper analysis may be possible with ag_dump.")
            } else {
                hints.append(
                    "AGGraphRef not accessible. State-level causality requires AttributeGraph access.")
            }

            entry["hints"] = AnyCodable(hints)
            entry["note"] = AnyCodable(
                "Phase 4 research: 'why' tracking depends on AttributeGraph API availability. " +
                "Run ag_probe first to check. Visual diff shows WHAT changed; AG analysis can show WHY."
            )

            results.append(entry)
        }

        return .ok(id: command.id, data: [
            "why": AnyCodable(results.map { AnyCodable($0) }),
        ])
    }

    // MARK: - Helpers

    /// Find all `_UIHostingView` instances in the visible window hierarchy.
    private func findHostingViews() -> [UIView] {
        var results: [UIView] = []
        for window in UIWindow.pepper_allVisibleWindows {
            collectHostingViews(in: window, into: &results)
        }
        return results
    }

    /// Recursively search for hosting views. A hosting view is identified by its class name
    /// containing "_UIHostingView" (the internal SwiftUI view that backs UIHostingController).
    private func collectHostingViews(in view: UIView, into results: inout [UIView]) {
        let typeName = String(describing: type(of: view))
        if typeName.contains("_UIHostingView") || typeName.contains("UIHostingView") {
            results.append(view)
            return  // Don't recurse into hosting view internals
        }
        for subview in view.subviews {
            collectHostingViews(in: subview, into: &results)
        }
    }

    /// Walk the responder chain to find the owning view controller's type name.
    private func owningViewControllerName(for view: UIView) -> String? {
        if let vc = PepperSwiftUIBridge.shared.findOwningViewController(for: view) {
            return String(describing: type(of: vc))
        }
        return nil
    }
}
