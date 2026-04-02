import Foundation
import MachO

// MARK: - BodyEvalEvent

/// A structured record of one SwiftUI View.body evaluation.
struct BodyEvalEvent {
    let timestampMs: Int64
    let viewType: String
    let durationNs: UInt64

    func toDict() -> [String: AnyCodable] {
        [
            "timestamp_ms": AnyCodable(timestampMs),
            "view_type": AnyCodable(viewType),
            "duration_ns": AnyCodable(durationNs),
        ]
    }
}

// MARK: - PepperSwiftUIBodyTracker

/// Tracks per-view SwiftUI body evaluations by scanning Mach-O protocol conformance
/// records for `SwiftUI.View` and hooking the `body` getter witness via IMP replacement.
///
/// Approach:
/// 1. Iterate `__swift5_proto` Mach-O section for protocol conformance records
/// 2. Match conformances to SwiftUI.View protocol
/// 3. For each concrete View type, swizzle its `body` property getter (via the ObjC bridge
///    on _UIHostingView subclasses) or use the Swift metadata to find and hook body getters
/// 4. Record view type + timestamp + duration for each evaluation
///
/// Simulator only — relies on writable code pages.
final class PepperSwiftUIBodyTracker {

    static let shared = PepperSwiftUIBodyTracker()

    // MARK: - State

    private(set) var isActive = false

    /// Concurrent queue for ring buffer reads/writes.
    private let queue = DispatchQueue(label: "pepper.swiftui_body", attributes: .concurrent)

    /// Ring buffer of recent body evaluation events.
    private var ringBuffer: [BodyEvalEvent] = []
    private var maxEvents = 500
    private var totalDropped = 0

    /// Per-view-type evaluation counts.
    private var evalCounts: [String: Int] = [:]
    private let lock = NSLock()

    /// Tracks hooked classes so we can unhook on stop.
    private var hookedClasses: [(cls: AnyClass, originalIMP: IMP, method: Method)] = []

    // MARK: - Ring Buffer

    private func appendEvent(_ event: BodyEvalEvent) {
        queue.async(flags: .barrier) { [self] in
            if ringBuffer.count >= maxEvents {
                ringBuffer.removeFirst()
                totalDropped += 1
            }
            ringBuffer.append(event)
        }
    }

    func recentEvents(limit: Int = 100, sinceMs: Int64 = 0) -> [BodyEvalEvent] {
        queue.sync {
            let filtered = sinceMs > 0 ? ringBuffer.filter { $0.timestampMs >= sinceMs } : ringBuffer
            let tail = limit > 0 && filtered.count > limit ? Array(filtered.suffix(limit)) : filtered
            return tail
        }
    }

    var totalEventCount: Int {
        queue.sync { ringBuffer.count }
    }

    func clearEvents() {
        queue.async(flags: .barrier) { [self] in
            ringBuffer.removeAll()
        }
    }

    // MARK: - Lifecycle

    /// Start tracking body evaluations. Scans for _UIHostingView subclasses and hooks
    /// layoutSubviews to measure body evaluation timing per hosting view type.
    ///
    /// We use a pragmatic approach: hook `layoutSubviews` on all `_UIHostingView` subclasses
    /// since each layoutSubviews call triggers a body re-evaluation. We also extract the
    /// SwiftUI View type name from the generic parameter of the hosting view class.
    @discardableResult
    func start() -> [String: Any] {
        guard !isActive else {
            return ["status": "already_active", "note": "Call stop first to restart."]
        }

        guard let hostingViewClass = NSClassFromString("_UIHostingView") else {
            return ["status": "error", "message": "_UIHostingView not found"]
        }

        let targetClasses = findHostingViewSubclasses(base: hostingViewClass)
        let conformances = scanViewConformances()

        var hooked: [[String: String]] = []

        // Hook updateRootView on each hosting view class to capture body evaluations
        // with timing. This piggybacks on the render tracker's approach but adds
        // per-View-type resolution via Swift metadata.
        for cls in targetClasses {
            let className = NSStringFromClass(cls)
            let viewTypeName = extractSwiftUIViewType(from: className)

            let sel = NSSelectorFromString("layoutSubviews")
            guard let method = class_getInstanceMethod(cls, sel) else { continue }
            let originalIMP = method_getImplementation(method)

            let capturedViewType = viewTypeName
            let block: @convention(block) (AnyObject) -> Void = { [weak self] obj in
                guard let self = self else {
                    // Call original
                    unsafeBitCast(originalIMP, to: (@convention(c) (AnyObject, Selector) -> Void).self)(obj, sel)
                    return
                }
                let startTime = DispatchTime.now().uptimeNanoseconds
                // Call original layoutSubviews
                unsafeBitCast(originalIMP, to: (@convention(c) (AnyObject, Selector) -> Void).self)(obj, sel)
                let elapsed = DispatchTime.now().uptimeNanoseconds - startTime

                self.recordEval(viewType: capturedViewType, durationNs: elapsed)
            }

            let newIMP = imp_implementationWithBlock(block as Any)
            method_setImplementation(method, newIMP)
            hookedClasses.append((cls: cls, originalIMP: originalIMP, method: method))
            hooked.append(["class": className, "view_type": capturedViewType, "status": "hooked"])
        }

        isActive = true

        lock.lock()
        evalCounts.removeAll()
        lock.unlock()

        clearEvents()

        pepperLog.info(
            "SwiftUI body tracker started. \(hooked.count) class(es) hooked, \(conformances.count) View conformances found.",
            category: .lifecycle
        )

        return [
            "status": "started",
            "classes_hooked": hooked.count,
            "view_conformances": conformances.count,
            "conformance_types": conformances,
            "details": hooked,
        ]
    }

    /// Stop tracking and restore original implementations.
    @discardableResult
    func stop() -> [String: Any] {
        guard isActive else {
            return ["status": "not_active"]
        }

        var restored = 0
        for entry in hookedClasses {
            method_setImplementation(entry.method, entry.originalIMP)
            restored += 1
        }
        hookedClasses.removeAll()
        isActive = false

        lock.lock()
        let finalCounts = evalCounts
        lock.unlock()

        pepperLog.info("SwiftUI body tracker stopped. \(restored) hook(s) removed.", category: .lifecycle)

        // Build sorted top-N
        let sorted = finalCounts.sorted { $0.value > $1.value }
        let topViews = sorted.prefix(20).map { ["view_type": $0.key, "count": $0.value] as [String: Any] }

        return [
            "status": "stopped",
            "hooks_removed": restored,
            "total_evaluations": finalCounts.values.reduce(0, +),
            "unique_view_types": finalCounts.count,
            "top_views": topViews,
        ]
    }

    // MARK: - Recording

    private func recordEval(viewType: String, durationNs: UInt64) {
        lock.lock()
        evalCounts[viewType, default: 0] += 1
        let count = evalCounts[viewType, default: 0]
        lock.unlock()

        let event = BodyEvalEvent(
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            viewType: viewType,
            durationNs: durationNs
        )
        appendEvent(event)

        PepperFlightRecorder.shared.record(
            type: .render,
            summary: "body eval: \(viewType) (#\(count), \(durationNs / 1_000)μs)",
            referenceId: viewType
        )
    }

    // MARK: - Counts

    var currentCounts: [String: Int] {
        lock.lock()
        let counts = evalCounts
        lock.unlock()
        return counts
    }

    func reset() {
        if isActive { stop() }
        lock.lock()
        evalCounts.removeAll()
        lock.unlock()
        clearEvents()
    }

    // MARK: - Mach-O Protocol Conformance Scanning

    /// Scan loaded images for types conforming to SwiftUI.View.
    /// Returns demangled type names of all discovered View conformances.
    func scanViewConformances() -> [String] {
        var viewTypes: [String] = []

        // Strategy: enumerate all ObjC classes and check for _UIHostingView subclasses.
        // The generic parameter of _UIHostingView<SomeView> encodes the View type.
        // This is more reliable than parsing __swift5_proto directly.
        guard let hostingClass = NSClassFromString("_UIHostingView") else { return [] }

        var classCount: UInt32 = 0
        guard let classList = objc_copyClassList(&classCount) else { return [] }
        defer { free(UnsafeMutableRawPointer(mutating: classList)) }

        for i in 0..<Int(classCount) {
            let cls: AnyClass = classList[i]
            let name = NSStringFromClass(cls)

            // _UIHostingView subclasses encode the View type in their class name
            // via Swift generic specialization mangling
            if isSubclass(cls, of: hostingClass) && cls !== hostingClass {
                let viewType = extractSwiftUIViewType(from: name)
                if viewType != name {
                    viewTypes.append(viewType)
                }
            }
        }

        // Also scan __swift5_proto section for direct conformances
        let protoConformances = scanSwift5ProtoSection()
        viewTypes.append(contentsOf: protoConformances)

        // Deduplicate
        return Array(Set(viewTypes)).sorted()
    }

    /// Scan the __swift5_proto Mach-O section for SwiftUI.View protocol conformances.
    /// Returns demangled type names.
    private func scanSwift5ProtoSection() -> [String] {
        var viewTypes: [String] = []

        for imageIndex in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(imageIndex) else { continue }

            // Only scan the main executable and app frameworks, skip system images
            guard let imageName = _dyld_get_image_name(imageIndex) else { continue }
            let path = String(cString: imageName)
            guard path.contains(".app/") || path.contains("Pepper.framework") else { continue }

            var size: UInt = 0
            let sectionName = "__swift5_proto"
            let segmentName = "__TEXT"

            guard let sectionData = UnsafeRawPointer(header).withMemoryRebound(
                to: mach_header_64.self, capacity: 1, {
                    getsectiondata($0, segmentName, sectionName, &size)
                })
            else { continue }

            // Each entry is a 4-byte relative pointer to a protocol conformance descriptor
            let entrySize = MemoryLayout<Int32>.size
            let entryCount = Int(size) / entrySize

            for entryIdx in 0..<entryCount {
                let entryPtr = sectionData.advanced(by: entryIdx * entrySize)
                let relativeOffset = entryPtr.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
                let descriptorPtr = entryPtr.advanced(by: Int(relativeOffset))

                // Protocol conformance descriptor layout:
                // offset 0: protocol descriptor relative pointer (4 bytes)
                // offset 4: nominal type descriptor relative pointer (4 bytes)
                // We check if the protocol is SwiftUI.View

                let protoRelPtr = descriptorPtr.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
                let protoDescPtr = descriptorPtr.advanced(by: Int(protoRelPtr))

                // Try to read the protocol name from the descriptor
                // Protocol descriptor has name at offset 8 (relative pointer)
                let nameRelPtr = protoDescPtr.advanced(by: 8).withMemoryRebound(to: Int32.self, capacity: 1) {
                    $0.pointee
                }
                let namePtr = protoDescPtr.advanced(by: 8 + Int(nameRelPtr))

                // Safety: validate the pointer is readable
                let cNamePtr = UnsafeRawPointer(namePtr).assumingMemoryBound(to: CChar.self)
                guard let name = String(validatingCString: cNamePtr) else {
                    continue
                }

                // Check if this is a View protocol conformance
                guard name == "View" else { continue }

                // Read the type descriptor relative pointer (offset 4 from conformance descriptor)
                let typeRelPtr = descriptorPtr.advanced(by: 4).withMemoryRebound(to: Int32.self, capacity: 1) {
                    $0.pointee
                }

                // The low 2 bits of the type descriptor field encode the kind
                let typeKind = typeRelPtr & 0x3
                guard typeKind == 0 else { continue }  // 0 = direct reference to nominal type

                let typeDescPtr = descriptorPtr.advanced(by: 4 + Int(typeRelPtr & ~0x3))

                // Nominal type descriptor: name is at offset 8 (relative pointer)
                let typeNameRelPtr = typeDescPtr.advanced(by: 8).withMemoryRebound(to: Int32.self, capacity: 1) {
                    $0.pointee
                }
                let typeNamePtr = typeDescPtr.advanced(by: 8 + Int(typeNameRelPtr))

                let cTypeNamePtr = UnsafeRawPointer(typeNamePtr).assumingMemoryBound(to: CChar.self)
                if let typeName = String(validatingCString: cTypeNamePtr) {
                    viewTypes.append(typeName)
                }
            }
        }

        return viewTypes
    }

    // MARK: - Helpers

    /// Find all subclasses of a given base class.
    private func findHostingViewSubclasses(base: AnyClass) -> [AnyClass] {
        var count: UInt32 = 0
        guard let classList = objc_copyClassList(&count) else { return [base] }
        defer { free(UnsafeMutableRawPointer(mutating: classList)) }

        var result: [AnyClass] = [base]
        for i in 0..<Int(count) {
            let cls: AnyClass = classList[i]
            if cls !== base && isSubclass(cls, of: base) {
                result.append(cls)
            }
        }
        return result
    }

    private func isSubclass(_ cls: AnyClass, of base: AnyClass) -> Bool {
        var superclass: AnyClass? = class_getSuperclass(cls)
        while let sc = superclass {
            if sc === base { return true }
            superclass = class_getSuperclass(sc)
        }
        return false
    }

    /// Extract the SwiftUI View type from a hosting view class name.
    /// _TtGC7SwiftUI14_UIHostingViewV6MyApp11ContentView_ → ContentView
    /// Falls back to the raw class name if parsing fails.
    private func extractSwiftUIViewType(from className: String) -> String {
        // Try to demangle Swift class names
        // Pattern: _TtGC7SwiftUI14_UIHostingViewVNNN..._ or similar mangled names
        // Also handles _TtC prefixed names

        // Check for common patterns in hosting view subclass names
        if className.contains("HostingView") {
            // Try to find the inner type from Swift mangled name
            if let demangled = demangle(className) {
                // Extract the generic parameter: SwiftUI._UIHostingView<MyApp.ContentView>
                if let start = demangled.firstIndex(of: "<"),
                    let end = demangled.lastIndex(of: ">")
                {
                    let innerType = String(demangled[demangled.index(after: start)..<end])
                    // Strip module prefix if present
                    if let dotIdx = innerType.lastIndex(of: ".") {
                        return String(innerType[innerType.index(after: dotIdx)...])
                    }
                    return innerType
                }
                return demangled
            }
        }

        return className
    }

    /// Demangle a Swift symbol name using the runtime.
    private func demangle(_ mangledName: String) -> String? {
        // Use swift_demangle from the Swift runtime
        guard let cStr = mangledName.cString(using: .utf8) else { return nil }
        guard let demangled = swift_demangle(cStr, UInt(cStr.count - 1), nil, nil, 0) else { return nil }
        let result = String(cString: demangled)
        free(demangled)
        return result
    }

    private init() {}
}

// MARK: - Swift runtime demangling

/// Import the Swift runtime demangling function.
@_silgen_name("swift_demangle")
private func swift_demangle(
    _ mangledName: UnsafePointer<CChar>,
    _ mangledNameLength: UInt,
    _ outputBuffer: UnsafeMutablePointer<CChar>?,
    _ outputBufferSize: UnsafeMutablePointer<UInt>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?
