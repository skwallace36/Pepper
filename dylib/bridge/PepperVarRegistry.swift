import Foundation
import UIKit
import ObjectiveC

/// C function — find live instances of specific classes on the heap.
/// Implemented in PepperHeapScan.c.
@_silgen_name("pepper_heap_find_instances")
func pepper_heap_find_instances(
    _ target_classes: UnsafePointer<UnsafeRawPointer?>,
    _ target_count: Int32,
    _ out_instances: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeRawPointer?>?>,
    _ out_classes: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeRawPointer?>?>,
    _ out_count: UnsafeMutablePointer<Int32>
) -> Int32

/// Discovers and catalogs @Published properties on ObservableObject instances at runtime.
/// Supports reading and writing values, triggering SwiftUI re-renders on mutation.
///
/// Discovery is triggered automatically from `pepper_viewDidAppear` — each VC's view
/// hierarchy is walked to find UIHostingController rootViews and regular VC stored properties
/// that conform to ObservableObject.
///
/// Additionally, `discoverFromHeap()` scans the process heap for @Observable instances
/// (classes with a `_$observationRegistrar` ivar) — independent of SwiftUI view tree structure.
final class PepperVarRegistry {

    static let shared = PepperVarRegistry()

    // MARK: - Types

    /// Supported property types for serialization and write.
    enum VarType: String {
        case int, double, cgfloat, bool, string
        case cgSize, edgeInsets, color
        case optional  // wraps an inner type
        case unknown   // read-only, serialized as string description
    }

    /// Cached metadata for a single @Published property.
    struct PropertyInfo {
        let name: String          // property name (without underscore)
        let type: VarType
        let innerType: VarType?   // for Optional<T>, the inner type
        let typeName: String      // raw Swift type name string
        let ivarName: String      // ivar name in the class (with underscore prefix)
        let ivarOffset: Int?      // byte offset for raw memory access
    }

    /// A tracked ObservableObject or @Observable instance with its class name and property catalog.
    struct TrackedInstance {
        let className: String
        weak var instance: AnyObject?
        let properties: [PropertyInfo]
        let isObservable: Bool  // true = @Observable (Observation framework), false = ObservableObject + @Published
    }

    // MARK: - State

    /// Tracked instances. Weak refs auto-nil when objects dealloc.
    private var tracked: [TrackedInstance] = []
    private let lock = NSLock()

    /// Property catalog cache keyed by class name — avoids re-cataloging the same class.
    private var catalogCache: [String: [PropertyInfo]] = [:]

    /// Whether the initial heap scan for @Observable has run.
    private var didInitialHeapScan = false

    private init() {}

    // MARK: - Discovery

    /// Discover ObservableObject instances from a view controller's hierarchy.
    /// Called from pepper_viewDidAppear.
    func discoverFromViewController(_ vc: UIViewController) {
        // Skip container VCs
        if vc is UINavigationController || vc is UITabBarController || vc is UISplitViewController {
            return
        }

        lock.lock()
        // Prune dead refs
        tracked.removeAll { $0.instance == nil }
        lock.unlock()

        // UIHostingController: Mirror rootView for @StateObject/@ObservedObject refs
        let vcMirror = Mirror(reflecting: vc)
        let vcTypeName = String(describing: type(of: vc))

        if vcTypeName.contains("UIHostingController") {
            // Find the rootView property
            for child in vcMirror.children {
                if child.label == "rootView" || child.label == "_rootView" {
                    discoverFromSwiftUIView(child.value, depth: 0)
                    break
                }
            }
        }

        // Also mirror the VC itself for stored ObservableObject properties
        discoverFromObject(vc)

        // Walk child VCs
        for child in vc.children {
            let childTypeName = String(describing: type(of: child))
            if childTypeName.contains("UIHostingController") {
                let childMirror = Mirror(reflecting: child)
                for prop in childMirror.children {
                    if prop.label == "rootView" || prop.label == "_rootView" {
                        discoverFromSwiftUIView(prop.value, depth: 0)
                        break
                    }
                }
            }
        }

        // Run heap-based @Observable discovery once on first viewDidAppear
        if !didInitialHeapScan {
            didInitialHeapScan = true
            discoverFromHeap()
        }
    }

    /// Force re-scan: discover from all visible VCs + heap scan for @Observable.
    func forceDiscover() {
        lock.lock()
        tracked.removeAll { $0.instance == nil }
        lock.unlock()

        for window in UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            where window.isKeyWindow {
            if let rootVC = window.rootViewController {
                discoverFromVCTree(rootVC)
            }
        }

        // Heap-based discovery for @Observable instances (bypasses SwiftUI view tree)
        discoverFromHeap()
    }

    private func discoverFromVCTree(_ vc: UIViewController) {
        discoverFromViewController(vc)
        if let presented = vc.presentedViewController {
            discoverFromVCTree(presented)
        }
        for child in vc.children {
            discoverFromVCTree(child)
        }
    }

    // MARK: - Heap-based @Observable Discovery (BUG-003)

    /// Scan the heap for live instances of @Observable classes.
    /// Uses ObjC runtime to find classes with `_$observationRegistrar` ivar,
    /// then the C heap scanner to find live instances. Independent of SwiftUI view tree.
    func discoverFromHeap() {
        // Safe mode: skip heap scanning entirely. Set PEPPER_SAFE_MODE=1 in CI
        // or other environments where the heap scan may crash the process.
        if ProcessInfo.processInfo.environment["PEPPER_SAFE_MODE"] != nil {
            pepperLog.info("Vars: heap scan skipped (PEPPER_SAFE_MODE)", category: .bridge)
            return
        }

        // Step 1: Find all ObjC classes that have a _$observationRegistrar ivar
        let observableClasses = findObservableClasses()
        guard !observableClasses.isEmpty else { return }

        pepperLog.info("Vars: heap scan found \(observableClasses.count) @Observable class(es)", category: .bridge)

        // Step 2: Use the heap scanner to find live instances
        var targetPtrs: [UnsafeRawPointer?] = observableClasses.map { unsafeBitCast($0, to: UnsafeRawPointer.self) }

        var instancesPtr: UnsafeMutablePointer<UnsafeRawPointer?>?
        var classesPtr: UnsafeMutablePointer<UnsafeRawPointer?>?
        var count: Int32 = 0

        let result = targetPtrs.withUnsafeMutableBufferPointer { buf in
            // swiftlint:disable:next force_unwrapping
            pepper_heap_find_instances(buf.baseAddress!, Int32(buf.count), &instancesPtr, &classesPtr, &count)
        }

        guard result == 0, count > 0, let instances = instancesPtr, let classes = classesPtr else { return }
        defer {
            free(instances)
            free(classes)
        }

        // Step 3: Track each found instance (deduplicated in trackInstance)
        // Use a set to avoid tracking multiple instances of the same pointer
        var seen = Set<UnsafeRawPointer>()
        for i in 0..<Int(count) {
            guard let instancePtr = instances[i] else { continue }
            guard seen.insert(instancePtr).inserted else { continue }

            // Liveness validation: the object may have been deallocated between
            // the heap scan and now. Dereferencing a freed pointer is UB.
            // 1) malloc_size returns 0 for freed blocks
            guard malloc_size(instancePtr) >= MemoryLayout<UnsafeRawPointer>.size else { continue }
            // 2) Verify the isa pointer still matches the class the scanner found.
            //    If memory was freed and reused, the isa will differ.
            guard let expectedClassPtr = classes[i] else { continue }
            let isaPtr = instancePtr.load(as: UnsafeRawPointer.self)
            guard isaPtr == expectedClassPtr else { continue }

            // Safe to dereference — validated as a live instance of the expected class
            let obj: AnyObject = Unmanaged<AnyObject>.fromOpaque(instancePtr).takeUnretainedValue()
            trackInstance(obj, knownObservable: true)
        }
    }

    /// Find all ObjC classes that have a `_$observationRegistrar` stored property.
    /// This ivar is added by the @Observable macro (Observation framework).
    /// Only returns classes from the app's main executable — system framework
    /// @Observable classes (e.g. SwiftUI internals) are excluded to avoid crashes
    /// when Mirror touches read-only __DATA_CONST memory.
    private func findObservableClasses() -> [AnyClass] {
        let totalCount = Int(objc_getClassList(nil, 0))
        guard totalCount > 0 else { return [] }

        let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: totalCount)
        let actualCount = Int(objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), Int32(totalCount)))
        defer { buffer.deallocate() }

        // Only include classes from the app's main bundle — skip all system frameworks.
        // This avoids SwiftUI internal @Observable classes (NavigationSelectionHost,
        // ScrollEnvironmentStorage, etc.) whose fields can point to read-only memory.
        let mainBundlePath = Bundle.main.bundlePath

        var result: [AnyClass] = []
        for i in 0..<actualCount {
            let cls = buffer[i]

            // Filter to app bundle classes only
            let classBundle = Bundle(for: cls)
            guard classBundle.bundlePath.hasPrefix(mainBundlePath) else { continue }

            // Skip Pepper dylib's own classes
            let name = NSStringFromClass(cls)
            if name.hasPrefix("Pepper.") { continue }

            // Check if this class has _$observationRegistrar ivar
            if classHasObservationRegistrar(cls) {
                result.append(cls)
            }
        }
        return result
    }

    /// Check if a class (not superclasses) declares a `_$observationRegistrar` ivar.
    private func classHasObservationRegistrar(_ cls: AnyClass) -> Bool {
        var ivarCount: UInt32 = 0
        guard let ivars = class_copyIvarList(cls, &ivarCount) else { return false }
        defer { free(ivars) }

        for i in 0..<Int(ivarCount) {
            guard let cName = ivar_getName(ivars[i]) else { continue }
            if strcmp(cName, "_$observationRegistrar") == 0 {
                return true
            }
        }
        return false
    }

    /// Recursively mirror a SwiftUI view tree looking for ObservableObject refs.
    private func discoverFromSwiftUIView(_ value: Any, depth: Int) {
        guard depth < 15 else { return }

        let mirror = Mirror(reflecting: value)

        for child in mirror.children {
            let label = child.label ?? ""
            let childMirror = Mirror(reflecting: child.value)
            let typeName = String(describing: childMirror.subjectType)

            // @StateObject wraps as StateObject<T>, @ObservedObject as ObservedObject<T>
            if typeName.hasPrefix("StateObject<") || typeName.hasPrefix("ObservedObject<") ||
               typeName.hasPrefix("EnvironmentObject<") {
                // The actual object is in the storage/wrappedValue
                if let obj = extractObservableObject(from: child.value) {
                    trackInstance(obj)
                }
                continue
            }

            // @State can hold @Observable objects (Swift 5.9+ Observation framework)
            if typeName.hasPrefix("State<") {
                if let obj = extractStateValue(from: child.value), isObservableClass(obj) {
                    trackInstance(obj)
                }
                continue
            }

            // @Environment can hold @Observable objects (Swift 5.9+ Observation framework)
            // e.g. @Environment(AppState.self) var state → Environment<AppState>
            if typeName.hasPrefix("Environment<") {
                if let obj = extractEnvironmentValue(from: child.value), isObservableClass(obj) {
                    trackInstance(obj)
                }
                continue
            }

            // _EnvironmentKeyWritingModifier — the writer side of .environment(obj).
            // This is where the injected @Observable object actually lives in the
            // view modifier chain. The modifier has a `value` property.
            if typeName.contains("EnvironmentKeyWritingModifier") {
                let modMirror = Mirror(reflecting: child.value)
                for modChild in modMirror.children {
                    if (modChild.label == "value" || modChild.label == "_value"),
                       "\(modChild.value)" != "nil" {
                        let obj = modChild.value as AnyObject
                        if isObservableClass(obj) {
                            trackInstance(obj)
                        }
                    }
                }
                // Still recurse into the modifier's content
                discoverFromSwiftUIView(child.value, depth: depth + 1)
                continue
            }

            // Also check if the child itself is an ObservableObject (stored property)
            let childObj = child.value as AnyObject
            if isObservableObject(childObj) {
                trackInstance(childObj)
            }

            // Recurse into view body/content/modifier chain.
            // "storage"/"view" pierce AnyView type erasure (AnyViewStorageBase box pattern).
            // "some" handles Optional wrapping in SwiftUI types.
            // Type-based check catches AnyView/Storage containers regardless of label.
            if label == "content" || label == "body" || label == "modifier" ||
               label == "storage" || label == "view" || label == "some" ||
               label == "_tree" || label == "_root" || label.hasPrefix("_") ||
               typeName.contains("AnyView") || typeName.contains("Storage") {
                discoverFromSwiftUIView(child.value, depth: depth + 1)
            }
        }
    }

    /// Mirror a regular object for ObservableObject stored properties.
    /// Skips UIViewController subclasses whose stored properties may contain
    /// ObjC-bridged collections (Set, Array) that crash Mirror iteration.
    private func discoverFromObject(_ obj: AnyObject) {
        // Skip UIKit/AppKit classes — Mirror iteration on their stored properties
        // can crash when encountering ObjC-bridged collections (Set, Array).
        if obj is UIViewController || obj is UIView { return }
        // Skip pure NSObject subclasses that aren't SwiftUI view models
        let typeName = String(describing: type(of: obj))
        if typeName.hasPrefix("UI") || typeName.hasPrefix("NS") || typeName.hasPrefix("_") { return }

        let mirror = Mirror(reflecting: obj)
        for child in mirror.children {
            let childObj = child.value as AnyObject
            if isObservableObject(childObj) {
                trackInstance(childObj)
            }
        }
    }

    /// Check if an object is likely an ObservableObject using type name heuristics.
    /// Avoids Mirror iteration which can crash on objects with Set/Array properties
    /// that fail Objective-C→Swift bridging (swift_dynamicCastFailure in Set.Iterator).
    private func isObservableObject(_ obj: AnyObject) -> Bool {
        let typeName = String(describing: type(of: obj))
        // Skip framework types — never ObservableObject
        let skipPrefixes = ["UI", "NS", "CA", "_", "OS_", "Swift.", "Combine.",
                            "GMS", "GMSx", "WK", "MK", "AV", "CL", "CK", "CN"]
        for prefix in skipPrefixes {
            if typeName.hasPrefix(prefix) { return false }
        }
        // Known ObservableObject naming patterns
        if typeName.contains("ViewModel") || typeName.contains("Store") ||
           typeName.contains("Manager") || typeName.contains("Observable") ||
           typeName.contains("Model") || typeName.contains("State") {
            return true
        }
        // Fallback: check for @Observable (Observation framework)
        return isObservableClass(obj)
    }

    /// Check if an object uses the Observation framework (@Observable macro).
    /// Detects the _$observationRegistrar stored property added by the macro.
    private func isObservableClass(_ obj: AnyObject) -> Bool {
        let mirror = Mirror(reflecting: obj)
        return mirror.children.contains { $0.label == "_$observationRegistrar" }
    }

    /// Extract the ObservableObject from a StateObject/ObservedObject wrapper.
    private func extractObservableObject(from wrapper: Any) -> AnyObject? {
        let mirror = Mirror(reflecting: wrapper)
        // StateObject stores in _wrappedValue, _stateObject, or storage
        for child in mirror.children {
            let label = child.label ?? ""
            if label == "wrappedValue" || label == "_wrappedValue" {
                return child.value as AnyObject
            }
            if label == "_stateObject" || label == "storage" || label == "_storage" {
                // Recurse one level
                let innerMirror = Mirror(reflecting: child.value)
                for inner in innerMirror.children {
                    let innerLabel = inner.label ?? ""
                    if innerLabel == "wrappedValue" || innerLabel == "_wrappedValue" ||
                       innerLabel == "object" || innerLabel == "_object" {
                        return inner.value as AnyObject
                    }
                }
                // Try the child itself
                let childObj = child.value as AnyObject
                if isObservableObject(childObj) {
                    return childObj
                }
            }
        }
        return nil
    }

    /// Extract the value from a SwiftUI State<T> wrapper.
    private func extractStateValue(from wrapper: Any) -> AnyObject? {
        let mirror = Mirror(reflecting: wrapper)
        for child in mirror.children {
            let label = child.label ?? ""
            if label == "_value" || label == "wrappedValue" || label == "_wrappedValue" {
                return child.value as AnyObject
            }
            if label == "storage" || label == "_storage" {
                let innerMirror = Mirror(reflecting: child.value)
                for inner in innerMirror.children {
                    let innerLabel = inner.label ?? ""
                    if innerLabel == "value" || innerLabel == "_value" || innerLabel == ".0" {
                        return inner.value as AnyObject
                    }
                }
            }
        }
        return nil
    }

    /// Extract the @Observable object from a SwiftUI Environment<T> wrapper.
    /// Environment stores its value in internal storage that varies by iOS version.
    private func extractEnvironmentValue(from wrapper: Any) -> AnyObject? {
        let mirror = Mirror(reflecting: wrapper)
        for child in mirror.children {
            let label = child.label ?? ""
            // Direct value storage
            if label == "_value" || label == "wrappedValue" || label == "_wrappedValue" || label == "value" {
                let obj = child.value as AnyObject
                // Skip Optional.none — environment may not be populated yet
                if "\(child.value)" == "nil" { continue }
                return obj
            }
            // Internal storage variants
            if label == "_content" || label == "_store" || label == "content" || label == "storage" || label == "_storage" {
                let innerMirror = Mirror(reflecting: child.value)
                for inner in innerMirror.children {
                    let innerLabel = inner.label ?? ""
                    if innerLabel == "value" || innerLabel == "_value" || innerLabel == ".0" || innerLabel == "wrappedValue" {
                        if "\(inner.value)" == "nil" { continue }
                        return inner.value as AnyObject
                    }
                }
                // If the storage itself is the object (single-element enum payload)
                if innerMirror.children.isEmpty {
                    let obj = child.value as AnyObject
                    if isObservableClass(obj) { return obj }
                }
            }
        }
        // Fallback: walk all children looking for something @Observable
        for child in mirror.children {
            let obj = child.value as AnyObject
            if isObservableClass(obj) { return obj }
        }
        return nil
    }

    /// Track an instance if not already tracked.
    /// - Parameter knownObservable: If true, skip the Mirror-based `isObservableClass` check
    ///   (already verified at the C/ObjC runtime level). This avoids crashes when Mirror
    ///   touches objects with fields in read-only memory.
    private func trackInstance(_ obj: AnyObject, knownObservable: Bool = false) {
        let className = String(describing: type(of: obj))

        lock.lock()
        defer { lock.unlock() }

        // Check if already tracked (same object identity)
        let ptr = Unmanaged.passUnretained(obj).toOpaque()
        // swiftlint:disable:next force_unwrapping
        if tracked.contains(where: { $0.instance != nil && Unmanaged.passUnretained($0.instance!).toOpaque() == ptr }) {
            return
        }

        let observable = knownObservable || isObservableClass(obj)
        let props: [PropertyInfo]
        if observable {
            props = catalogObservableProperties(of: obj, className: className)
        } else {
            props = catalogProperties(of: obj, className: className)
        }
        tracked.append(TrackedInstance(className: className, instance: obj, properties: props, isObservable: observable))
        let framework = observable ? "@Observable" : "@Published"
        pepperLog.info("Vars: tracked \(className) with \(props.count) \(framework) properties", category: .bridge)
    }

    // MARK: - Property Cataloging

    /// Catalog @Published properties for an instance. Cached by class name.
    private func catalogProperties(of obj: AnyObject, className: String) -> [PropertyInfo] {
        if let cached = catalogCache[className] {
            return cached
        }

        var props: [PropertyInfo] = []
        let mirror = Mirror(reflecting: obj)

        for child in mirror.children {
            guard let label = child.label, label.hasPrefix("_") else { continue }

            let childTypeName = String(describing: Mirror(reflecting: child.value).subjectType)
            guard childTypeName.hasPrefix("Published<") else { continue }

            let propertyName = String(label.dropFirst()) // remove leading underscore
            let innerTypeName = extractGenericParam(from: childTypeName)
            let (varType, innerType) = classifyType(innerTypeName)

            // Find ivar offset for raw memory access
            let ivarOffset = findIvarOffset(named: label, in: type(of: obj))

            props.append(PropertyInfo(
                name: propertyName,
                type: varType,
                innerType: innerType,
                typeName: innerTypeName,
                ivarName: label,
                ivarOffset: ivarOffset
            ))
        }

        catalogCache[className] = props
        return props
    }

    /// Catalog properties for an @Observable instance (Observation framework).
    /// Unlike @Published, properties are stored directly with an underscore prefix.
    private func catalogObservableProperties(of obj: AnyObject, className: String) -> [PropertyInfo] {
        if let cached = catalogCache[className] {
            return cached
        }

        var props: [PropertyInfo] = []
        let mirror = Mirror(reflecting: obj)

        for child in mirror.children {
            guard let label = child.label else { continue }
            // Skip Observation framework infrastructure (_$observationRegistrar, _$id, etc.)
            if label.hasPrefix("_$") { continue }
            // @ObservationTracked properties have underscore-prefixed backing storage
            guard label.hasPrefix("_") else { continue }

            let propertyName = String(label.dropFirst())
            let childTypeName = String(describing: Mirror(reflecting: child.value).subjectType)

            // Skip if it looks like a Published wrapper (hybrid class)
            if childTypeName.hasPrefix("Published<") { continue }

            let (varType, innerType) = classifyType(childTypeName)
            let ivarOffset = findIvarOffset(named: label, in: type(of: obj))

            props.append(PropertyInfo(
                name: propertyName,
                type: varType,
                innerType: innerType,
                typeName: childTypeName,
                ivarName: label,
                ivarOffset: ivarOffset
            ))
        }

        catalogCache[className] = props
        return props
    }

    /// Extract the generic type parameter from "Published<SomeType>".
    private func extractGenericParam(from typeName: String) -> String {
        guard typeName.hasPrefix("Published<"), typeName.hasSuffix(">") else {
            return typeName
        }
        let start = typeName.index(typeName.startIndex, offsetBy: 10) // "Published<".count
        let end = typeName.index(before: typeName.endIndex)
        return String(typeName[start..<end])
    }

    /// Classify a type name string into our VarType enum.
    private func classifyType(_ typeName: String) -> (VarType, VarType?) {
        switch typeName {
        case "Int":         return (.int, nil)
        case "Double":      return (.double, nil)
        case "CGFloat":     return (.cgfloat, nil)
        case "Bool":        return (.bool, nil)
        case "String":      return (.string, nil)
        case "CGSize":      return (.cgSize, nil)
        case "EdgeInsets":  return (.edgeInsets, nil)
        case "Color":       return (.color, nil)
        default:
            if typeName.hasPrefix("Optional<") {
                let innerName = String(typeName.dropFirst(9).dropLast(1))
                let (innerType, _) = classifyType(innerName)
                return (.optional, innerType)
            }
            return (.unknown, nil)
        }
    }

    /// Find the ivar byte offset for a named property.
    private func findIvarOffset(named name: String, in cls: AnyClass) -> Int? {
        var currentClass: AnyClass? = cls
        while let c = currentClass {
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(c, &count) {
                defer { free(ivars) }
                for i in 0..<Int(count) {
                    let ivar = ivars[i]
                    guard let cName = ivar_getName(ivar) else { continue }
                    let ivarName = String(cString: cName)
                    if ivarName == name || ivarName == "_\(name)" {
                        return ivar_getOffset(ivar)
                    }
                }
            }
            currentClass = class_getSuperclass(c)
        }
        return nil
    }

    // MARK: - Read

    /// List all tracked instances and their properties.
    func listAll() -> [[String: AnyCodable]] {
        lock.lock()
        tracked.removeAll { $0.instance == nil }
        let snapshot = tracked
        lock.unlock()

        return snapshot.compactMap { entry -> [String: AnyCodable]? in
            guard entry.instance != nil else { return nil }
            return [
                "class": AnyCodable(entry.className),
                "properties": AnyCodable(entry.properties.map { prop -> [String: AnyCodable] in
                    var info: [String: AnyCodable] = [
                        "name": AnyCodable(prop.name),
                        "type": AnyCodable(prop.typeName),
                        "writable": AnyCodable(prop.type != .unknown)
                    ]
                    if let value = readValue(className: entry.className, propertyName: prop.name) {
                        info["value"] = value
                    }
                    return info
                })
            ]
        }
    }

    /// Get a specific property value by "ClassName.propertyName" path.
    func getValue(path: String) -> AnyCodable? {
        let parts = path.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return readValue(className: String(parts[0]), propertyName: String(parts[1]))
    }

    /// Mirror ALL properties of a tracked instance (not just @Published).
    /// Uses Swift Mirror to enumerate every stored property, marking which are @Published (writable).
    func mirrorAll(_ className: String) -> [[String: AnyCodable]]? {
        lock.lock()
        tracked.removeAll { $0.instance == nil }
        let entry = tracked.first { $0.className == className && $0.instance != nil }
        lock.unlock()

        guard let entry = entry, let instance = entry.instance else { return nil }

        let publishedNames = Set(entry.properties.map { $0.name })
        let mirror = Mirror(reflecting: instance)
        var result: [[String: AnyCodable]] = []

        // Walk the full mirror chain (including superclasses)
        var currentMirror: Mirror? = mirror
        while let m = currentMirror {
            for child in m.children {
                guard let label = child.label else { continue }

                // Strip leading underscore (Swift stores @Published as _propName)
                let name: String
                let childTypeName = String(describing: Mirror(reflecting: child.value).subjectType)

                if label.hasPrefix("_") && childTypeName.hasPrefix("Published<") {
                    name = String(label.dropFirst())
                } else if label.hasPrefix("_") {
                    // Could be a property wrapper backing store — show clean name
                    name = String(label.dropFirst())
                } else {
                    name = label
                }

                let isPublished = publishedNames.contains(name)

                // Serialize the value
                let valueStr: String
                if isPublished {
                    // Use the Published extraction path for accurate values
                    if let val = readValue(className: className, propertyName: name) {
                        valueStr = describeAnyCodable(val)
                    } else {
                        valueStr = String(describing: child.value)
                    }
                } else {
                    valueStr = describeValue(child.value)
                }

                let info: [String: AnyCodable] = [
                    "name": AnyCodable(name),
                    "type": AnyCodable(childTypeName),
                    "value": AnyCodable(valueStr),
                    "published": AnyCodable(isPublished),
                    "writable": AnyCodable(isPublished),
                ]

                result.append(info)
            }
            currentMirror = m.superclassMirror
        }

        return result
    }

    /// Describe a value for mirror output — handles optionals, collections, etc.
    private func describeValue(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)

        // Unwrap optionals
        if mirror.displayStyle == .optional {
            if let first = mirror.children.first {
                return describeValue(first.value)
            }
            return "nil"
        }

        // Short description for known simple types
        if value is String || value is Int || value is Double || value is Bool || value is CGFloat {
            return String(describing: value)
        }

        // Collections — show count + first few items
        if mirror.displayStyle == .collection || mirror.displayStyle == .set {
            let items = mirror.children.prefix(3).map { describeValue($0.value) }
            let suffix = mirror.children.count > 3 ? ", ... (\(mirror.children.count) total)" : ""
            return "[\(items.joined(separator: ", "))\(suffix)]"
        }

        // Dictionaries
        if mirror.displayStyle == .dictionary {
            return "[\(mirror.children.count) entries]"
        }

        return String(describing: value)
    }

    /// Describe an AnyCodable value as a string.
    private func describeAnyCodable(_ value: AnyCodable) -> String {
        if let s = value.stringValue { return s }
        if let i = value.intValue { return String(i) }
        if let d = value.doubleValue { return String(d) }
        if let b = value.boolValue { return String(b) }
        return String(describing: value.value)
    }

    /// Dump all properties of a specific class.
    func dumpClass(_ className: String) -> [String: AnyCodable]? {
        lock.lock()
        tracked.removeAll { $0.instance == nil }
        let entry = tracked.first { $0.className == className && $0.instance != nil }
        lock.unlock()

        guard let entry = entry, entry.instance != nil else { return nil }

        var result: [String: AnyCodable] = [:]
        for prop in entry.properties {
            if let value = readValue(className: className, propertyName: prop.name) {
                result[prop.name] = value
            }
        }
        return result
    }

    /// Read a single property value.
    private func readValue(className: String, propertyName: String) -> AnyCodable? {
        lock.lock()
        let entry = tracked.first { $0.className == className && $0.instance != nil }
        lock.unlock()

        guard let entry = entry, let instance = entry.instance else { return nil }
        guard let prop = entry.properties.first(where: { $0.name == propertyName }) else { return nil }

        let mirror = Mirror(reflecting: instance)
        guard let child = mirror.children.first(where: { $0.label == prop.ivarName }) else {
            return nil
        }

        if entry.isObservable {
            // @Observable: value is stored directly, no Published<T> unwrap needed
            return serializeValue(child.value, type: prop.type, innerType: prop.innerType)
        } else {
            // ObservableObject + @Published: unwrap Published<T> storage
            let value = extractPublishedValue(child.value)
            return serializeValue(value, type: prop.type, innerType: prop.innerType)
        }
    }

    /// Extract the wrapped value from a Published<T> instance.
    /// Published<T> has two internal storage states:
    ///   - .value(T) — before any subscriber attaches
    ///   - .publisher(CurrentValueSubject<T, Never>) — after first subscription
    private func extractPublishedValue(_ published: Any) -> Any? {
        let mirror = Mirror(reflecting: published)

        // Try direct "storage" child (Published internal layout)
        for child in mirror.children {
            let label = child.label ?? ""
            if label == "storage" || label == "_storage" {
                let storageMirror = Mirror(reflecting: child.value)
                // Enum case: check children
                for storageChild in storageMirror.children {
                    let sLabel = storageChild.label ?? ""
                    if sLabel == "value" || sLabel == ".0" {
                        // .value(T) case — the T is directly here
                        return storageChild.value
                    }
                    if sLabel == "publisher" || sLabel == ".0" {
                        // .publisher case — it's a CurrentValueSubject, get its value
                        let pubMirror = Mirror(reflecting: storageChild.value)
                        for pubChild in pubMirror.children {
                            let pLabel = pubChild.label ?? ""
                            if pLabel == "value" || pLabel == "_value" || pLabel == "currentValue" {
                                return pubChild.value
                            }
                        }
                        // Try KVC on the subject
                        let subject = storageChild.value as AnyObject
                        if subject.responds(to: NSSelectorFromString("value")) {
                            return subject.value(forKey: "value")
                        }
                    }
                }
                // If storage itself contains the value directly
                return child.value
            }
        }

        // Fallback: try to find value directly in mirror children
        for child in mirror.children {
            if child.label == "value" || child.label == "wrappedValue" {
                return child.value
            }
        }

        // Last resort: the first child might be the storage enum
        if let first = mirror.children.first {
            return extractValueFromEnum(first.value)
        }

        return nil
    }

    /// Try to extract value from a Swift enum storage.
    private func extractValueFromEnum(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        if let first = mirror.children.first {
            // Enum associated values appear as .0, .1, etc.
            return first.value
        }
        return value
    }

    /// Serialize a value to AnyCodable based on its classified type.
    // swiftlint:disable:next cyclomatic_complexity
    private func serializeValue(_ value: Any?, type: VarType, innerType: VarType?) -> AnyCodable? {
        guard let value = value else { return AnyCodable(NSNull()) }

        // Handle optionals: unwrap the Optional<T>
        if type == .optional {
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                if let first = mirror.children.first {
                    return serializeValue(first.value, type: innerType ?? .unknown, innerType: nil)
                } else {
                    return AnyCodable(NSNull()) // nil
                }
            }
            // Not actually Optional — serialize with inner type
            return serializeValue(value, type: innerType ?? .unknown, innerType: nil)
        }

        switch type {
        case .int:
            if let v = value as? Int { return AnyCodable(v) }
        case .double:
            if let v = value as? Double { return AnyCodable(v) }
        case .cgfloat:
            if let v = value as? CGFloat { return AnyCodable(Double(v)) }
        case .bool:
            if let v = value as? Bool { return AnyCodable(v) }
        case .string:
            if let v = value as? String { return AnyCodable(v) }
        case .cgSize:
            if let v = value as? CGSize {
                return AnyCodable(["width": AnyCodable(Double(v.width)),
                                   "height": AnyCodable(Double(v.height))])
            }
        case .edgeInsets:
            if let v = value as? UIEdgeInsets {
                return AnyCodable(["top": AnyCodable(Double(v.top)),
                                   "leading": AnyCodable(Double(v.left)),
                                   "bottom": AnyCodable(Double(v.bottom)),
                                   "trailing": AnyCodable(Double(v.right))])
            }
        case .color:
            // Color → hex string
            return AnyCodable(String(describing: value))
        case .optional:
            break // handled above
        case .unknown:
            return AnyCodable(String(describing: value))
        }

        // Fallback: string description
        return AnyCodable(String(describing: value))
    }

    // MARK: - Write

    /// Set a property value. Returns the new value after write, or nil on failure.
    func setValue(path: String, jsonValue: AnyCodable) -> (AnyCodable?, String?) {
        let parts = path.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else {
            return (nil, "Invalid path format. Use 'ClassName.propertyName'.")
        }

        let className = String(parts[0])
        let propertyName = String(parts[1])

        lock.lock()
        tracked.removeAll { $0.instance == nil }
        let entry = tracked.first { $0.className == className && $0.instance != nil }
        lock.unlock()

        guard let entry = entry, let instance = entry.instance else {
            return (nil, "No tracked instance of '\(className)'.")
        }
        guard let prop = entry.properties.first(where: { $0.name == propertyName }) else {
            return (nil, "Property '\(propertyName)' not found on '\(className)'.")
        }

        let effectiveType = prop.type == .optional ? (prop.innerType ?? .unknown) : prop.type
        guard effectiveType != .unknown else {
            return (nil, "Property '\(propertyName)' has unsupported type '\(prop.typeName)' and is read-only.")
        }

        // Convert JSON value to the correct Swift type
        guard let swiftValue = deserializeValue(jsonValue, type: prop.type, innerType: prop.innerType) else {
            return (nil, "Could not convert value to type '\(prop.typeName)'.")
        }

        // Attempt write
        let writeError = performWrite(instance: instance, prop: prop, value: swiftValue)
        if let writeError = writeError {
            return (nil, writeError)
        }

        // Fire objectWillChange to trigger SwiftUI re-render
        fireObjectWillChange(instance)

        // Read back the value
        let newValue = readValue(className: className, propertyName: propertyName)
        return (newValue, nil)
    }

    /// Convert a JSON AnyCodable to the target Swift type.
    private func deserializeValue(_ json: AnyCodable, type: VarType, innerType: VarType?) -> Any? {
        // Handle null for optionals
        if type == .optional {
            if json.isNull {
                return NSNull() // will be written as nil
            }
            return deserializeValue(json, type: innerType ?? .unknown, innerType: nil)
        }

        switch type {
        case .int:
            return json.intValue
        case .double:
            return json.doubleValue
        case .cgfloat:
            if let v = json.doubleValue { return CGFloat(v) }
            return nil
        case .bool:
            return json.boolValue
        case .string:
            return json.stringValue
        case .cgSize:
            if let dict = json.dictValue,
               let w = dict["width"]?.doubleValue,
               let h = dict["height"]?.doubleValue {
                return CGSize(width: w, height: h)
            }
            return nil
        case .edgeInsets:
            if let dict = json.dictValue,
               let top = dict["top"]?.doubleValue,
               let leading = dict["leading"]?.doubleValue,
               let bottom = dict["bottom"]?.doubleValue,
               let trailing = dict["trailing"]?.doubleValue {
                return UIEdgeInsets(top: top, left: leading, bottom: bottom, right: trailing)
            }
            return nil
        case .color:
            // Accept hex string — return as-is, actual Color conversion is complex
            return json.stringValue
        case .optional:
            return nil // handled above
        case .unknown:
            return nil
        }
    }

    /// Perform the actual write to the Published property.
    private func performWrite(instance: AnyObject, prop: PropertyInfo, value: Any) -> String? {
        // Handle nil for optionals
        let isSettingNil = value is NSNull

        // Strategy 1: KVC (works for NSObject subclasses)
        if let nsObj = instance as? NSObject {
            // KVC setValue can throw ObjC exceptions that Swift can't catch.
            // Use a simple test first.
            if nsObj.responds(to: NSSelectorFromString(prop.name)) ||
               nsObj.responds(to: NSSelectorFromString("set\(prop.name.prefix(1).uppercased())\(prop.name.dropFirst()):")) {
                if isSettingNil {
                    nsObj.setValue(nil, forKey: prop.name)
                } else {
                    nsObj.setValue(value, forKey: prop.name)
                }
                return nil // success
            }
        }

        // Strategy 2: Mirror into Published<T> storage → find CurrentValueSubject → set value
        let instanceMirror = Mirror(reflecting: instance)
        if let publishedChild = instanceMirror.children.first(where: { $0.label == prop.ivarName }) {
            if let error = writeViaPublishedStorage(published: publishedChild.value, value: value, isNil: isSettingNil) {
                // Strategy 3 failed too — fall through to raw memory
                _ = error
            } else {
                return nil // success
            }
        }

        // Strategy 3: Raw memory write via ivar offset
        if let offset = prop.ivarOffset, !isSettingNil {
            let ptr = Unmanaged.passUnretained(instance).toOpaque()
            return writeRawMemory(ptr: ptr, offset: offset, value: value, type: prop.type, innerType: prop.innerType)
        }

        return "All write strategies failed for '\(prop.name)'."
    }

    /// Write value into Published<T>'s internal CurrentValueSubject.
    private func writeViaPublishedStorage(published: Any, value: Any, isNil: Bool) -> String? {
        let mirror = Mirror(reflecting: published)

        for child in mirror.children {
            let label = child.label ?? ""
            if label == "storage" || label == "_storage" {
                let storageMirror = Mirror(reflecting: child.value)
                for storageChild in storageMirror.children {
                    // .publisher(CurrentValueSubject) case
                    let subject = storageChild.value as AnyObject
                    if subject.responds(to: NSSelectorFromString("value")) {
                        if isNil {
                            subject.setValue(nil, forKey: "value")
                        } else {
                            subject.setValue(value, forKey: "value")
                        }
                        return nil // success
                    }
                }
            }
        }

        return "Could not find CurrentValueSubject in Published storage."
    }

    /// Write to raw memory at the ivar offset. Unsafe but works for pure Swift classes.
    private func writeRawMemory(ptr: UnsafeMutableRawPointer, offset: Int, value: Any,
                                type: VarType, innerType: VarType?) -> String? {
        let effectiveType = type == .optional ? (innerType ?? .unknown) : type

        switch effectiveType {
        case .int:
            guard let v = value as? Int else { return "Type mismatch: expected Int" }
            ptr.storeBytes(of: v, toByteOffset: offset, as: Int.self)
        case .double:
            guard let v = value as? Double else { return "Type mismatch: expected Double" }
            ptr.storeBytes(of: v, toByteOffset: offset, as: Double.self)
        case .cgfloat:
            guard let v = value as? CGFloat else { return "Type mismatch: expected CGFloat" }
            ptr.storeBytes(of: v, toByteOffset: offset, as: CGFloat.self)
        case .bool:
            guard let v = value as? Bool else { return "Type mismatch: expected Bool" }
            ptr.storeBytes(of: v, toByteOffset: offset, as: Bool.self)
        default:
            return "Raw memory write not supported for type '\(effectiveType.rawValue)'"
        }

        return nil // success
    }

    /// Fire objectWillChange.send() on the instance to trigger SwiftUI re-render.
    private func fireObjectWillChange(_ instance: AnyObject) {
        // Try via protocol conformance
        let mirror = Mirror(reflecting: instance)
        for child in mirror.children {
            let label = child.label ?? ""
            if label == "objectWillChange" || label == "_objectWillChange" {
                // It's a Publisher — try to call send() via performSelector
                let publisher = child.value as AnyObject
                if publisher.responds(to: NSSelectorFromString("send")) {
                    _ = publisher.perform(NSSelectorFromString("send"))
                    return
                }
                // Might be lazy — access wrappedValue first
                let pubMirror = Mirror(reflecting: child.value)
                for pubChild in pubMirror.children {
                    let inner = pubChild.value as AnyObject
                    if inner.responds(to: NSSelectorFromString("send")) {
                        _ = inner.perform(NSSelectorFromString("send"))
                        return
                    }
                }
            }
        }

        // Fallback: post a generic notification that SwiftUI might pick up
        // This is a last resort — performSelector on objectWillChange should work in most cases
        pepperLog.debug("Vars: could not fire objectWillChange on \(type(of: instance))", category: .bridge)
    }
}
