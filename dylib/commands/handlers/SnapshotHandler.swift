import Foundation
import os

/// Handles {"cmd": "snapshot"} commands for screen state diffing.
///
/// Captures structured `look` (introspect map) output as a named baseline,
/// then diffs the current screen state against it.
///
/// Actions:
///   - "save":   Capture current screen state and save as a named snapshot.
///   - "diff":   Compare current screen state against a saved snapshot.
///   - "list":   List all saved snapshot names.
///   - "delete": Delete a saved snapshot by name.
///   - "clear":  Delete all saved snapshots.
struct SnapshotHandler: PepperHandler {
    let commandName = "snapshot"
    let timeout: TimeInterval = 30.0

    private var logger: Logger { PepperLogger.logger(category: "snapshot") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "save"
        let name = command.params?["name"]?.stringValue ?? "default"

        switch action {
        case "save":
            return handleSave(command, name: name)
        case "diff":
            return handleDiff(command, name: name)
        case "list":
            return handleList(command)
        case "delete":
            return handleDelete(command, name: name)
        case "clear":
            return handleClear(command)
        default:
            return .error(id: command.id, message: "Unknown snapshot action: \(action). Use: save, diff, list, delete, clear")
        }
    }

    // MARK: - Save

    private func handleSave(_ command: PepperCommand, name: String) -> PepperResponse {
        let state = captureScreenState()
        SnapshotStore.shared.save(state, name: name)
        logger.info("Saved snapshot '\(name)' with \(state.elements.count) elements on screen '\(state.screen)'")
        return .ok(id: command.id, data: [
            "action": AnyCodable("save"),
            "name": AnyCodable(name),
            "screen": AnyCodable(state.screen),
            "element_count": AnyCodable(state.elements.count),
            "text_count": AnyCodable(state.texts.count)
        ])
    }

    // MARK: - Diff

    private func handleDiff(_ command: PepperCommand, name: String) -> PepperResponse {
        guard let baseline = SnapshotStore.shared.load(name) else {
            return .error(id: command.id, message: "No snapshot named '\(name)'. Save one first with action=save.")
        }

        let current = captureScreenState()
        let ignoreTransient = command.params?["ignore_transient"]?.boolValue ?? false
        let assertNoDiff = command.params?["assert_no_diff"]?.boolValue ?? false

        let diff = computeDiff(baseline: baseline, current: current, ignoreTransient: ignoreTransient)

        let hasChanges = !diff.added.isEmpty || !diff.removed.isEmpty || !diff.changed.isEmpty
            || !diff.addedTexts.isEmpty || !diff.removedTexts.isEmpty || !diff.changedTexts.isEmpty
            || diff.screenChanged

        if assertNoDiff && hasChanges {
            return .error(id: command.id, message: "Assertion failed: screen state differs from snapshot '\(name)'. \(diff.summary)")
        }

        var data: [String: AnyCodable] = [
            "action": AnyCodable("diff"),
            "name": AnyCodable(name),
            "has_changes": AnyCodable(hasChanges),
            "baseline_screen": AnyCodable(baseline.screen),
            "current_screen": AnyCodable(current.screen),
            "screen_changed": AnyCodable(diff.screenChanged),
            "summary": AnyCodable(diff.summary)
        ]

        if !diff.added.isEmpty {
            data["added"] = AnyCodable(diff.added.map { AnyCodable($0) })
        }
        if !diff.removed.isEmpty {
            data["removed"] = AnyCodable(diff.removed.map { AnyCodable($0) })
        }
        if !diff.changed.isEmpty {
            data["changed"] = AnyCodable(diff.changed.map { AnyCodable($0) })
        }
        if !diff.addedTexts.isEmpty {
            data["added_texts"] = AnyCodable(diff.addedTexts.map { AnyCodable($0) })
        }
        if !diff.removedTexts.isEmpty {
            data["removed_texts"] = AnyCodable(diff.removedTexts.map { AnyCodable($0) })
        }
        if !diff.changedTexts.isEmpty {
            data["changed_texts"] = AnyCodable(diff.changedTexts.map { AnyCodable($0) })
        }

        logger.info("Diff against '\(name)': \(diff.summary)")
        return .ok(id: command.id, data: data)
    }

    // MARK: - List / Delete / Clear

    private func handleList(_ command: PepperCommand) -> PepperResponse {
        let names = SnapshotStore.shared.listNames()
        return .ok(id: command.id, data: [
            "action": AnyCodable("list"),
            "snapshots": AnyCodable(names.map { AnyCodable($0) }),
            "count": AnyCodable(names.count)
        ])
    }

    private func handleDelete(_ command: PepperCommand, name: String) -> PepperResponse {
        let existed = SnapshotStore.shared.delete(name)
        return .ok(id: command.id, data: [
            "action": AnyCodable("delete"),
            "name": AnyCodable(name),
            "deleted": AnyCodable(existed)
        ])
    }

    private func handleClear(_ command: PepperCommand) -> PepperResponse {
        let count = SnapshotStore.shared.clearAll()
        return .ok(id: command.id, data: [
            "action": AnyCodable("clear"),
            "cleared_count": AnyCodable(count)
        ])
    }

    // MARK: - Screen State Capture

    /// Capture current screen state by running introspect map and extracting
    /// the element/text data into a diffable representation.
    private func captureScreenState() -> ScreenState {
        let introspectHandler = IntrospectHandler()
        let cmd = PepperCommand(id: "snapshot-internal", cmd: "introspect", params: ["mode": AnyCodable("map")])
        let response = introspectHandler.handle(cmd)

        guard let data = response.data else {
            return ScreenState(screen: "unknown", elements: [], texts: [])
        }

        let screen = data["screen"]?.stringValue ?? "unknown"

        // Extract interactive elements from rows
        var elements: [ElementState] = []
        if let rows = data["rows"]?.arrayValue {
            for row in rows {
                if let rowDict = row.dictValue, let rowElements = rowDict["elements"]?.arrayValue {
                    for elem in rowElements {
                        if let elemDict = elem.dictValue {
                            elements.append(ElementState.from(elemDict))
                        }
                    }
                }
            }
        }

        // Extract non-interactive text
        var texts: [TextState] = []
        if let nonInteractive = data["non_interactive"]?.arrayValue {
            for item in nonInteractive {
                if let dict = item.dictValue {
                    texts.append(TextState.from(dict))
                }
            }
        }

        return ScreenState(screen: screen, elements: elements, texts: texts)
    }

    // MARK: - Diff Computation

    private func computeDiff(baseline: ScreenState, current: ScreenState, ignoreTransient: Bool) -> ScreenDiff {
        let screenChanged = baseline.screen != current.screen

        // Build lookup by identity key (label + type + index)
        let baselineByKey = Dictionary(grouping: baseline.elements, by: { $0.identityKey })
        let currentByKey = Dictionary(grouping: current.elements, by: { $0.identityKey })

        var added: [[String: AnyCodable]] = []
        var removed: [[String: AnyCodable]] = []
        var changed: [[String: AnyCodable]] = []

        // Find removed elements (in baseline but not current)
        for (key, baseElems) in baselineByKey {
            if currentByKey[key] == nil {
                for elem in baseElems {
                    removed.append(elem.serialize())
                }
            }
        }

        // Find added elements (in current but not baseline)
        for (key, curElems) in currentByKey {
            if baselineByKey[key] == nil {
                for elem in curElems {
                    added.append(elem.serialize())
                }
            }
        }

        // Find changed elements (same key, different properties)
        for (key, curElems) in currentByKey {
            guard let baseElems = baselineByKey[key] else { continue }
            // Compare first element of each group
            guard let curElem = curElems.first, let baseElem = baseElems.first else { continue }
            let changes = curElem.diff(from: baseElem)
            if !changes.isEmpty {
                var entry: [String: AnyCodable] = [
                    "element": AnyCodable(curElem.identityKey),
                    "changes": AnyCodable(changes.map { AnyCodable($0) })
                ]
                if let label = curElem.label {
                    entry["label"] = AnyCodable(label)
                }
                changed.append(entry)
            }
        }

        // Text diffing
        let baselineTextKeys = Set(baseline.texts.map { $0.identityKey })
        let currentTextKeys = Set(current.texts.map { $0.identityKey })
        let baselineTextByKey = Dictionary(grouping: baseline.texts, by: { $0.identityKey })
        let currentTextByKey = Dictionary(grouping: current.texts, by: { $0.identityKey })

        var addedTexts: [[String: AnyCodable]] = []
        var removedTexts: [[String: AnyCodable]] = []
        var changedTexts: [[String: AnyCodable]] = []

        for key in currentTextKeys.subtracting(baselineTextKeys) {
            if let items = currentTextByKey[key] {
                for item in items {
                    if ignoreTransient && item.isVolatile { continue }
                    addedTexts.append(item.serialize())
                }
            }
        }

        for key in baselineTextKeys.subtracting(currentTextKeys) {
            if let items = baselineTextByKey[key] {
                for item in items {
                    if ignoreTransient && item.isVolatile { continue }
                    removedTexts.append(item.serialize())
                }
            }
        }

        for key in currentTextKeys.intersection(baselineTextKeys) {
            guard let curItems = currentTextByKey[key], let baseItems = baselineTextByKey[key] else { continue }
            guard let cur = curItems.first, let base = baseItems.first else { continue }
            if ignoreTransient && (cur.isVolatile || base.isVolatile) { continue }
            let changes = cur.diff(from: base)
            if !changes.isEmpty {
                changedTexts.append([
                    "text": AnyCodable(cur.label),
                    "changes": AnyCodable(changes.map { AnyCodable($0) })
                ])
            }
        }

        let parts: [String] = [
            screenChanged ? "screen changed (\(baseline.screen) → \(current.screen))" : nil,
            added.isEmpty ? nil : "\(added.count) added",
            removed.isEmpty ? nil : "\(removed.count) removed",
            changed.isEmpty ? nil : "\(changed.count) changed",
            addedTexts.isEmpty ? nil : "\(addedTexts.count) texts added",
            removedTexts.isEmpty ? nil : "\(removedTexts.count) texts removed",
            changedTexts.isEmpty ? nil : "\(changedTexts.count) texts changed",
        ].compactMap { $0 }
        let summary = parts.isEmpty ? "no changes" : parts.joined(separator: ", ")

        return ScreenDiff(
            screenChanged: screenChanged,
            added: added, removed: removed, changed: changed,
            addedTexts: addedTexts, removedTexts: removedTexts, changedTexts: changedTexts,
            summary: summary
        )
    }
}

// MARK: - Data Types

/// Captured screen state for diffing.
struct ScreenState {
    let screen: String
    let elements: [ElementState]
    let texts: [TextState]
}

/// Serialized interactive element state.
struct ElementState {
    let label: String?
    let type: String
    let center: (x: Int, y: Int)
    let frame: (x: Int, y: Int, w: Int, h: Int)
    let value: String?
    let heuristic: String?
    let selected: Bool?
    let toggleState: String?
    let index: Int?

    /// Identity key for matching elements across snapshots.
    /// Uses label + type + index (not position, which can shift).
    var identityKey: String {
        let l = label ?? "_unlabeled"
        let idx = index.map { "[\($0)]" } ?? ""
        return "\(type):\(l)\(idx)"
    }

    static func from(_ dict: [String: AnyCodable]) -> ElementState {
        let centerArray = dict["center"]?.arrayValue
        let frameArray = dict["frame"]?.arrayValue
        return ElementState(
            label: dict["label"]?.stringValue,
            type: dict["type"]?.stringValue ?? "element",
            center: (
                x: centerArray?[0].intValue ?? 0,
                y: centerArray?[1].intValue ?? 0
            ),
            frame: (
                x: frameArray?[0].intValue ?? 0,
                y: frameArray?[1].intValue ?? 0,
                w: frameArray?[2].intValue ?? 0,
                h: frameArray?[3].intValue ?? 0
            ),
            value: dict["value"]?.stringValue,
            heuristic: dict["heuristic"]?.stringValue,
            selected: dict["selected"]?.boolValue,
            toggleState: dict["toggle_state"]?.stringValue,
            index: dict["index"]?.intValue
        )
    }

    func serialize() -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "type": AnyCodable(type)
        ]
        if let label = label { dict["label"] = AnyCodable(label) }
        if let value = value { dict["value"] = AnyCodable(value) }
        if let heuristic = heuristic { dict["heuristic"] = AnyCodable(heuristic) }
        if let selected = selected { dict["selected"] = AnyCodable(selected) }
        if let toggleState = toggleState { dict["toggle_state"] = AnyCodable(toggleState) }
        if let index = index { dict["index"] = AnyCodable(index) }
        dict["center"] = AnyCodable([AnyCodable(center.x), AnyCodable(center.y)])
        return dict
    }

    /// Compute property-level changes from another element state.
    func diff(from other: ElementState) -> [[String: AnyCodable]] {
        var changes: [[String: AnyCodable]] = []

        if value != other.value {
            changes.append([
                "property": AnyCodable("value"),
                "from": AnyCodable(other.value ?? "nil"),
                "to": AnyCodable(value ?? "nil")
            ])
        }
        if selected != other.selected {
            changes.append([
                "property": AnyCodable("selected"),
                "from": AnyCodable(other.selected.map { AnyCodable($0) } ?? AnyCodable("nil")),
                "to": AnyCodable(selected.map { AnyCodable($0) } ?? AnyCodable("nil"))
            ])
        }
        if toggleState != other.toggleState {
            changes.append([
                "property": AnyCodable("toggle_state"),
                "from": AnyCodable(other.toggleState ?? "nil"),
                "to": AnyCodable(toggleState ?? "nil")
            ])
        }
        // Position change (> 20pt threshold to ignore minor layout shifts)
        let dx = abs(center.x - other.center.x)
        let dy = abs(center.y - other.center.y)
        if dx > 20 || dy > 20 {
            changes.append([
                "property": AnyCodable("position"),
                "from": AnyCodable([AnyCodable(other.center.x), AnyCodable(other.center.y)]),
                "to": AnyCodable([AnyCodable(center.x), AnyCodable(center.y)])
            ])
        }
        return changes
    }
}

/// Serialized non-interactive text state.
struct TextState {
    let label: String
    let type: String
    let center: (x: Int, y: Int)
    let isVolatile: Bool

    var identityKey: String {
        label
    }

    static func from(_ dict: [String: AnyCodable]) -> TextState {
        let centerArray = dict["center"]?.arrayValue
        return TextState(
            label: dict["label"]?.stringValue ?? "",
            type: dict["type"]?.stringValue ?? "staticText",
            center: (
                x: centerArray?[0].intValue ?? 0,
                y: centerArray?[1].intValue ?? 0
            ),
            isVolatile: dict["volatile"]?.boolValue ?? false
        )
    }

    func serialize() -> [String: AnyCodable] {
        [
            "text": AnyCodable(label),
            "type": AnyCodable(type),
            "center": AnyCodable([AnyCodable(center.x), AnyCodable(center.y)])
        ]
    }

    func diff(from other: TextState) -> [[String: AnyCodable]] {
        var changes: [[String: AnyCodable]] = []
        let dx = abs(center.x - other.center.x)
        let dy = abs(center.y - other.center.y)
        if dx > 20 || dy > 20 {
            changes.append([
                "property": AnyCodable("position"),
                "from": AnyCodable([AnyCodable(other.center.x), AnyCodable(other.center.y)]),
                "to": AnyCodable([AnyCodable(center.x), AnyCodable(center.y)])
            ])
        }
        return changes
    }
}

/// Result of diffing two screen states.
struct ScreenDiff {
    let screenChanged: Bool
    let added: [[String: AnyCodable]]
    let removed: [[String: AnyCodable]]
    let changed: [[String: AnyCodable]]
    let addedTexts: [[String: AnyCodable]]
    let removedTexts: [[String: AnyCodable]]
    let changedTexts: [[String: AnyCodable]]
    let summary: String
}

// MARK: - Snapshot Store

/// Thread-safe in-memory store for screen state snapshots.
final class SnapshotStore {
    static let shared = SnapshotStore()

    private var snapshots: [String: ScreenState] = [:]
    private let lock = NSLock()

    func save(_ state: ScreenState, name: String) {
        lock.lock()
        snapshots[name] = state
        lock.unlock()
    }

    func load(_ name: String) -> ScreenState? {
        lock.lock()
        let state = snapshots[name]
        lock.unlock()
        return state
    }

    func delete(_ name: String) -> Bool {
        lock.lock()
        let existed = snapshots.removeValue(forKey: name) != nil
        lock.unlock()
        return existed
    }

    func clearAll() -> Int {
        lock.lock()
        let count = snapshots.count
        snapshots.removeAll()
        lock.unlock()
        return count
    }

    func listNames() -> [String] {
        lock.lock()
        let names = Array(snapshots.keys).sorted()
        lock.unlock()
        return names
    }
}
