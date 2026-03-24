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

    private func handleList(_ command: PepperCommand) -> PepperResponse {
        let instances = PepperVarRegistry.shared.listAll()
        return .ok(
            id: command.id,
            data: [
                "instances": AnyCodable(instances),
                "count": AnyCodable(instances.count),
            ])
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

        let (newValue, error) = PepperVarRegistry.shared.setValue(path: path, jsonValue: value)

        if let error = error {
            return .error(id: command.id, message: error)
        }

        var data: [String: AnyCodable] = [
            "path": AnyCodable(path),
            "ok": AnyCodable(true),
        ]
        if let newValue = newValue {
            data["value"] = newValue
        }
        return .ok(id: command.id, data: data)
    }

    private func handleDiscover(_ command: PepperCommand) -> PepperResponse {
        PepperVarRegistry.shared.forceDiscover()
        let instances = PepperVarRegistry.shared.listAll()
        return .ok(
            id: command.id,
            data: [
                "instances": AnyCodable(instances),
                "count": AnyCodable(instances.count),
            ])
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
