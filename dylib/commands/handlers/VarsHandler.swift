import Foundation

/// Handles {"cmd": "vars"} commands for runtime variable inspection and mutation.
///
/// Actions:
///   - "list":     List all discovered ObservableObject instances and their @Published properties.
///   - "get":      Get a specific property value. Params: path ("ClassName.propertyName")
///   - "set":      Set a property value and trigger re-render. Params: path, value
///   - "discover": Force re-scan the current VC hierarchy for ObservableObjects.
///   - "dump":     Dump all properties of a specific class. Params: class
struct VarsHandler: PepperHandler {
    let commandName = "vars"
    /// Heap scan on first call can take 30+s on complex apps.
    var timeout: TimeInterval { 45.0 }

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "list"

        switch action {
        case "list":
            return handleList(command)
        case "get":
            return handleGet(command)
        case "set":
            return handleSet(command)
        case "discover":
            return handleDiscover(command)
        case "dump":
            return handleDump(command)
        case "mirror":
            return handleMirror(command)
        default:
            return .error(
                id: command.id, message: "Unknown vars action '\(action)'. Use list/get/set/discover/dump/mirror.")
        }
    }

    // MARK: - Actions

    /// Default cap for unbounded list to prevent crashes on large apps.
    private static let listLimit = 50

    private func handleList(_ command: PepperCommand) -> PepperResponse {
        PepperVarRegistry.shared.discoverFromHeapIfNeeded()

        let classFilter = command.params?["class"]?.stringValue
        let limit = command.params?["limit"]?.intValue ?? Self.listLimit

        let allInstances = PepperVarRegistry.shared.listAll(classFilter: classFilter)
        let truncated = allInstances.count > limit
        let instances = truncated ? Array(allInstances.prefix(limit)) : allInstances

        var data: [String: AnyCodable] = [
            "instances": AnyCodable(instances),
            "count": AnyCodable(allInstances.count),
        ]
        if truncated {
            data["truncated"] = AnyCodable(true)
            data["hint"] = AnyCodable("Showing \(limit) of \(allInstances.count). Use class filter or increase limit.")
        }
        return .ok(id: command.id, data: data)
    }

    private func handleGet(_ command: PepperCommand) -> PepperResponse {
        guard let path = command.params?["path"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'path' param. Use 'ClassName.propertyName'.")
        }

        guard let value = PepperVarRegistry.shared.getValue(path: path) else {
            return .error(id: command.id, message: "Property not found: '\(path)'. Run action:discover to refresh.")
        }

        return .ok(
            id: command.id,
            data: [
                "path": AnyCodable(path),
                "value": value,
            ])
    }

    private func handleSet(_ command: PepperCommand) -> PepperResponse {
        guard let path = command.params?["path"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'path' param. Use 'ClassName.propertyName'.")
        }

        guard let value = command.params?["value"] else {
            return .error(id: command.id, message: "Missing 'value' param.")
        }

        let (newValue, changes, renders, error) = PepperVarRegistry.shared.setValueWithChangeTracking(
            path: path, jsonValue: value)

        if let error = error {
            return .error(id: command.id, message: error)
        }

        var data: [String: AnyCodable] = [
            "path": AnyCodable(path),
            "ok": AnyCodable(true),
            "changes": AnyCodable(changes.map { AnyCodable($0.toDict()) }),
        ]
        if let newValue = newValue {
            data["value"] = newValue
        }
        if !renders.isEmpty {
            data["renders"] = AnyCodable(renders)
        }
        return .ok(id: command.id, data: data)
    }

    private func handleDiscover(_ command: PepperCommand) -> PepperResponse {
        PepperVarRegistry.shared.forceDiscover()

        let classFilter = command.params?["class"]?.stringValue
        let limit = command.params?["limit"]?.intValue ?? Self.listLimit

        let allInstances = PepperVarRegistry.shared.listAll(classFilter: classFilter)
        let truncated = allInstances.count > limit
        let instances = truncated ? Array(allInstances.prefix(limit)) : allInstances

        var data: [String: AnyCodable] = [
            "instances": AnyCodable(instances),
            "count": AnyCodable(allInstances.count),
        ]
        if truncated {
            data["truncated"] = AnyCodable(true)
            data["hint"] = AnyCodable("Showing \(limit) of \(allInstances.count). Use class filter or increase limit.")
        }
        return .ok(id: command.id, data: data)
    }

    private func handleDump(_ command: PepperCommand) -> PepperResponse {
        guard let className = command.params?["class"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'class' param.")
        }

        guard let props = PepperVarRegistry.shared.dumpClass(className) else {
            return .error(
                id: command.id, message: "No tracked instance of '\(className)'. Run action:discover to refresh.")
        }

        return .ok(
            id: command.id,
            data: [
                "class": AnyCodable(className),
                "properties": AnyCodable(props),
            ])
    }

    private func handleMirror(_ command: PepperCommand) -> PepperResponse {
        guard let className = command.params?["class"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'class' param.")
        }

        guard let result = PepperVarRegistry.shared.mirrorAll(className) else {
            return .error(
                id: command.id, message: "No tracked instance of '\(className)'. Run action:discover to refresh.")
        }

        return .ok(
            id: command.id,
            data: [
                "class": AnyCodable(className),
                "properties": AnyCodable(result),
            ])
    }
}
