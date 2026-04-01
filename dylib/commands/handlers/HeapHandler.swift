import Foundation
import ObjectiveC
import UIKit

/// Handles {"cmd": "heap"} commands for runtime object discovery.
///
/// Finds live objects in the running app by:
/// 1. Class enumeration via ObjC runtime
/// 2. Singleton/shared instance detection (calls .shared, .default, etc.)
/// 3. ViewController hierarchy walking
/// 4. UIView hierarchy walking (finds any view: GMSMapView, MKMapView, etc.)
/// 5. Malloc zone heap scan (finds any ObjC-compatible object, including pure Swift classes)
///
/// Actions:
///   - "find":       Find singleton/shared instance of a class. Params: class
///   - "inspect":    Mirror-dump a found instance. Params: class
///   - "read":       Read ObjC property via KVC. Params: class, key_path (e.g. "camera.zoom")
///   - "classes":    List loaded classes matching a pattern. Params: pattern
///   - "controllers": List all live UIViewControllers in the hierarchy
struct HeapHandler: PepperHandler {
    let commandName = "heap"
    let timeout: TimeInterval = 20.0

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "find"

        switch action {
        case "find":
            return handleFind(command)
        case "inspect":
            return handleInspect(command)
        case "read":
            return handleRead(command)
        case "classes":
            return handleClasses(command)
        case "controllers":
            return handleControllers(command)
        default:
            return .error(
                id: command.id, message: "Unknown heap action '\(action)'. Use find/inspect/read/classes/controllers.")
        }
    }

    // MARK: - Find Instance

    private func handleFind(_ command: PepperCommand) -> PepperResponse {
        guard let className = command.params?["class"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'class' param.")
        }

        guard let (obj, resolvedClass, method) = findInstance(className: className) else {
            return .error(
                id: command.id,
                message:
                    "No live instance found for '\(className)'. Checked singletons, VC/view hierarchy, and heap scan. Try 'classes' action to verify the class name."
            )
        }

        let mirror = Mirror(reflecting: obj)
        var props: [[String: AnyCodable]] = []
        walkMirror(mirror) { name, type, value in
            props.append([
                "name": AnyCodable(name),
                "type": AnyCodable(type),
                "value": AnyCodable(value),
            ])
        }

        return .ok(
            id: command.id,
            data: [
                "class": AnyCodable(resolvedClass),
                "found_via": AnyCodable(method),
                "address": AnyCodable(String(format: "%p", unsafeBitCast(obj as AnyObject, to: Int.self))),
                "property_count": AnyCodable(props.count),
                "properties": AnyCodable(props),
            ])
    }

    // MARK: - Inspect (alias for find with full dump)

    private func handleInspect(_ command: PepperCommand) -> PepperResponse {
        // Same as find — both return full property dump
        return handleFind(command)
    }

    // MARK: - Read Property (KVC)

    private func handleRead(_ command: PepperCommand) -> PepperResponse {
        guard let className = command.params?["class"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'class' param.")
        }
        guard let keyPath = command.params?["key_path"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'key_path' param (e.g. 'camera.zoom').")
        }

        guard let (obj, resolvedClass, method) = findInstance(className: className) else {
            return .error(id: command.id, message: "No instance found for '\(className)'.")
        }

        guard let nsObj = obj as? NSObject else {
            return .error(id: command.id, message: "'\(resolvedClass)' is not an NSObject — KVC not available.")
        }

        // Read via KVC, catching ObjC exceptions for invalid key paths
        var result: Any?
        var caughtException: NSException?
        PepperObjCExceptionCatcher.try(
            {
                result = nsObj.value(forKeyPath: keyPath)
            },
            catch: { exception in
                caughtException = exception
            })

        if let exception = caughtException {
            return .error(
                id: command.id,
                message:
                    "KVC failed for '\(keyPath)' on \(resolvedClass): \(exception.reason ?? exception.name.rawValue)")
        }

        let valueStr: String
        let valueType: String
        if let result = result {
            valueStr = describeValue(result)
            valueType = String(describing: type(of: result))
        } else {
            valueStr = "nil"
            valueType = "nil"
        }

        return .ok(
            id: command.id,
            data: [
                "class": AnyCodable(resolvedClass),
                "found_via": AnyCodable(method),
                "key_path": AnyCodable(keyPath),
                "value": AnyCodable(valueStr),
                "type": AnyCodable(valueType),
            ])
    }

    // MARK: - List Classes

    private func handleClasses(_ command: PepperCommand) -> PepperResponse {
        let pattern = command.params?["pattern"]?.stringValue
        let limit = command.params?["limit"]?.intValue ?? 20
        let offset = command.params?["offset"]?.intValue ?? 0

        guard let pattern = pattern, !pattern.isEmpty else {
            return .error(
                id: command.id, message: "Missing 'pattern' param. Provide a search string (e.g. 'Manager', 'Service')."
            )
        }

        let count = Int(objc_getClassList(nil, 0))
        guard count > 0 else {
            return .error(id: command.id, message: "Failed to get class list.")
        }

        let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: count)
        let actualCount = Int(objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), Int32(count)))
        defer { buffer.deallocate() }

        let lowerPattern = pattern.lowercased()
        var matches: [String] = []
        for i in 0..<actualCount {
            let name = NSStringFromClass(buffer[i])
            if name.lowercased().contains(lowerPattern) {
                matches.append(name)
            }
            if matches.count > 500 { break }
        }

        matches.sort()
        let total = matches.count
        let page = Array(matches.dropFirst(min(offset, matches.count)).prefix(limit))

        return .ok(
            id: command.id,
            data: [
                "pattern": AnyCodable(pattern),
                "total": AnyCodable(total),
                "offset": AnyCodable(offset),
                "showing": AnyCodable(page.count),
                "has_more": AnyCodable(offset + page.count < total),
                "classes": AnyCodable(page),
            ])
    }

    // MARK: - List Controllers

    private func handleControllers(_ command: PepperCommand) -> PepperResponse {
        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window found.")
        }

        let limit = command.params?["limit"]?.intValue ?? 20
        let offset = command.params?["offset"]?.intValue ?? 0

        var controllers: [[String: AnyCodable]] = []
        func walk(_ vc: UIViewController, depth: Int) {
            let name = String(describing: type(of: vc))
            var entry: [String: AnyCodable] = [
                "class": AnyCodable(name),
                "depth": AnyCodable(depth),
                "title": AnyCodable(vc.title ?? ""),
                "isVisible": AnyCodable(vc.isViewLoaded && vc.view.window != nil),
            ]
            if let nav = vc as? UINavigationController {
                entry["stack_count"] = AnyCodable(nav.viewControllers.count)
            }
            if let tab = vc as? UITabBarController {
                entry["tab_count"] = AnyCodable(tab.viewControllers?.count ?? 0)
                entry["selected_tab"] = AnyCodable(tab.selectedIndex)
            }
            controllers.append(entry)

            for child in vc.children {
                walk(child, depth: depth + 1)
            }
            if let presented = vc.presentedViewController, presented.presentingViewController == vc {
                walk(presented, depth: depth + 1)
            }
        }

        if let rootVC = window.rootViewController {
            walk(rootVC, depth: 0)
        }

        let total = controllers.count
        let page = Array(controllers.dropFirst(min(offset, controllers.count)).prefix(limit))

        return .ok(
            id: command.id,
            data: [
                "count": AnyCodable(page.count),
                "total": AnyCodable(total),
                "offset": AnyCodable(offset),
                "has_more": AnyCodable(offset + page.count < total),
                "controllers": AnyCodable(page),
            ])
    }

    // MARK: - Instance Discovery

    /// Find a live instance by class name. Tries multiple strategies:
    /// 1. ObjC runtime class lookup → singleton selectors (shared, default, etc.)
    /// 2. Search the ViewController hierarchy
    /// 3. Search the UIView hierarchy (any view subclass)
    private func findInstance(className: String) -> (Any, String, String)? {
        // Resolve the class
        guard let cls = resolveClass(className) else { return nil }
        let resolvedName = NSStringFromClass(cls)

        // Strategy 1: Try singleton selectors
        let singletonSelectors = [
            "shared", "sharedInstance", "default", "defaultManager",
            "current", "main", "standard", "currentUser",
        ]
        for selName in singletonSelectors {
            let sel = NSSelectorFromString(selName)
            // Check if the class (as meta-class) responds to this selector
            guard object_getClass(cls) != nil else { continue }
            if class_getClassMethod(cls, sel) != nil {
                // Call the class method
                if let result = (cls as AnyObject).perform(sel)?.takeUnretainedValue() {
                    return (result, resolvedName, ".\(selName)")
                }
            }
        }

        // Strategy 2: Walk ViewController hierarchy
        if let window = UIWindow.pepper_keyWindow, let rootVC = window.rootViewController {
            if let found = findInControllerHierarchy(rootVC, targetClass: cls) {
                return (found, resolvedName, "vc_hierarchy")
            }
        }

        // Strategy 3: Walk UIView hierarchy (finds any view, e.g. GMSMapView, MKMapView)
        if let window = UIWindow.pepper_keyWindow {
            if let found = findInViewHierarchy(window, targetClass: cls) {
                return (found, resolvedName, "view_hierarchy")
            }
        }

        // Strategy 4: Malloc zone heap scan — finds any ObjC-compatible object on the heap,
        // including pure Swift classes not reachable via singletons or UIKit hierarchy.
        if let found = findOnHeap(cls) {
            return (found, resolvedName, "heap_scan")
        }

        return nil
    }

    /// Resolve a class name, trying exact match and app module prefix.
    private func resolveClass(_ name: String) -> AnyClass? {
        // Exact match
        if let cls = NSClassFromString(name) { return cls }

        // Try with app module prefix
        let bundleName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? ""
        let moduleName = bundleName.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        if let cls = NSClassFromString("\(moduleName).\(name)") { return cls }

        // Try configured class lookup prefixes
        for prefix in PepperAppConfig.shared.classLookupPrefixes {
            if let cls = NSClassFromString("\(prefix).\(name)") { return cls }
        }

        return nil
    }

    /// Walk the ViewController hierarchy looking for a specific class.
    private func findInControllerHierarchy(_ vc: UIViewController, targetClass: AnyClass) -> UIViewController? {
        if object_getClass(vc) == targetClass || vc.isKind(of: targetClass) {
            return vc
        }
        for child in vc.children {
            if let found = findInControllerHierarchy(child, targetClass: targetClass) {
                return found
            }
        }
        if let presented = vc.presentedViewController, presented.presentingViewController == vc {
            if let found = findInControllerHierarchy(presented, targetClass: targetClass) {
                return found
            }
        }
        return nil
    }

    /// Walk the UIView hierarchy looking for a specific class (e.g. GMSMapView, MKMapView).
    private func findInViewHierarchy(_ view: UIView, targetClass: AnyClass) -> UIView? {
        if object_getClass(view) == targetClass || view.isKind(of: targetClass) {
            return view
        }
        for subview in view.subviews {
            if let found = findInViewHierarchy(subview, targetClass: targetClass) {
                return found
            }
        }
        return nil
    }

    /// Find an instance on the heap via malloc zone enumeration.
    /// Falls back to this when ObjC runtime strategies (singletons, VC/view hierarchy) fail.
    private func findOnHeap(_ cls: AnyClass) -> AnyObject? {
        var targetPtrs: [UnsafeRawPointer?] = [unsafeBitCast(cls, to: UnsafeRawPointer.self)]

        var instancesPtr: UnsafeMutablePointer<UnsafeRawPointer?>?
        var classesPtr: UnsafeMutablePointer<UnsafeRawPointer?>?
        var count: Int32 = 0

        let result = targetPtrs.withUnsafeMutableBufferPointer { buf in
            pepper_heap_find_instances(buf.baseAddress!, Int32(buf.count), &instancesPtr, &classesPtr, &count)
        }

        guard result == 0, count > 0, let instances = instancesPtr, let classes = classesPtr else { return nil }
        defer {
            free(instances)
            free(classes)
        }

        // Return the first live instance (with liveness validation)
        for i in 0..<Int(count) {
            guard let instancePtr = instances[i] else { continue }

            // Liveness check: malloc_size returns 0 for freed blocks
            guard malloc_size(instancePtr) >= MemoryLayout<UnsafeRawPointer>.size else { continue }
            // Verify isa pointer still matches — guards against freed+reused memory
            guard let expectedClassPtr = classes[i] else { continue }
            let isaPtr = instancePtr.load(as: UnsafeRawPointer.self)
            guard isaPtr == expectedClassPtr else { continue }

            return Unmanaged<AnyObject>.fromOpaque(instancePtr).takeUnretainedValue()
        }

        return nil
    }

    // MARK: - Helpers

    private func walkMirror(_ mirror: Mirror, depth: Int = 0, handler: (String, String, String) -> Void) {
        if let superMirror = mirror.superclassMirror, depth < 5 {
            walkMirror(superMirror, depth: depth + 1, handler: handler)
        }
        for child in mirror.children {
            guard let label = child.label else { continue }
            let name = label.hasPrefix("_") ? String(label.dropFirst()) : label
            let type = String(describing: Swift.type(of: child.value))
            let value = describeValue(child.value)
            handler(name, type, value)
        }
    }

    private func describeValue(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let child = mirror.children.first {
                return describeValue(child.value)
            }
            return "nil"
        }
        let str = String(describing: value)
        return str.count > 200 ? String(str.prefix(197)) + "..." : str
    }
}
