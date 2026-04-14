import Foundation
import MachO

// MARK: - Mach Time Helpers

private let _timebaseInfo: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

@inline(__always)
private func machTicksToNs(_ ticks: UInt64) -> UInt64 {
    // On Apple Silicon numer==denom==1, compiles to a no-op.
    ticks &* UInt64(_timebaseInfo.numer) / UInt64(_timebaseInfo.denom)
}

@inline(__always)
private func machTicksToMs(_ ticks: UInt64) -> Int64 {
    Int64(machTicksToNs(ticks) / 1_000_000)
}

// MARK: - BodyEvalEvent

/// A structured record of one SwiftUI View.body evaluation.
/// Public interface is unchanged; internally materialized from compact ring buffer entries.
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

// MARK: - Compact Ring Buffer Entry (no ARC, 24 bytes)

/// Internal storage format — uses a UInt16 type index instead of a String
/// to eliminate ARC retain/release traffic on every body evaluation.
private struct CompactEvalEvent {
    var timestamp: UInt64 = 0  // mach_absolute_time ticks
    var durationNs: UInt64 = 0
    var viewTypeIdx: UInt16 = 0
    var _pad: UInt16 = 0
    var _pad2: UInt32 = 0
}

// MARK: - Per-Type Running Stats

/// Accumulated inline during recording — avoids recomputing from the ring buffer.
private struct ViewTypeStats {
    var count: Int = 0
    var totalNs: UInt64 = 0
    var maxNs: UInt64 = 0
}

// MARK: - PepperSwiftUIBodyTracker

/// Tracks per-view SwiftUI body evaluations by scanning Mach-O protocol conformance
/// records for `SwiftUI.View` and hooking `layoutSubviews` on `_UIHostingView` subclasses.
///
/// Optimizations over the original implementation:
/// - `os_unfair_lock` instead of NSLock + DispatchQueue (~4x faster lock)
/// - Fixed-capacity power-of-2 ring buffer with bitmask (no array growth/realloc)
/// - UInt16 type index per event instead of String (zero ARC on hot path)
/// - `mach_absolute_time()` instead of `DispatchTime.now().uptimeNanoseconds` (no timebase conversion in hook)
/// - Per-type stats accumulated inline during recording (no post-hoc aggregation)
/// - C-level `strstr` for image path filtering (no Swift String allocation per dyld image)
/// - Direct byte comparison for "View" protocol name (no String allocation for non-matches)
///
/// Simulator only — relies on writable code pages.
final class PepperSwiftUIBodyTracker {

    static let shared = PepperSwiftUIBodyTracker()

    // MARK: - State

    private(set) var isActive = false

    // --- Type table: built at hook time, immutable while active ---
    private var viewTypeNames: [String] = []
    private var viewTypeIndex: [String: UInt16] = [:]

    // --- Ring buffer: fixed capacity, O(1) writes via bitmask ---
    private let ringCapacity = 2048  // power of 2
    private var ring: UnsafeMutableBufferPointer<CompactEvalEvent>?
    private var ringWritePos: Int = 0  // monotonic counter
    private var ringReady = false

    // --- Per-type running stats: array indexed by viewTypeIdx ---
    private var typeStats: UnsafeMutableBufferPointer<ViewTypeStats>?

    // --- Lock: os_unfair_lock is ~4x faster than NSLock, no ObjC dispatch ---
    private var _lock = os_unfair_lock()
    @inline(__always) private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return body()
    }

    /// Tracks hooked classes so we can unhook on stop.
    private var hookedClasses: [(cls: AnyClass, originalIMP: IMP, method: Method)] = []

    // MARK: - Ring Buffer Management

    private func ensureRing() {
        guard !ringReady else { return }
        let ptr = UnsafeMutablePointer<CompactEvalEvent>.allocate(capacity: ringCapacity)
        ptr.initialize(repeating: CompactEvalEvent(), count: ringCapacity)
        ring = UnsafeMutableBufferPointer(start: ptr, count: ringCapacity)
        ringReady = true
    }

    private func allocateTypeStats(count: Int) {
        if let existing = typeStats {
            existing.baseAddress?.deinitialize(count: existing.count)
            existing.baseAddress?.deallocate()
        }
        let ptr = UnsafeMutablePointer<ViewTypeStats>.allocate(capacity: count)
        ptr.initialize(repeating: ViewTypeStats(), count: count)
        typeStats = UnsafeMutableBufferPointer(start: ptr, count: count)
    }

    // MARK: - Ring Buffer Reads (public API)

    func recentEvents(limit: Int = 100, sinceMs: Int64 = 0) -> [BodyEvalEvent] {
        withLock {
            let totalWritten = ringWritePos
            let available = min(totalWritten, ringCapacity)
            guard available > 0, let ring = ring else { return [] }

            let startIdx = totalWritten - available
            var result: [BodyEvalEvent] = []
            result.reserveCapacity(min(limit, available))

            // Walk from oldest to newest
            for i in startIdx..<totalWritten {
                let slot = i & (ringCapacity - 1)
                let ev = ring[slot]
                let ms = machTicksToMs(ev.timestamp)

                if sinceMs > 0 && ms < sinceMs { continue }

                let name =
                    Int(ev.viewTypeIdx) < viewTypeNames.count
                    ? viewTypeNames[Int(ev.viewTypeIdx)] : "?"

                result.append(BodyEvalEvent(timestampMs: ms, viewType: name, durationNs: ev.durationNs))

                if result.count >= limit { break }
            }
            return result
        }
    }

    var totalEventCount: Int {
        withLock { min(ringWritePos, ringCapacity) }
    }

    func clearEvents() {
        withLock {
            ringWritePos = 0
        }
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> [String: Any] {
        guard !isActive else {
            return ["status": "already_active", "note": "Call stop first to restart."]
        }

        guard let hostingViewClass = NSClassFromString("_UIHostingView") else {
            return ["status": "error", "message": "_UIHostingView not found"]
        }

        ensureRing()
        ringWritePos = 0
        viewTypeNames.removeAll()
        viewTypeIndex.removeAll()

        let targetClasses = findHostingViewSubclasses(base: hostingViewClass)
        let conformances = scanViewConformances()

        var hooked: [[String: String]] = []

        // Build type table and hook plan in one pass
        let sel = NSSelectorFromString("layoutSubviews")
        var hookPlan: [(cls: AnyClass, method: Method, originalIMP: IMP, typeIdx: UInt16)] = []

        for cls in targetClasses {
            let className = NSStringFromClass(cls)
            let viewTypeName = extractSwiftUIViewType(from: className)

            guard let method = class_getInstanceMethod(cls, sel) else { continue }
            let originalIMP = method_getImplementation(method)

            let idx: UInt16
            if let existing = viewTypeIndex[viewTypeName] {
                idx = existing
            } else {
                idx = UInt16(viewTypeNames.count)
                viewTypeNames.append(viewTypeName)
                viewTypeIndex[viewTypeName] = idx
            }

            hookPlan.append((cls: cls, method: method, originalIMP: originalIMP, typeIdx: idx))
            hooked.append(["class": className, "view_type": viewTypeName, "status": "hooked"])
        }

        // Allocate stats array now that we know the type count
        allocateTypeStats(count: max(viewTypeNames.count, 1))

        // Install hooks — closures capture only value types (UInt16, IMP, Selector)
        for entry in hookPlan {
            let originalIMP = entry.originalIMP
            let typeIdx = entry.typeIdx

            let block: @convention(block) (AnyObject) -> Void = { obj in
                let t0 = mach_absolute_time()
                let orig = unsafeBitCast(originalIMP, to: (@convention(c) (AnyObject, Selector) -> Void).self)
                orig(obj, sel)
                let elapsed = mach_absolute_time() &- t0
                PepperSwiftUIBodyTracker.shared.recordEvalFast(typeIdx: typeIdx, ticks: t0, durationTicks: elapsed)
            }

            let newIMP = imp_implementationWithBlock(block as Any)
            method_setImplementation(entry.method, newIMP)
            hookedClasses.append((cls: entry.cls, originalIMP: entry.originalIMP, method: entry.method))
        }

        isActive = true

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

        let finalCounts = currentCounts

        pepperLog.info("SwiftUI body tracker stopped. \(restored) hook(s) removed.", category: .lifecycle)

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

    // MARK: - Hot Path Recording

    /// Called on every layoutSubviews — the most performance-critical path.
    ///
    /// - os_unfair_lock (no ObjC message send)
    /// - Ring buffer write via bitmask (no array growth)
    /// - UInt16 type index (no ARC retain/release)
    /// - Stats updated inline (no post-hoc aggregation)
    @inline(__always)
    func recordEvalFast(typeIdx: UInt16, ticks: UInt64, durationTicks: UInt64) {
        let durationNs = machTicksToNs(durationTicks)

        let count: Int = withLock {
            guard let ring = ring, let typeStats = typeStats else { return 0 }

            let slot = ringWritePos & (ringCapacity - 1)
            ring[slot] = CompactEvalEvent(timestamp: ticks, durationNs: durationNs, viewTypeIdx: typeIdx)
            ringWritePos &+= 1

            let idx = Int(typeIdx)
            typeStats[idx].count &+= 1
            typeStats[idx].totalNs &+= durationNs
            if durationNs > typeStats[idx].maxNs { typeStats[idx].maxNs = durationNs }
            return typeStats[idx].count
        }

        // Flight recorder outside the lock — it has its own synchronization
        let viewType = Int(typeIdx) < viewTypeNames.count ? viewTypeNames[Int(typeIdx)] : "?"
        PepperFlightRecorder.shared.record(
            type: .render,
            summary: "body eval: \(viewType) (#\(count), \(durationNs / 1_000)μs)",
            referenceId: viewType
        )
    }

    // MARK: - Counts

    var currentCounts: [String: Int] {
        withLock {
            guard let typeStats = typeStats else { return [:] }
            var counts: [String: Int] = [:]
            counts.reserveCapacity(viewTypeNames.count)
            for i in 0..<viewTypeNames.count {
                let c = typeStats[i].count
                if c > 0 { counts[viewTypeNames[i]] = c }
            }
            return counts
        }
    }

    func reset() {
        if isActive { stop() }
        withLock {
            ringWritePos = 0
            if let stats = typeStats {
                for i in 0..<stats.count {
                    stats[i] = ViewTypeStats()
                }
            }
        }
    }

    // MARK: - Mach-O Protocol Conformance Scanning

    /// Scan loaded images for types conforming to SwiftUI.View.
    /// Returns demangled type names of all discovered View conformances.
    func scanViewConformances() -> [String] {
        var viewTypes: [String] = []

        guard let hostingClass = NSClassFromString("_UIHostingView") else { return [] }

        var classCount: UInt32 = 0
        guard let classList = objc_copyClassList(&classCount) else { return [] }
        defer { free(UnsafeMutableRawPointer(mutating: classList)) }

        for i in 0..<Int(classCount) {
            let cls: AnyClass = classList[i]
            let name = NSStringFromClass(cls)

            if isSubclass(cls, of: hostingClass) && cls !== hostingClass {
                let viewType = extractSwiftUIViewType(from: name)
                if viewType != name {
                    viewTypes.append(viewType)
                }
            }
        }

        let protoConformances = scanSwift5ProtoSection()
        viewTypes.append(contentsOf: protoConformances)

        return Array(Set(viewTypes)).sorted()
    }

    /// Scan __swift5_proto Mach-O section for SwiftUI.View protocol conformances.
    private func scanSwift5ProtoSection() -> [String] {
        var viewTypes: [String] = []

        for imageIndex in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(imageIndex) else { continue }

            // Fast C-string check — avoids allocating a Swift String per image
            guard let imageName = _dyld_get_image_name(imageIndex) else { continue }
            guard strstr(imageName, ".app/") != nil || strstr(imageName, "Pepper.framework") != nil else { continue }

            var size: UInt = 0
            guard
                let sectionData = UnsafeRawPointer(header).withMemoryRebound(
                    to: mach_header_64.self, capacity: 1,
                    {
                        getsectiondata($0, "__TEXT", "__swift5_proto", &size)
                    })
            else { continue }

            let raw = UnsafeRawPointer(sectionData)
            let entryCount = Int(size) / 4  // each entry is 4 bytes (Int32)

            for entryIdx in 0..<entryCount {
                let entryPtr = raw.advanced(by: entryIdx &* 4)
                let relativeOffset = entryPtr.load(as: Int32.self)
                let descriptorPtr = entryPtr.advanced(by: Int(relativeOffset))

                let protoRelPtr = descriptorPtr.load(as: Int32.self)
                let protoDescPtr = descriptorPtr.advanced(by: Int(protoRelPtr))

                // Protocol name at offset +8 — direct byte comparison for "View\0"
                let nameRelPtr = protoDescPtr.advanced(by: 8).load(as: Int32.self)
                let namePtr = protoDescPtr.advanced(by: 8 + Int(nameRelPtr)).assumingMemoryBound(to: CChar.self)

                guard namePtr[0] == 0x56,  // 'V'
                    namePtr[1] == 0x69,  // 'i'
                    namePtr[2] == 0x65,  // 'e'
                    namePtr[3] == 0x77,  // 'w'
                    namePtr[4] == 0x00  // '\0'
                else { continue }

                let typeRelPtr = descriptorPtr.advanced(by: 4).load(as: Int32.self)
                let typeKind = typeRelPtr & 0x3
                guard typeKind == 0 else { continue }

                let typeDescPtr = descriptorPtr.advanced(by: 4 + Int(typeRelPtr & ~0x3))
                let typeNameRelPtr = typeDescPtr.advanced(by: 8).load(as: Int32.self)
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

    private func extractSwiftUIViewType(from className: String) -> String {
        if className.contains("HostingView") {
            if let demangled = demangle(className) {
                if let start = demangled.firstIndex(of: "<"),
                    let end = demangled.lastIndex(of: ">")
                {
                    let innerType = String(demangled[demangled.index(after: start)..<end])
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

    private func demangle(_ mangledName: String) -> String? {
        guard let cStr = mangledName.cString(using: .utf8) else { return nil }
        guard let demangled = swift_demangle(cStr, UInt(cStr.count - 1), nil, nil, 0) else { return nil }
        let result = String(cString: demangled)
        free(demangled)
        return result
    }

    private init() {}
}

// MARK: - Swift runtime demangling

@_silgen_name("swift_demangle")
private func swift_demangle(
    _ mangledName: UnsafePointer<CChar>,
    _ mangledNameLength: UInt,
    _ outputBuffer: UnsafeMutablePointer<CChar>?,
    _ outputBufferSize: UnsafeMutablePointer<UInt>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?
