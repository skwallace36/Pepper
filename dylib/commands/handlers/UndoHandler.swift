import Foundation
import UIKit

/// Handles {"cmd": "undo"} commands for UndoManager inspection and control.
///
/// Inspects undo/redo stack state — depth, action names, grouping level — and
/// triggers undo/redo programmatically. Useful for testing edit flows in
/// document-based and text-heavy apps.
///
/// Actions:
///   - "list":   Find all UndoManager instances via responder chain + heap scan
///   - "status": Query canUndo/canRedo, action names, grouping for a specific manager
///   - "undo":   Trigger undo on a specific manager (or first available)
///   - "redo":   Trigger redo on a specific manager (or first available)
struct UndoHandler: PepperHandler {
    let commandName = "undo"
    let timeout: TimeInterval = 15.0

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "list"

        switch action {
        case "list":
            return handleList(command)
        case "status":
            return handleStatus(command)
        case "undo":
            return handleUndo(command)
        case "redo":
            return handleRedo(command)
        default:
            return .error(id: command.id, message: "Unknown undo action '\(action)'. Use list/status/undo/redo.")
        }
    }

    // MARK: - List

    /// Discover all UndoManager instances via responder chain walking + heap scan.
    private func handleList(_ command: PepperCommand) -> PepperResponse {
        var managers: [(UndoManager, String)] = [] // (manager, owner description)
        var seen = Set<ObjectIdentifier>()

        // Strategy 1: Walk responder chains from all visible view controllers
        if let window = UIWindow.pepper_keyWindow, let rootVC = window.rootViewController {
            collectFromControllerHierarchy(rootVC, managers: &managers, seen: &seen)
        }

        // Also check the first responder's undo manager
        if let window = UIWindow.pepper_keyWindow {
            collectFromFirstResponder(in: window, managers: &managers, seen: &seen)
        }

        // Strategy 2: Heap scan for UndoManager instances not found via responder chain
        collectFromHeap(managers: &managers, seen: &seen)

        let entries: [[String: AnyCodable]] = managers.map { manager, owner in
            managerEntry(manager, owner: owner)
        }

        return .ok(id: command.id, data: [
            "count": AnyCodable(entries.count),
            "managers": AnyCodable(entries),
        ])
    }

    // MARK: - Status

    private func handleStatus(_ command: PepperCommand) -> PepperResponse {
        let index = command.params?["index"]?.intValue ?? 0

        guard let (manager, owner) = findManager(index: index) else {
            return .error(id: command.id, message: "No UndoManager found at index \(index). Use 'list' to see available managers.")
        }

        return .ok(id: command.id, data: managerEntry(manager, owner: owner))
    }

    // MARK: - Undo

    private func handleUndo(_ command: PepperCommand) -> PepperResponse {
        let index = command.params?["index"]?.intValue ?? 0

        guard let (manager, owner) = findManager(index: index) else {
            return .error(id: command.id, message: "No UndoManager found at index \(index).")
        }

        guard manager.canUndo else {
            return .error(id: command.id, message: "Cannot undo — undo stack is empty (owner: \(owner)).")
        }

        let actionName = manager.undoActionName
        manager.undo()

        return .ok(id: command.id, data: [
            "performed": AnyCodable("undo"),
            "action_name": AnyCodable(actionName),
            "owner": AnyCodable(owner),
            "can_undo": AnyCodable(manager.canUndo),
            "can_redo": AnyCodable(manager.canRedo),
        ])
    }

    // MARK: - Redo

    private func handleRedo(_ command: PepperCommand) -> PepperResponse {
        let index = command.params?["index"]?.intValue ?? 0

        guard let (manager, owner) = findManager(index: index) else {
            return .error(id: command.id, message: "No UndoManager found at index \(index).")
        }

        guard manager.canRedo else {
            return .error(id: command.id, message: "Cannot redo — redo stack is empty (owner: \(owner)).")
        }

        let actionName = manager.redoActionName
        manager.redo()

        return .ok(id: command.id, data: [
            "performed": AnyCodable("redo"),
            "action_name": AnyCodable(actionName),
            "owner": AnyCodable(owner),
            "can_undo": AnyCodable(manager.canUndo),
            "can_redo": AnyCodable(manager.canRedo),
        ])
    }

    // MARK: - Discovery Helpers

    /// Find a manager by index (across responder chain + heap).
    private func findManager(index: Int) -> (UndoManager, String)? {
        var managers: [(UndoManager, String)] = []
        var seen = Set<ObjectIdentifier>()

        if let window = UIWindow.pepper_keyWindow, let rootVC = window.rootViewController {
            collectFromControllerHierarchy(rootVC, managers: &managers, seen: &seen)
        }
        if let window = UIWindow.pepper_keyWindow {
            collectFromFirstResponder(in: window, managers: &managers, seen: &seen)
        }
        collectFromHeap(managers: &managers, seen: &seen)

        guard index >= 0, index < managers.count else { return nil }
        return managers[index]
    }

    /// Walk the VC hierarchy and collect undo managers from each VC's responder chain.
    private func collectFromControllerHierarchy(
        _ vc: UIViewController,
        managers: inout [(UndoManager, String)],
        seen: inout Set<ObjectIdentifier>
    ) {
        if let um = vc.undoManager {
            let id = ObjectIdentifier(um)
            if !seen.contains(id) {
                seen.insert(id)
                let owner = String(describing: type(of: vc))
                managers.append((um, owner))
            }
        }

        for child in vc.children {
            collectFromControllerHierarchy(child, managers: &managers, seen: &seen)
        }
        if let presented = vc.presentedViewController, presented.presentingViewController == vc {
            collectFromControllerHierarchy(presented, managers: &managers, seen: &seen)
        }
    }

    /// Check if the current first responder has an undo manager.
    private func collectFromFirstResponder(
        in window: UIWindow,
        managers: inout [(UndoManager, String)],
        seen: inout Set<ObjectIdentifier>
    ) {
        guard let firstResponder = findFirstResponder(in: window) else { return }
        guard let um = firstResponder.undoManager else { return }
        let id = ObjectIdentifier(um)
        guard !seen.contains(id) else { return }
        seen.insert(id)
        let owner = "firstResponder(\(String(describing: type(of: firstResponder))))"
        managers.append((um, owner))
    }

    /// Recursively find the first responder in a view hierarchy.
    private func findFirstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = findFirstResponder(in: subview) {
                return found
            }
        }
        return nil
    }

    /// Heap scan for UndoManager instances not already found.
    private func collectFromHeap(
        managers: inout [(UndoManager, String)],
        seen: inout Set<ObjectIdentifier>
    ) {
        guard let undoClass: AnyClass = NSClassFromString("NSUndoManager") else { return }

        let classPtr = unsafeBitCast(undoClass, to: UnsafeRawPointer.self)
        var targetClasses: [UnsafeRawPointer?] = [classPtr]
        var outInstances: UnsafeMutablePointer<UnsafeRawPointer?>?
        var outClasses: UnsafeMutablePointer<UnsafeRawPointer?>?
        var outCount: Int32 = 0

        let result = pepper_heap_find_instances(
            &targetClasses,
            Int32(targetClasses.count),
            &outInstances,
            &outClasses,
            &outCount
        )

        guard result == 0, let instances = outInstances, outCount > 0 else { return }
        defer {
            outInstances?.deallocate()
            outClasses?.deallocate()
        }

        for i in 0..<Int(outCount) {
            guard let ptr = instances[i] else { continue }
            let obj = Unmanaged<UndoManager>.fromOpaque(ptr).takeUnretainedValue()
            let id = ObjectIdentifier(obj)
            guard !seen.contains(id) else { continue }
            seen.insert(id)

            // Try to identify the owner by walking responder chain backwards
            let owner = identifyOwner(of: obj) ?? "heap"
            managers.append((obj, owner))
        }
    }

    /// Try to find which responder owns a given undo manager by checking
    /// all view controllers and windows.
    private func identifyOwner(of manager: UndoManager) -> String? {
        guard let window = UIWindow.pepper_keyWindow, let rootVC = window.rootViewController else {
            return nil
        }

        func searchVC(_ vc: UIViewController) -> String? {
            if vc.undoManager === manager {
                return String(describing: type(of: vc))
            }
            for child in vc.children {
                if let found = searchVC(child) { return found }
            }
            if let presented = vc.presentedViewController, presented.presentingViewController == vc {
                if let found = searchVC(presented) { return found }
            }
            return nil
        }

        return searchVC(rootVC)
    }

    // MARK: - Formatting

    /// Build a dictionary describing an UndoManager's state.
    private func managerEntry(_ manager: UndoManager, owner: String) -> [String: AnyCodable] {
        var entry: [String: AnyCodable] = [
            "owner": AnyCodable(owner),
            "address": AnyCodable(String(format: "%p", unsafeBitCast(manager, to: Int.self))),
            "can_undo": AnyCodable(manager.canUndo),
            "can_redo": AnyCodable(manager.canRedo),
            "grouping_level": AnyCodable(manager.groupingLevel),
            "is_undo_registration_enabled": AnyCodable(manager.isUndoRegistrationEnabled),
            "levels_of_undo": AnyCodable(manager.levelsOfUndo),
        ]

        if manager.canUndo {
            entry["undo_action_name"] = AnyCodable(manager.undoActionName)
        }
        if manager.canRedo {
            entry["redo_action_name"] = AnyCodable(manager.redoActionName)
        }

        // Collect undo/redo menu item titles for stack depth hints
        let undoTitle = manager.undoMenuItemTitle
        let redoTitle = manager.redoMenuItemTitle
        if !undoTitle.isEmpty {
            entry["undo_menu_title"] = AnyCodable(undoTitle)
        }
        if !redoTitle.isEmpty {
            entry["redo_menu_title"] = AnyCodable(redoTitle)
        }

        if manager.groupsByEvent {
            entry["groups_by_event"] = AnyCodable(true)
        }
        if manager.isUndoing {
            entry["is_undoing"] = AnyCodable(true)
        }
        if manager.isRedoing {
            entry["is_redoing"] = AnyCodable(true)
        }

        return entry
    }
}
