import Foundation
import UIKit

/// Handles {"cmd": "renders"} commands for SwiftUI render tracking and view tree inspection.
///
/// Actions:
///   - "snapshot": Capture the current SwiftUI view tree for all hosting views.
///   - "diff":     Compare current view tree against previous snapshot, showing changes.
///   - "reset":    Clear all render tracking data.
///
/// Usage:
///   {"cmd":"renders","params":{"action":"snapshot"}}
///   {"cmd":"renders","params":{"action":"diff"}}
///   {"cmd":"renders","params":{"action":"reset"}}
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
        default:
            return .error(id: command.id, message: "Unknown action '\(action)'. Use snapshot, diff, or reset.")
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
