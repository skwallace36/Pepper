import Foundation
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

/// Heap-based @Observable discovery — scans the ObjC heap for live instances
/// of classes annotated with the @Observable macro (Observation framework).
extension PepperVarRegistry {

    // MARK: - Heap-based @Observable Discovery (BUG-003)

    /// Scan the heap for live instances of @Observable classes.
    /// Uses ObjC runtime to find classes with `_$observationRegistrar` ivar,
    /// Run heap scan lazily on first vars_inspect call, not at boot.
    /// The scan blocks the main thread for 30+ seconds on complex SwiftUI apps.
    func discoverFromHeapIfNeeded() {
        guard !didInitialHeapScan else { return }
        didInitialHeapScan = true
        discoverFromHeap()
    }

    /// Scan the ObjC heap for @Observable instances. Uses class introspection first,
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
            let cls: AnyClass = buffer[i]

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
}
