import Foundation

extension PepperVarRegistry {

    // MARK: - Property Change

    /// A single property change observed after a `vars set` mutation.
    struct PropertyChange {
        /// Full path to the property: "ClassName.propertyName".
        let keyPath: String
        /// Value before the mutation.
        let old: AnyCodable
        /// Value after the mutation.
        let new: AnyCodable

        func toDict() -> [String: AnyCodable] {
            ["keyPath": AnyCodable(keyPath), "old": old, "new": new]
        }
    }

    // MARK: - Snapshot

    /// Snapshot all tracked observable properties as "ClassName.propertyName" -> value.
    /// Used to detect cascade changes after a `vars set` mutation.
    func snapshotAllProperties() -> [String: AnyCodable] {
        var result: [String: AnyCodable] = [:]
        for instance in listAll() {
            guard let className = instance["class"]?.stringValue,
                let propsArray = instance["properties"]?.arrayValue
            else { continue }
            for propEntry in propsArray {
                guard let propDict = propEntry.dictValue,
                    let name = propDict["name"]?.stringValue,
                    let value = propDict["value"]
                else { continue }
                result["\(className).\(name)"] = value
            }
        }
        return result
    }

    // MARK: - Set With Change Tracking

    /// Set a property value and report all cascade effects: other properties that changed
    /// as a side-effect, and which SwiftUI hosting views re-rendered.
    ///
    /// - Parameters:
    ///   - path: "ClassName.propertyName"
    ///   - jsonValue: the new value to write
    /// - Returns: `(newValue, changes, renders, error)`
    ///   - `changes`: other properties that changed as a cascade of this mutation
    ///   - `renders`: addresses of `_UIHostingView` instances that re-rendered
    func setValueWithChangeTracking(
        path: String, jsonValue: AnyCodable
    ) -> (newValue: AnyCodable?, changes: [PropertyChange], renders: [String], error: String?) {

        // 1. Snapshot all tracked properties before mutation
        let beforeSnapshot = snapshotAllProperties()
        let beforeRenders = PepperRenderTracker.shared.currentCounts

        // 2. Perform the mutation
        let (newValue, error) = setValue(path: path, jsonValue: jsonValue)
        if let error = error {
            return (nil, [], [], error)
        }

        // 3. Wait briefly for SwiftUI to process the state change and re-render
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // 4. Snapshot after mutation
        let afterSnapshot = snapshotAllProperties()
        let afterRenders = PepperRenderTracker.shared.currentCounts

        // 5. Diff — find properties that changed (excluding the one we just set)
        var changes: [PropertyChange] = []
        for (keyPath, afterValue) in afterSnapshot {
            guard keyPath != path else { continue }
            guard let beforeValue = beforeSnapshot[keyPath] else { continue }
            if beforeValue != afterValue {
                changes.append(PropertyChange(keyPath: keyPath, old: beforeValue, new: afterValue))
            }
        }
        changes.sort { $0.keyPath < $1.keyPath }

        // 6. Hosting views with increased render counts
        var renders: [String] = []
        for (key, afterCount) in afterRenders where afterCount > (beforeRenders[key] ?? 0) {
            renders.append(key)
        }
        renders.sort()

        return (newValue, changes, renders, nil)
    }
}
