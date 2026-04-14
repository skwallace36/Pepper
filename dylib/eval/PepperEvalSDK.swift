// PepperEvalSDK.swift
// Compiled alongside dynamically injected eval code.
// Provides a clean Swift API for accessing Pepper's runtime from eval expressions.
//
// Calls @_cdecl exports from Pepper.framework via dlsym. Pepper is already loaded
// in the host process, so symbols resolve at dlopen time.

import Foundation
import UIKit

// MARK: - Pepper Namespace

/// Entry point for all Pepper runtime APIs from eval code.
public enum Pepper {
    /// Variable registry — read/write @Published and @Observable properties.
    public static let vars = VarsBridge()

    /// Heap introspection — find live objects by class name.
    public static let heap = HeapBridge()

    /// Sampling profiler — capture main thread stacks.
    public static let profiler = ProfilerBridge()

    /// Convenience: get the key window.
    public static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow }
    }

    /// Convenience: root view controller.
    public static var rootVC: UIViewController? {
        keyWindow?.rootViewController
    }

    /// Convenience: Mirror any object's stored properties.
    public static func mirror(_ obj: Any) -> [(label: String, value: Any)] {
        Mirror(reflecting: obj).children.map { ($0.label ?? "?", $0.value) }
    }

    /// Convenience: find all view controllers in the hierarchy.
    public static func allVCs() -> [UIViewController] {
        guard let root = rootVC else { return [] }
        var result: [UIViewController] = []
        var queue: [UIViewController] = [root]
        while !queue.isEmpty {
            let vc = queue.removeFirst()
            result.append(vc)
            queue.append(contentsOf: vc.children)
            if let presented = vc.presentedViewController {
                queue.append(presented)
            }
        }
        return result
    }
}

// MARK: - Symbol Resolution

/// Resolve a C function from Pepper.framework by name.
private func sym<T>(_ name: String) -> T? {
    guard let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
    return unsafeBitCast(ptr, to: T.self)
}

/// Parse a JSON C string into a Swift value, then free the pointer.
private func parseJSON(_ cstr: UnsafePointer<CChar>) -> Any? {
    let str = String(cString: cstr)
    free(UnsafeMutablePointer(mutating: cstr))
    guard let data = str.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

// MARK: - VarsBridge

public struct VarsBridge {
    /// List all tracked observable instances and their properties.
    public func list(classFilter: String? = nil) -> [[String: Any]] {
        typealias F = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>
        guard let fn: F = sym("pepper_vars_list_json") else { return [] }
        let cstr = classFilter.map { ($0 as NSString).utf8String } ?? nil
        let result = fn(cstr)
        return (parseJSON(result) as? [[String: Any]]) ?? []
    }

    /// Get a property value. Path format: "ClassName.propertyName"
    public func get(_ path: String) -> Any? {
        typealias F = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>
        guard let fn: F = sym("pepper_vars_get_json") else { return nil }
        let result = fn((path as NSString).utf8String!)
        let parsed = parseJSON(result)
        // Unwrap {"_": value} wrapper for scalars
        if let dict = parsed as? [String: Any], let wrapped = dict["_"] {
            return wrapped
        }
        return parsed
    }

    /// Set a property value. Triggers SwiftUI re-render automatically.
    @discardableResult
    public func set(_ path: String, to value: Any) -> Any? {
        typealias F = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafePointer<CChar>
        guard let fn: F = sym("pepper_vars_set_json") else { return nil }
        // Wrap scalar values so JSONSerialization can handle them
        let wrapped: Any = JSONSerialization.isValidJSONObject(value) ? value : [value]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: wrapped),
            var jsonStr = String(data: jsonData, encoding: .utf8)
        else { return nil }
        // Unwrap the array wrapper for scalars
        if !JSONSerialization.isValidJSONObject(value) {
            // "[42]" -> "42"
            jsonStr = String(jsonStr.dropFirst().dropLast())
        }
        let result = fn((path as NSString).utf8String!, (jsonStr as NSString).utf8String!)
        return parseJSON(result)
    }

    /// Mirror ALL properties of a tracked class (not just @Published).
    public func mirrorAll(_ className: String) -> [[String: Any]]? {
        typealias F = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>
        guard let fn: F = sym("pepper_vars_mirror_json") else { return nil }
        let result = fn((className as NSString).utf8String!)
        return parseJSON(result) as? [[String: Any]]
    }

    /// Force re-discover observable instances from VC hierarchy + heap.
    public func discover() {
        typealias F = @convention(c) () -> Void
        guard let fn: F = sym("pepper_vars_discover") else { return }
        fn()
    }
}

// MARK: - HeapBridge

public struct HeapBridge {
    /// Find a live instance by class name. Searches singletons, VC hierarchy.
    public func find(_ className: String) -> AnyObject? {
        guard let cls = NSClassFromString(className) else { return nil }

        let singletonSelectors = ["shared", "sharedInstance", "default", "current", "main", "standard"]
        for sel in singletonSelectors {
            let selector = NSSelectorFromString(sel)
            if cls.responds(to: selector) {
                if let result = (cls as AnyObject).perform(selector)?.takeUnretainedValue() {
                    return result
                }
            }
        }

        if let vcClass = cls as? UIViewController.Type {
            for vc in Pepper.allVCs() where type(of: vc) == vcClass {
                return vc
            }
        }

        return nil
    }

    /// Find a live instance by type (compile-time type access).
    public func find<T: AnyObject>(_ type: T.Type) -> T? {
        find(String(describing: type)) as? T
    }

    /// List ObjC classes matching a pattern.
    public func classes(matching pattern: String) -> [String] {
        var count: UInt32 = 0
        guard let classList = objc_copyClassList(&count) else { return [] }
        defer { free(UnsafeMutableRawPointer(classList)) }

        let lowered = pattern.lowercased()
        return (0..<Int(count))
            .map { NSStringFromClass(classList[$0]) }
            .filter { $0.lowercased().contains(lowered) }
            .sorted()
    }
}

// MARK: - ProfilerBridge

public struct ProfilerBridge {
    /// Start sampling the main thread at given interval.
    public func start(intervalUs: Int = 1000) {
        typealias F = @convention(c) (Int32) -> Void
        guard let fn: F = sym("pepper_profiler_start") else { return }
        fn(Int32(intervalUs))
    }

    /// Stop and return the profile report as a formatted string.
    public func stop() -> String {
        typealias F = @convention(c) () -> UnsafePointer<CChar>
        guard let fn: F = sym("pepper_profiler_stop_json") else { return "profiler not available" }
        let result = fn()
        let str = String(cString: result)
        free(UnsafeMutablePointer(mutating: result))
        return str
    }

    /// Check if profiler is running.
    public var isRunning: Bool {
        typealias F = @convention(c) () -> Bool
        guard let fn: F = sym("pepper_profiler_is_running") else { return false }
        return fn()
    }

    /// Current sample count.
    public var sampleCount: Int {
        typealias F = @convention(c) () -> Int32
        guard let fn: F = sym("pepper_profiler_sample_count") else { return 0 }
        return Int(fn())
    }
}
