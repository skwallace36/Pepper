import Foundation

// C-callable exports from Pepper.framework for use by dynamically compiled eval code.
// These are resolved at dlopen time via -undefined dynamic_lookup.
// The PepperEvalSDK.swift wrapper calls these via dlsym so eval code gets a clean API.

// MARK: - Var Registry

/// List all tracked observable instances as JSON string.
@_cdecl("pepper_vars_list_json")
public func pepperVarsListJSON(_ classFilter: UnsafePointer<CChar>?) -> UnsafePointer<CChar> {
    let filter = classFilter.map { String(cString: $0) }
    let results = PepperVarRegistry.shared.listAll(classFilter: filter)
    return jsonCString(results.map { dict in dict.mapValues { $0.value } })
}

/// Get a property value as JSON string. Path: "ClassName.propertyName"
@_cdecl("pepper_vars_get_json")
public func pepperVarsGetJSON(_ path: UnsafePointer<CChar>) -> UnsafePointer<CChar> {
    let pathStr = String(cString: path)
    if let value = PepperVarRegistry.shared.getValue(path: pathStr) {
        return jsonCString(value.value)
    }
    return staticCString("null")
}

/// Set a property value. Returns new value as JSON string.
@_cdecl("pepper_vars_set_json")
public func pepperVarsSetJSON(
    _ path: UnsafePointer<CChar>, _ valueJSON: UnsafePointer<CChar>
) -> UnsafePointer<CChar> {
    let pathStr = String(cString: path)
    let valueStr = String(cString: valueJSON)

    // Parse the JSON value — handle scalars by wrapping in array
    guard let data = valueStr.data(using: .utf8) else {
        return staticCString("{\"error\":\"invalid UTF-8\"}")
    }
    let parsed: Any
    if let obj = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
        parsed = obj
    } else {
        return staticCString("{\"error\":\"invalid JSON: \(valueStr)\"}")
    }

    let (result, error) = PepperVarRegistry.shared.setValue(
        path: pathStr, jsonValue: AnyCodable(parsed))

    if let error = error {
        return jsonCString(["error": error])
    }
    return jsonCString(result?.value ?? NSNull())
}

/// Mirror all properties of a class as JSON string.
@_cdecl("pepper_vars_mirror_json")
public func pepperVarsMirrorJSON(_ className: UnsafePointer<CChar>) -> UnsafePointer<CChar> {
    let name = String(cString: className)
    if let results = PepperVarRegistry.shared.mirrorAll(name) {
        return jsonCString(results.map { $0.mapValues { $0.value } })
    }
    return staticCString("null")
}

/// Force re-discover observable instances.
@_cdecl("pepper_vars_discover")
public func pepperVarsDiscover() {
    PepperVarRegistry.shared.forceDiscover()
}

// MARK: - Profiler

@_cdecl("pepper_profiler_start")
public func pepperProfilerStart(_ intervalUs: Int32) {
    PepperSamplingProfiler.shared.start(intervalUs: Int(intervalUs))
}

@_cdecl("pepper_profiler_stop_json")
public func pepperProfilerStopJSON() -> UnsafePointer<CChar> {
    let report = PepperSamplingProfiler.shared.stop()
    let dict = report.toDictionary()
    return jsonCString((dict["summary"]?.value as? String) ?? "No samples")
}

@_cdecl("pepper_profiler_is_running")
public func pepperProfilerIsRunning() -> Bool {
    PepperSamplingProfiler.shared.isRunning
}

@_cdecl("pepper_profiler_sample_count")
public func pepperProfilerSampleCount() -> Int32 {
    Int32(PepperSamplingProfiler.shared.sampleCount)
}

// MARK: - Helpers

/// Serialize any value to JSON and return as strdup'd C string.
/// Non-JSON-serializable values are converted to their String description.
private func jsonCString(_ value: Any) -> UnsafePointer<CChar> {
    let sanitized = sanitizeForJSON(value)
    do {
        let data: Data
        if JSONSerialization.isValidJSONObject(sanitized) {
            data = try JSONSerialization.data(withJSONObject: sanitized)
        } else {
            data = try JSONSerialization.data(withJSONObject: ["_": sanitized])
        }
        let str = String(data: data, encoding: .utf8) ?? "null"
        return UnsafePointer(strdup(str)!)
    } catch {
        return UnsafePointer(strdup("null")!)
    }
}

/// Recursively convert non-JSON-serializable values to strings.
private func sanitizeForJSON(_ value: Any) -> Any {
    switch value {
    case let dict as [String: Any]:
        return dict.mapValues { sanitizeForJSON($0) }
    case let array as [Any]:
        return array.map { sanitizeForJSON($0) }
    case let str as String:
        return str
    case let num as NSNumber:
        return num
    case is NSNull:
        return NSNull()
    default:
        // Check if JSONSerialization can handle it
        if JSONSerialization.isValidJSONObject([value]) {
            return value
        }
        return String(describing: value)
    }
}

private func staticCString(_ str: String) -> UnsafePointer<CChar> {
    UnsafePointer(strdup(str)!)
}
