import Foundation

/// A node in the layer tree hierarchy.
struct LayerNodeInfo {
    let className: String
    let frame: CGRect
    let properties: [String: String]
    let sublayers: [LayerNodeInfo]
}

/// Result of layer inspection at a screen coordinate.
struct LayerInspectionResult {
    let viewClass: String
    let viewFrame: CGRect
    let point: CGPoint
    let layerTree: LayerNodeInfo
}

/// Summary of a single class in a heap snapshot.
struct HeapClassInfo {
    let className: String
    let instanceCount: Int
}

/// Result of a heap snapshot or diff operation.
struct HeapSnapshotResult {
    let totalClasses: Int
    let totalInstances: Int
    let topClasses: [HeapClassInfo]
}

/// Heap diff showing which classes grew or shrank between snapshots.
struct HeapDiffResult {
    let growing: [HeapClassDelta]
    let shrinking: [HeapClassDelta]
    let residentMb: Double
    let virtualMb: Double
}

/// Change in instance count for a single class between snapshots.
struct HeapClassDelta {
    let className: String
    let before: Int
    let after: Int
    let delta: Int
}

/// Inspects view layers and heap state for debugging.
///
/// iOS implementation uses CALayer traversal for layer inspection and
/// ObjC runtime heap enumeration for memory analysis. Android would
/// use View.getLayerType/RenderNode for layers and Debug.dumpHprofData
/// for heap.
protocol ViewIntrospection {
    /// Inspect the layer tree at a screen coordinate.
    func inspectLayers(at point: CGPoint, maxDepth: Int) -> LayerInspectionResult?

    /// Take a heap snapshot of current ObjC object counts.
    func heapSnapshot(filterPrefixes: [String]?) -> HeapSnapshotResult

    /// Compare current heap to the saved baseline snapshot.
    func heapDiff() -> HeapDiffResult?

    /// Save the current heap state as the baseline for future diffs.
    func saveHeapBaseline()

    /// Clear the saved heap baseline.
    func clearHeapBaseline()

    /// Whether a heap baseline has been saved.
    var hasHeapBaseline: Bool { get }
}
