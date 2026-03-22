import UIKit

/// iOS implementation of `ViewIntrospection`.
///
/// Layer inspection uses CALayer tree traversal (same approach as LayersHandler).
/// Heap analysis uses the C-bridge malloc zone scanner (same approach as HeapSnapshotHandler).
final class IOSViewIntrospection: ViewIntrospection {

    private var savedSnapshot: [String: Int]?
    private var snapshotTime: Date?

    // MARK: - Layer Inspection

    func inspectLayers(at point: CGPoint, maxDepth: Int) -> LayerInspectionResult? {
        guard let window = UIWindow.pepper_keyWindow else { return nil }
        guard let hitView = window.hitTest(point, with: nil) else { return nil }

        let viewClass = String(describing: type(of: hitView))
        let viewFrame = hitView.convert(hitView.bounds, to: window)
        let layerTree = walkLayer(hitView.layer, windowRef: window, depth: 0, maxDepth: maxDepth)

        return LayerInspectionResult(
            viewClass: viewClass,
            viewFrame: viewFrame,
            point: point,
            layerTree: layerTree
        )
    }

    // MARK: - Heap Analysis

    func heapSnapshot(filterPrefixes: [String]?) -> HeapSnapshotResult {
        let counts = scanHeap(filterPrefixes: filterPrefixes)
        let sorted = counts.sorted { $0.value > $1.value }.prefix(30)
        let topClasses = sorted.map { HeapClassInfo(className: $0.key, instanceCount: $0.value) }

        return HeapSnapshotResult(
            totalClasses: counts.count,
            totalInstances: counts.values.reduce(0, +),
            topClasses: topClasses
        )
    }

    func heapDiff() -> HeapDiffResult? {
        guard let baseline = savedSnapshot else { return nil }

        let current = scanHeap(filterPrefixes: nil)

        var growing: [HeapClassDelta] = []
        var shrinking: [HeapClassDelta] = []

        for (cls, currentCount) in current {
            let baseCount = baseline[cls] ?? 0
            let delta = currentCount - baseCount
            if delta > 0 {
                growing.append(HeapClassDelta(className: cls, before: baseCount, after: currentCount, delta: delta))
            } else if delta < 0 {
                shrinking.append(HeapClassDelta(className: cls, before: baseCount, after: currentCount, delta: delta))
            }
        }

        for (cls, baseCount) in baseline where current[cls] == nil {
            shrinking.append(HeapClassDelta(className: cls, before: baseCount, after: 0, delta: -baseCount))
        }

        growing.sort { $0.delta > $1.delta }
        shrinking.sort { $0.delta < $1.delta }

        let memInfo = getMemoryInfo()

        return HeapDiffResult(
            growing: growing,
            shrinking: shrinking,
            residentMb: memInfo.residentMb,
            virtualMb: memInfo.virtualMb
        )
    }

    func saveHeapBaseline() {
        savedSnapshot = scanHeap(filterPrefixes: nil)
        snapshotTime = Date()
    }

    func clearHeapBaseline() {
        savedSnapshot = nil
        snapshotTime = nil
    }

    var hasHeapBaseline: Bool {
        savedSnapshot != nil
    }

    // MARK: - Layer Tree Walk

    private func walkLayer(_ layer: CALayer, windowRef: UIView, depth: Int, maxDepth: Int) -> LayerNodeInfo {
        let windowFrame: CGRect
        if let superlayer = layer.superlayer {
            windowFrame = superlayer.convert(layer.frame, to: windowRef.layer)
        } else {
            windowFrame = layer.frame
        }

        var props: [String: String] = [:]
        props["cornerRadius"] = String(Double(layer.cornerRadius))
        props["opacity"] = String(Double(layer.opacity))
        if layer.borderWidth > 0 {
            props["borderWidth"] = String(Double(layer.borderWidth))
        }
        if let bg = layer.backgroundColor {
            props["backgroundColor"] = cgColorToHex(bg)
        }
        if layer.shadowOpacity > 0 {
            props["shadowOpacity"] = String(Double(layer.shadowOpacity))
            props["shadowRadius"] = String(Double(layer.shadowRadius))
        }

        var sublayerNodes: [LayerNodeInfo] = []
        if depth < maxDepth, let sublayers = layer.sublayers {
            sublayerNodes = sublayers.map { walkLayer($0, windowRef: windowRef, depth: depth + 1, maxDepth: maxDepth) }
        }

        return LayerNodeInfo(
            className: String(describing: type(of: layer)),
            frame: windowFrame,
            properties: props,
            sublayers: sublayerNodes
        )
    }

    // MARK: - Heap Scan (via C bridge)

    private func scanHeap(filterPrefixes: [String]?) -> [String: Int] {
        let prefixes: [String]
        if let provided = filterPrefixes {
            prefixes = provided
        } else {
            prefixes = [Bundle.main.infoDictionary?["CFBundleName"] as? String ?? ""]
                + PepperAppConfig.shared.classLookupPrefixes
        }

        var cPrefixes: [UnsafePointer<CChar>?] = []
        var cStrings: [UnsafeMutablePointer<CChar>] = []

        for prefix in prefixes where !prefix.isEmpty {
            let cStr = strdup(prefix)!
            cStrings.append(cStr)
            cPrefixes.append(UnsafePointer(cStr))
        }
        defer { cStrings.forEach { free($0) } }

        var entriesPtr: UnsafeMutablePointer<PepperHeapEntry>?
        var count: Int32 = 0

        let result = cPrefixes.withUnsafeBufferPointer { buf in
            pepper_heap_scan(&entriesPtr, &count, buf.baseAddress, Int32(buf.count))
        }

        guard result == 0, let entries = entriesPtr else { return [:] }
        defer { free(entries) }

        var counts: [String: Int] = [:]
        for i in 0..<Int(count) {
            let entry = entries[i]
            guard let namePtr = entry.class_name else { continue }
            var name = String(cString: namePtr)
            if let dotIdx = name.lastIndex(of: ".") {
                name = String(name[name.index(after: dotIdx)...])
            }
            counts[name, default: 0] += Int(entry.count)
        }

        return counts
    }

    // MARK: - Memory Info

    private struct MemoryInfo {
        let residentMb: Double
        let virtualMb: Double
    }

    private func getMemoryInfo() -> MemoryInfo {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return MemoryInfo(residentMb: 0, virtualMb: 0) }
        return MemoryInfo(
            residentMb: Double(info.resident_size) / 1_048_576.0,
            virtualMb: Double(info.virtual_size) / 1_048_576.0
        )
    }

    // MARK: - Helpers

    private func cgColorToHex(_ color: CGColor) -> String {
        guard let rgb = color.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
              let components = rgb.components, components.count >= 3 else {
            return "#000000FF"
        }
        let r = UInt8(min(max(components[0], 0), 1) * 255)
        let g = UInt8(min(max(components[1], 0), 1) * 255)
        let b = UInt8(min(max(components[2], 0), 1) * 255)
        let a = UInt8(min(max(components.count > 3 ? components[3] : 1.0, 0), 1) * 255)
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
