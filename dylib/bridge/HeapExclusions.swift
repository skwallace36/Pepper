import Foundation

/// Known-benign class name patterns excluded from leak detection.
///
/// The C heap scanner (`PepperHeapScan.c`) filters system frameworks by prefix,
/// but some classes slip through — especially module-qualified names that pass
/// the "contains dot" heuristic. This Swift-level filter catches the rest.
///
/// Two categories:
/// 1. **Exact names** — runtime internals that grow with normal execution
/// 2. **Substring patterns** — class families that fluctuate without leaking
enum HeapExclusions {

    /// Class names that grow during normal runtime and aren't leaks.
    private static let exactNames: Set<String> = [
        // Block runtime types (may survive C-level prefix filter via module qualification)
        "__NSMallocBlock__",
        "__NSStackBlock__",
        "__NSGlobalBlock__",
        "NSMallocBlock",
        "NSStackBlock",
        "NSBlock",
        // Autorelease internals
        "NSAutoreleasePool",
        "AutoreleasepoolPage",
        // Dispatch internals
        "OS_dispatch_data",
        "OS_dispatch_queue",
        "OS_dispatch_source",
        "OS_dispatch_continuation",
        "OS_dispatch_group",
        "OS_dispatch_semaphore",
        // SwiftUI layout/hosting internals (short names after module strip)
        "StoredLocationBase",
        "HostingScrollView",
        "PlatformViewHost",
        "DisplayList",
        "ViewCache",
        // Combine pipeline objects
        "AnyCancellable",
        "PublishedSubject",
        // Foundation transient objects
        "NSKeyValueObservance",
        "NSConcreteValue",
    ]

    /// Substrings indicating benign growth when found anywhere in a class name.
    private static let benignSubstrings: [String] = [
        "MallocBlock",
        "StackBlock",
        "GlobalBlock",
        "AutoreleasePool",
        "LayoutCache",
        "LayoutEngine",
        "_UIHostingView",
        "DisplayLink",
        "RunLoop",
        "AttributeGraph",
        "_AG",
    ]

    /// Minimum seconds after baseline before growth is treated as suspicious.
    /// Lets autorelease pools drain, lazy initializers fire, and layout settle.
    static let warmupSeconds: Int = 5

    /// Minimum screen observations in PepperLeakMonitor before reporting.
    /// The first N visits build a stable baseline.
    static let warmupObservations: Int = 2

    /// Returns true if the class name matches a known-benign growth pattern.
    static func isBenign(_ className: String) -> Bool {
        if exactNames.contains(className) { return true }
        for sub in benignSubstrings {
            if className.contains(sub) { return true }
        }
        return false
    }
}
