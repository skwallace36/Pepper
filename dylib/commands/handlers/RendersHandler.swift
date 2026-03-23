import Foundation
import UIKit

/// Handles {"cmd": "renders"} commands for SwiftUI render tracking and view tree inspection.
///
/// Actions:
///   - "snapshot": Capture the current SwiftUI view tree for all hosting views.
///   - "diff":     Compare current view tree against previous snapshot, showing changes.
///   - "reset":    Clear all render tracking data.
///   - "ag_probe": Probe AttributeGraph private APIs — reports which are available.
///   - "ag_server": Start the AG debug server (if available).
///   - "ag_dump":  Dump the attribute graph to JSON via AGGraphArchiveJSON.
///   - "signpost": Install/drain os_signpost introspection hook for SwiftUI events.
///   - "why":      Experimental — attempt to determine which state triggered a re-render.
///
/// Usage:
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
        let action = command.params?["action"]?.stringValue ?? "snapshot"

        switch action {
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
                message: "Unknown action '\(action)'. Use snapshot, diff, reset, ag_probe, ag_server, ag_dump, signpost, or why."
            )
        }
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
