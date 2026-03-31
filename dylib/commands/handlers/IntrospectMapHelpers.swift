import UIKit

// MARK: - CGColor sRGB Helpers

private func rgbComponents(of color: CGColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
    // If already in a compatible RGB space with 3+ components, read directly
    if let comps = color.components, comps.count >= 3 {
        let a = comps.count >= 4 ? comps[3] : 1.0
        return (comps[0], comps[1], comps[2], a)
    }
    // Grayscale or other color space — convert to sRGB
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
        let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
        let comps = converted.components, comps.count >= 3
    else { return nil }
    let a = comps.count >= 4 ? comps[3] : 1.0
    return (comps[0], comps[1], comps[2], a)
}

// MARK: - Shared Spatial Utilities

/// Parse a region bounding box from command params.
/// Supports dict format `{x, y, w, h}` or y-range string `"minY-maxY"`.
/// Used by both MapModeIntrospector and IntrospectHandler (interactive mode).
func parseRegion(from params: [String: AnyCodable]?) -> CGRect? {
    // Dict format: {x, y, w, h}
    if let regionDict = params?["region"]?.dictValue,
        let rx = regionDict["x"]?.doubleValue,
        let ry = regionDict["y"]?.doubleValue,
        let rw = regionDict["w"]?.doubleValue,
        let rh = regionDict["h"]?.doubleValue
    {
        return CGRect(x: rx, y: ry, width: rw, height: rh)
    }
    // Y-range string: "minY-maxY" (full screen width)
    if let regionStr = params?["region"]?.stringValue {
        let parts = regionStr.split(separator: "-")
        if parts.count == 2,
            let minY = Double(parts[0]),
            let maxY = Double(parts[1]),
            maxY > minY
        {
            let screenW = Double(UIScreen.main.bounds.width)
            return CGRect(x: 0, y: minY, width: screenW, height: maxY - minY)
        }
    }
    return nil
}

/// Generic spatial filter: filters and sorts elements by proximity to a point.
/// Used by both MapModeIntrospector (spatialFilterMap) and IntrospectHandler (spatialFilter).
func spatialFilterGeneric<T>(
    _ elements: [T],
    nearestTo point: CGPoint,
    direction: String?,
    count: Int,
    center: KeyPath<T, CGPoint>,
    frame: KeyPath<T, CGRect>
) -> [T] {
    let yPad: CGFloat = 8
    let xPad: CGFloat = 8

    var filtered = elements

    if let direction = direction {
        filtered = filtered.filter { el in
            let c = el[keyPath: center]
            let f = el[keyPath: frame]
            switch direction {
            case "right":
                guard c.x > point.x else { return false }
                return f.minY - yPad < point.y && f.maxY + yPad > point.y
            case "left":
                guard c.x < point.x else { return false }
                return f.minY - yPad < point.y && f.maxY + yPad > point.y
            case "above":
                guard c.y < point.y else { return false }
                return f.minX - xPad < point.x && f.maxX + xPad > point.x
            case "below":
                guard c.y > point.y else { return false }
                return f.minX - xPad < point.x && f.maxX + xPad > point.x
            default:
                return true
            }
        }
    }

    filtered.sort { a, b in
        let ac = a[keyPath: center]
        let bc = b[keyPath: center]
        let da = hypot(ac.x - point.x, ac.y - point.y)
        let db = hypot(bc.x - point.x, bc.y - point.y)
        return da < db
    }

    return Array(filtered.prefix(count))
}

// MARK: - Map Mode Helpers

extension MapModeIntrospector {

    /// Temporary struct for map mode element merging.
    struct MapElement {
        let label: String?
        let type: String
        let center: CGPoint
        let frame: CGRect
        let hitReachable: Bool
        /// Fraction of grid sample points that pass hit-test (0.0–1.0). -1 = not computed.
        var visible: Float = -1
        let heuristic: String?
        let iconName: String?
        let isInteractive: Bool
        let value: String?
        let traits: [String]
        let scrollContext: PepperScrollContext?
        let labelSource: String?
        var gestureContainerFrame: CGRect? = nil
        /// 1-based ordinal index when multiple interactive elements share the same label.
        /// nil when the label is unique. Set by `assignOrdinalIndices()`.
        var index: Int? = nil
        /// Whether this element is in a "selected" state (active tab, chosen segment, on toggle).
        var selected: Bool? = nil
        /// For toggle elements: "on" or "off" based on backgroundColor analysis.
        var toggleState: String? = nil
    }

    /// The effective identifier used for tap targeting: label, icon_name, or heuristic.
    /// Used to detect duplicates and assign ordinal indices.
    private func tapKey(for elem: MapElement) -> String? {
        if let label = elem.label { return "label:\(label)" }
        if let iconName = elem.iconName { return "icon:\(iconName)" }
        if let heuristic = elem.heuristic { return "heur:\(heuristic)" }
        return nil
    }

    /// Assign 1-based ordinal indices to interactive elements that share the same tap target.
    /// Elements are numbered in top-to-bottom, left-to-right order (their existing sort).
    /// Unique identifiers get no index (nil). Covers labels, icon names, and heuristics.
    func assignOrdinalIndices(_ elements: inout [MapElement]) {
        // Count tap keys (only for interactive elements with an identifier)
        var keyCounts: [String: Int] = [:]
        for elem in elements where elem.isInteractive {
            if let key = tapKey(for: elem) {
                keyCounts[key, default: 0] += 1
            }
        }
        // Assign 1-based indices for duplicated keys
        var keyCounters: [String: Int] = [:]
        for i in elements.indices where elements[i].isInteractive {
            if let key = tapKey(for: elements[i]), let count = keyCounts[key], count > 1 {
                let ordinal = (keyCounters[key] ?? 0) + 1
                keyCounters[key] = ordinal
                elements[i].index = ordinal
            }
        }
    }

    /// Group elements into rows by Y-band proximity.
    func groupIntoRows(
        _ elements: [MapElement], bandSize: CGFloat, summary: Bool = false,
        verboseFields: Set<String> = []
    ) -> [AnyCodable] {
        guard !elements.isEmpty else { return [] }

        var rows: [AnyCodable] = []
        var currentRow: [MapElement] = [elements[0]]
        var rowMinY = elements[0].center.y

        for element in elements.dropFirst() {
            if element.center.y - rowMinY <= bandSize {
                currentRow.append(element)
            } else {
                rows.append(serializeRow(currentRow, summary: summary, verboseFields: verboseFields))
                currentRow = [element]
                rowMinY = element.center.y
            }
        }
        if !currentRow.isEmpty {
            rows.append(serializeRow(currentRow, summary: summary, verboseFields: verboseFields))
        }

        return rows
    }

    /// Serialize a row of elements for JSON output.
    /// When `summary` is true, omits frames, traits, heuristics, scroll_context,
    /// and other verbose fields to reduce token count for agent use.
    func serializeRow(
        _ elements: [MapElement], summary: Bool = false,
        verboseFields: Set<String> = []
    ) -> AnyCodable {
        let minY = elements.map { $0.frame.origin.y }.min() ?? 0
        let maxY = elements.map { $0.frame.origin.y + $0.frame.size.height }.max() ?? 0

        let serialized: [AnyCodable] = elements.sorted(by: { $0.center.x < $1.center.x }).map {
            serializeElement($0, summary: summary, verboseFields: verboseFields)
        }

        var row: [String: AnyCodable] = [
            "elements": AnyCodable(serialized)
        ]
        if !summary {
            row["y_range"] = AnyCodable([AnyCodable(Int(minY)), AnyCodable(Int(maxY))])
        }
        return AnyCodable(row)
    }

    /// Serialize a single interactive element to a JSON dictionary.
    /// `verboseFields` controls which heavyweight fields to include (frame, visible,
    /// hit_reachable, label_source). These are omitted by default to reduce payload size;
    /// callers opt in by naming the fields they need.
    private func serializeElement(
        _ elem: MapElement, summary: Bool,
        verboseFields: Set<String> = []
    ) -> AnyCodable {
        var dict: [String: AnyCodable] = [
            "type": AnyCodable(elem.type)
        ]

        if !summary {
            dict["center"] = AnyCodable([AnyCodable(Int(elem.center.x)), AnyCodable(Int(elem.center.y))])
            dict["frame"] = AnyCodable([
                AnyCodable(Int(elem.frame.origin.x)),
                AnyCodable(Int(elem.frame.origin.y)),
                AnyCodable(Int(elem.frame.size.width)),
                AnyCodable(Int(elem.frame.size.height)),
            ])
            if verboseFields.contains("hit_reachable") {
                dict["hit_reachable"] = AnyCodable(elem.hitReachable)
            }
            if verboseFields.contains("visible"), elem.visible >= 0 {
                dict["visible"] = AnyCodable(Double(round(elem.visible * 100) / 100))
            }
        }

        serializeTapTarget(elem, into: &dict, summary: summary)

        if let idx = elem.index {
            dict["index"] = AnyCodable(idx)
        }

        if !summary {
            if let heuristic = elem.heuristic { dict["heuristic"] = AnyCodable(heuristic) }
            if let iconName = elem.iconName { dict["icon_name"] = AnyCodable(iconName) }
        }

        if let value = elem.value, !value.isEmpty {
            dict["value"] = AnyCodable(value)
        }

        if !summary {
            if !elem.traits.isEmpty { dict["traits"] = AnyCodable(elem.traits.map { AnyCodable($0) }) }
            if verboseFields.contains("label_source"), let ls = elem.labelSource {
                dict["label_source"] = AnyCodable(ls)
            }
            if let sc = elem.scrollContext {
                dict["scroll_context"] = AnyCodable(
                    [
                        "direction": AnyCodable(sc.direction),
                        "visible_in_viewport": AnyCodable(sc.visibleInViewport),
                    ] as [String: AnyCodable])
            }
        }

        if elem.selected == true { dict["selected"] = AnyCodable(true) }
        if let toggleState = elem.toggleState { dict["toggle_state"] = AnyCodable(toggleState) }

        return AnyCodable(dict)
    }

    /// Add tap_cmd and related fields to an element dictionary.
    private func serializeTapTarget(_ elem: MapElement, into dict: inout [String: AnyCodable], summary: Bool) {
        if let label = elem.label {
            dict["label"] = AnyCodable(label)
            dict["tap_cmd"] = AnyCodable("text")
        } else if let iconName = elem.iconName {
            dict["tap_cmd"] = AnyCodable("icon_name")
            dict["suggested_tap"] = AnyCodable(iconName)
        } else if let heuristic = elem.heuristic {
            dict["tap_cmd"] = AnyCodable("heuristic")
            dict["suggested_tap"] = AnyCodable(heuristic)
        } else {
            // Point-based tap needs coordinates even in summary mode
            dict["tap_cmd"] = AnyCodable("point")
            dict["center"] = AnyCodable([AnyCodable(Int(elem.center.x)), AnyCodable(Int(elem.center.y))])
        }
    }

    // MARK: - Spatial Query Helpers

    /// Filter map elements by proximity to a point (used in map mode).
    func spatialFilterMap(
        _ elements: [MapElement],
        nearestTo point: CGPoint,
        direction: String?,
        count: Int
    ) -> [MapElement] {
        spatialFilterGeneric(
            elements, nearestTo: point, direction: direction, count: count,
            center: \.center, frame: \.frame)
    }

    // MARK: - Gesture Container Grouping

    /// Group non-interactive text children of gesture container elements.
    /// SwiftUI views with `.contentShape(Rectangle()).onTapGesture { }` make containers
    /// tappable, but their child Text elements appear as separate NI entries. This phase
    /// groups them: the container gets labeled with the topmost text, others are absorbed.
    /// Must run BEFORE Phase 4b (text adoption) so it doesn't steal individual texts.
    func groupGestureContainerChildren(
        _ interactive: inout [MapElement],
        nonInteractive: inout [MapElement],
        screenBounds: CGRect
    ) {
        let screenArea = screenBounds.width * screenBounds.height
        var claimedIndices = Set<Int>()

        // Collect gesture container candidates and sort by area ascending.
        // Smaller containers (individual cards) must claim their texts BEFORE
        // larger containers (sheet/scroll wrappers) to avoid over-grouping.
        let candidates: [(index: Int, frame: CGRect)] = interactive.indices.compactMap { i in
            guard interactive[i].label == nil else { return nil }
            guard let containerFrame = interactive[i].gestureContainerFrame else { return nil }
            let area = containerFrame.width * containerFrame.height
            if area > screenArea * 0.5 { return nil }
            if containerFrame.width < 40 || containerFrame.height < 40 { return nil }
            return (i, containerFrame)
        }.sorted { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }

        for (i, containerFrame) in candidates {

            // Find NI texts whose center is inside the container frame (5pt tolerance)
            let expandedFrame = containerFrame.insetBy(dx: -5, dy: -5)
            var containedIndices: [Int] = []
            for j in nonInteractive.indices {
                guard !claimedIndices.contains(j) else { continue }
                guard nonInteractive[j].label != nil else { continue }
                if expandedFrame.contains(nonInteractive[j].center) {
                    containedIndices.append(j)
                }
            }

            // Need 2+ texts to form a card group (single text is Phase 4b's job)
            guard containedIndices.count >= 2 else { continue }

            // Sort by Y then X, take topmost text as label
            containedIndices.sort { a, b in
                let ay = nonInteractive[a].center.y
                let by = nonInteractive[b].center.y
                if abs(ay - by) > 3 { return ay < by }
                return nonInteractive[a].center.x < nonInteractive[b].center.x
            }

            guard let topLabel = nonInteractive[containedIndices[0]].label else { continue }

            interactive[i] = MapElement(
                label: topLabel,
                type: "button",
                center: interactive[i].center,
                frame: interactive[i].frame,
                hitReachable: interactive[i].hitReachable,
                visible: interactive[i].visible,
                heuristic: "card",
                iconName: interactive[i].iconName,
                isInteractive: true,
                value: interactive[i].value,
                traits: interactive[i].traits,
                scrollContext: interactive[i].scrollContext,
                labelSource: "text",
                gestureContainerFrame: interactive[i].gestureContainerFrame
            )

            claimedIndices.formUnion(containedIndices)
        }

        // Remove all claimed NI texts (reverse order for safe removal)
        for idx in claimedIndices.sorted().reversed() {
            nonInteractive.remove(at: idx)
        }
    }

    // MARK: - Radio Option Group Detection

    /// Detect groups of non-interactive text that look like tappable option groups
    /// (radio buttons, segment controls) and promote them to interactive elements.
    ///
    /// Pattern: 2+ short text labels at the same Y coordinate, side by side,
    /// with similar heights. Common in SwiftUI views using `.onTapGesture`.
    func promoteRadioOptionGroups(
        _ interactive: inout [MapElement],
        nonInteractive: inout [MapElement]
    ) {
        guard nonInteractive.count >= 2 else { return }

        // Group non-interactive text by Y-band (within 5pt)
        var yGroups: [[Int]] = []
        let sorted = nonInteractive.enumerated().sorted { $0.element.center.y < $1.element.center.y }

        var currentGroup: [Int] = []
        var groupY: CGFloat = -.infinity

        for (idx, elem) in sorted {
            guard let label = elem.label, label.count >= 2 else { continue }
            // Only short labels (2-12 chars) and reasonably sized frames.
            // Max width 210pt allows 2-column option layouts (175pt each on 402pt screen).
            // Exclude very small text (height < 16pt) — chart axis labels (14.7pt).
            // Keeps segment-sized text (17pt) like "Featured", "Sleep", "Recent".
            guard label.count <= 12, elem.frame.width < 210,
                elem.frame.height >= 16, elem.frame.height < 50
            else { continue }
            // Exclude labels with digits (stat values: "501", "7min", "0.1mi")
            // and ALL-CAPS labels ≥3 chars (stat units: "STEPS", "DURATION").
            // Real options are mixed-case: "Off", "Push", "Sleep", "Recent".
            guard !label.contains(where: { $0.isNumber }) else { continue }
            if label.count >= 3, label == label.uppercased() { continue }

            if abs(elem.center.y - groupY) <= 5 {
                currentGroup.append(idx)
            } else {
                if isValidOptionGroup(currentGroup, in: nonInteractive) {
                    yGroups.append(currentGroup)
                }
                currentGroup = [idx]
                groupY = elem.center.y
            }
        }
        if isValidOptionGroup(currentGroup, in: nonInteractive) {
            yGroups.append(currentGroup)
        }

        // Collect interactive element frames to skip text inside content areas/charts.
        // Exclude full-screen containers (content_area spanning >80% of screen)
        // which would block ALL text from being promoted.
        let screenArea = UIScreen.main.bounds.width * UIScreen.main.bounds.height
        let interactiveFrames = interactive.compactMap { elem -> CGRect? in
            let area = elem.frame.width * elem.frame.height
            if area > screenArea * 0.8 { return nil }
            return elem.frame
        }

        // Promote groups of 3+ to interactive (2 could be coincidental text pairs)
        var indicesToRemove = Set<Int>()
        for group in yGroups {
            // Skip if any member falls inside an existing interactive element's frame.
            // Prevents chart axis labels (12AM, 6AM) from being promoted.
            let insideExisting = group.contains { idx in
                let center = nonInteractive[idx].center
                return interactiveFrames.contains { $0.contains(center) }
            }
            if insideExisting { continue }

            for idx in group {
                let elem = nonInteractive[idx]
                interactive.append(
                    MapElement(
                        label: elem.label, type: "option",
                        center: elem.center, frame: elem.frame,
                        hitReachable: true, visible: elem.visible,
                        heuristic: "radio_option",
                        iconName: nil,
                        isInteractive: true, value: elem.value,
                        traits: elem.traits,
                        scrollContext: elem.scrollContext,
                        labelSource: "text"
                    ))
                indicesToRemove.insert(idx)
            }
        }

        // Remove promoted elements from non-interactive (reverse order)
        for idx in indicesToRemove.sorted().reversed() {
            nonInteractive.remove(at: idx)
        }
    }

    /// Check if a group of indices forms a valid option group.
    /// 3+ members always valid. 2 members must have short no-digit labels
    /// and fill their row (not scattered text like section headers).
    private func isValidOptionGroup(_ group: [Int], in elements: [MapElement]) -> Bool {
        if group.count >= 3 { return true }
        if group.count < 2 { return false }
        // All labels must be short and digit-free
        let allValid = group.allSatisfy { idx in
            guard let label = elements[idx].label, label.count <= 10 else { return false }
            return !label.contains(where: { $0.isNumber })
        }
        guard allValid else { return false }
        // 2-member groups: members must fill their span (not scattered text).
        // Real options: Off(175pt)+Push(175pt) span 187pt → fill=350/187=1.87
        // Real options: Featured(60pt)+Popular(45pt) span 100pt → fill=105/100=1.05
        // False positive: Rest(34pt)+Sort(38pt) span 195pt → fill=72/195=0.37
        let widths = group.map { elements[$0].frame.width }
        let totalW = widths.reduce(0, +)
        let xs = group.map { elements[$0].center.x }
        let span = (xs.max() ?? 0) - (xs.min() ?? 0)
        guard span > 0 else { return true }  // Same center = valid
        let fillRatio = totalW / span
        return fillRatio > 0.6  // Members fill > 60% of the span
    }

    // MARK: - Segment Control Detection

    /// Detect groups of labeled buttons at the same Y that form a segment control
    /// (Day/Week/Month/Year, Photos/Popular, Featured/Trending).
    /// Labels these with heuristic "segment" so the builder knows they're selectable tabs.
    // swiftlint:disable:next cyclomatic_complexity
    func promoteSegmentGroups(_ interactive: inout [MapElement], screenWidth: CGFloat) {
        guard interactive.count >= 2 else { return }

        // Find labeled buttons that could be segment items:
        // - Has a label, short (< 15 chars)
        // - Is a button type
        // - Width < 120pt (not full-width cells)
        // - Not already a tab_button or radio_option
        // Labels that are navigation actions, not segment choices
        let navLabels: Set<String> = ["Back", "Cancel", "Done", "Close", "Save", "Edit"]
        let candidates: [(idx: Int, y: CGFloat)] = interactive.enumerated().compactMap { (i, el) in
            guard let label = el.label, !label.isEmpty, label.count < 15 else { return nil }
            guard el.type == "button" else { return nil }
            guard el.frame.width < 120 else { return nil }
            guard el.heuristic == nil else { return nil }
            guard !navLabels.contains(label) else { return nil }
            return (i, el.center.y)
        }

        // Group by Y-band (within 8pt)
        var groups: [[Int]] = []
        var currentGroup: [Int] = []
        var groupY: CGFloat = -.infinity

        let sorted = candidates.sorted { $0.y < $1.y }
        for (idx, y) in sorted {
            if abs(y - groupY) <= 8 {
                currentGroup.append(idx)
            } else {
                if currentGroup.count >= 2 { groups.append(currentGroup) }
                currentGroup = [idx]
                groupY = y
            }
        }
        if currentGroup.count >= 2 { groups.append(currentGroup) }

        // Validate groups: members should span < 85% screen width (not a full row of cells)
        // and fill their span (not nav bar Cancel/Save pushed to opposite edges).
        for group in groups {
            let xs = group.map { interactive[$0].center.x }
            let span = (xs.max() ?? 0) - (xs.min() ?? 0)
            guard span < screenWidth * 0.85 else { continue }
            guard group.count >= 2 else { continue }
            // Segments must have distinct labels (e.g. Day/Week/Month).
            // Duplicate labels like "Follow"/"Follow" are action buttons, not segments.
            let labels = Set(group.compactMap { interactive[$0].label })
            guard labels.count >= group.count else { continue }
            // Fill ratio: combined widths / span. Real segments are compact (fill > 0.5).
            // Nav bar buttons: Cancel(72pt)+Save(36pt) span 327pt → fill=0.33 → rejected.
            let totalW = group.map { interactive[$0].frame.width }.reduce(0, +)
            guard span > 0 else { continue }  // Same center = skip
            let fillRatio = totalW / span
            guard fillRatio > 0.5 else { continue }

            for idx in group {
                interactive[idx] = MapElement(
                    label: interactive[idx].label,
                    type: "segment",
                    center: interactive[idx].center,
                    frame: interactive[idx].frame,
                    hitReachable: interactive[idx].hitReachable,
                    visible: interactive[idx].visible,
                    heuristic: "segment",
                    iconName: interactive[idx].iconName,
                    isInteractive: true,
                    value: interactive[idx].value,
                    traits: interactive[idx].traits,
                    scrollContext: interactive[idx].scrollContext,
                    labelSource: interactive[idx].labelSource
                )
            }
        }
    }

    // MARK: - Volatile Text Tracking

    /// Track text labels by position across introspect calls. Positions whose labels
    /// change are "volatile" (cycling timers, counters) and get sorted to the end.
    private static var prevTextByPos: [String: String] = [:]
    private static var volatilePositions: Set<String> = []

    /// Quantized position key for volatile tracking (5pt grid absorbs layout jitter).
    private static func posKey(_ center: CGPoint) -> String {
        let qx = (Int(center.x) / 5) * 5
        let qy = (Int(center.y) / 5) * 5
        return "\(qx),\(qy)"
    }

    /// Detect volatile text positions, sort volatile to end. Returns volatile position keys.
    static func trackVolatileText(_ elements: inout [MapElement]) -> Set<String> {
        var currentByPos: [String: String] = [:]
        for elem in elements {
            currentByPos[posKey(elem.center)] = elem.label
        }
        // If < 50% of previous positions still exist, user navigated → reset
        let currKeys = Set(currentByPos.keys)
        let prevKeys = Set(prevTextByPos.keys)
        let overlap = prevKeys.intersection(currKeys).count
        if !prevKeys.isEmpty && Double(overlap) / Double(max(prevKeys.count, 1)) < 0.5 {
            volatilePositions.removeAll()
        }
        for (key, label) in currentByPos {
            if let prev = prevTextByPos[key], prev != label {
                volatilePositions.insert(key)
            }
        }
        prevTextByPos = currentByPos
        volatilePositions = volatilePositions.intersection(currKeys)
        let stable = elements.filter { !volatilePositions.contains(posKey($0.center)) }
        let volatile = elements.filter { volatilePositions.contains(posKey($0.center)) }
        elements = stable + volatile
        return volatilePositions
    }

    /// Serialize non-interactive elements for JSON, marking volatile positions.
    /// When `summary` is true, returns only type, label, and value.
    /// Full mode includes center and frame. `verboseFields` controls opt-in heavyweight fields (visible, label_source).
    func serializeNonInteractive(
        _ elements: [MapElement], volatileKeys: Set<String>, summary: Bool = false,
        verboseFields: Set<String> = []
    ) -> [AnyCodable] {
        elements.map { elem in
            var dict: [String: AnyCodable] = [
                "type": AnyCodable(elem.type)
            ]
            if let label = elem.label { dict["label"] = AnyCodable(label) }
            if let value = elem.value, !value.isEmpty { dict["value"] = AnyCodable(value) }

            if !summary {
                dict["center"] = AnyCodable([AnyCodable(Int(elem.center.x)), AnyCodable(Int(elem.center.y))])
                dict["frame"] = AnyCodable([
                    AnyCodable(Int(elem.frame.origin.x)),
                    AnyCodable(Int(elem.frame.origin.y)),
                    AnyCodable(Int(elem.frame.size.width)),
                    AnyCodable(Int(elem.frame.size.height)),
                ])
                if verboseFields.contains("visible"), elem.visible >= 0 {
                    dict["visible"] = AnyCodable(Double(round(elem.visible * 100) / 100))
                }
                if verboseFields.contains("label_source"), let ls = elem.labelSource {
                    dict["label_source"] = AnyCodable(ls)
                }
                if volatileKeys.contains(Self.posKey(elem.center)) { dict["volatile"] = AnyCodable(true) }
            }

            return AnyCodable(dict)
        }
    }

    // MARK: - Selected State Detection via CALayer Background

    /// Detect selected state for groups of sibling elements (segments, radio options)
    /// by comparing their backing CALayer backgroundColors. The element with a distinct
    /// non-clear background that differs from the majority is "selected".
    /// Also detects toggle on/off state via backgroundColor (green = on, gray = off).
    // swiftlint:disable:next cyclomatic_complexity
    func detectSelectedByBackground(_ elements: inout [MapElement], window: UIWindow) {
        // Group elements by type + Y-band (within 8pt) to find sibling sets
        let groupTypes: Set<String> = ["segment", "option"]
        var groups: [[Int]] = []
        var toggleIndices: [Int] = []

        // Collect indices for groupable types
        var groupCandidates: [(idx: Int, y: CGFloat, type: String)] = []
        for i in elements.indices {
            if elements[i].heuristic == "toggle" {
                toggleIndices.append(i)
            } else if groupTypes.contains(elements[i].type) || elements[i].heuristic == "radio_option"
                || elements[i].heuristic == "segment"
            {
                groupCandidates.append((i, elements[i].center.y, elements[i].type))
            }
        }

        // Sort by Y and group by Y-band
        groupCandidates.sort { $0.y < $1.y }
        var currentGroup: [Int] = []
        var groupY: CGFloat = -.infinity
        var groupType: String = ""

        for (idx, y, type) in groupCandidates {
            if abs(y - groupY) <= 8 && type == groupType {
                currentGroup.append(idx)
            } else {
                if currentGroup.count >= 2 { groups.append(currentGroup) }
                currentGroup = [idx]
                groupY = y
                groupType = type
            }
        }
        if currentGroup.count >= 2 { groups.append(currentGroup) }

        // For each group, probe backgroundColor at each element's center
        for group in groups {
            // Skip if any element already has selected state (from a11y traits)
            if group.contains(where: { elements[$0].selected == true }) { continue }

            var bgColors: [(idx: Int, color: CGColor?)] = []
            for idx in group {
                let center = elements[idx].center
                let bgColor = probeBackgroundColor(at: center, in: window)
                bgColors.append((idx, bgColor))
            }

            // Determine which element has a distinct background.
            // Strategy: find colors that are non-clear and non-nil. If exactly one
            // element has a distinct (non-clear, non-white) background and the others
            // don't, that one is selected.
            let colorInfos: [(idx: Int, isFilled: Bool)] = bgColors.map { (idx, color) in
                guard let color = color else { return (idx, false) }
                return (idx, isDistinctBackground(color))
            }

            let filledCount = colorInfos.filter(\.isFilled).count
            let unfilledCount = colorInfos.count - filledCount

            if filledCount == 1 && unfilledCount >= 1 {
                // Exactly one filled — that's the selected one
                if let selected = colorInfos.first(where: \.isFilled) {
                    elements[selected.idx].selected = true
                }
            } else if filledCount >= 2 && unfilledCount == 0 {
                // All are filled — try to find the one with the most distinct color.
                // Compare alpha: higher alpha = more prominent = selected.
                // Or compare brightness: darker on light theme = selected.
                let analyzed: [(idx: Int, brightness: CGFloat, alpha: CGFloat)] = bgColors.compactMap { (idx, color) in
                    guard let color = color else { return nil }
                    guard let c = rgbComponents(of: color) else { return nil }
                    let brightness = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
                    return (idx, brightness, c.a)
                }
                guard analyzed.count == bgColors.count else { continue }

                // Find the element with the lowest brightness (darkest = selected on light theme)
                // Only if there's a clear difference (> 0.15 brightness gap)
                let sorted = analyzed.sorted { $0.brightness < $1.brightness }
                if sorted.count >= 2 {
                    let gap = sorted[1].brightness - sorted[0].brightness
                    if gap > 0.15 {
                        elements[sorted[0].idx].selected = true
                    }
                }
            }
        }

        // Toggle on/off detection via backgroundColor
        for idx in toggleIndices {
            let center = elements[idx].center
            guard let bgColor = probeBackgroundColor(at: center, in: window) else { continue }
            guard let c = rgbComponents(of: bgColor) else { continue }

            let r = c.r
            let g = c.g
            let b = c.b
            // Green-ish = on (iOS system green ~0.2, 0.78, 0.35)
            // Gray-ish = off (iOS system gray ~0.9, 0.9, 0.9 or ~0.47, 0.47, 0.47)
            if g > 0.5 && g > r * 1.3 && g > b * 1.3 {
                elements[idx].toggleState = "on"
                elements[idx].selected = true
            } else if abs(r - g) < 0.08 && abs(g - b) < 0.08 {
                // Neutral gray (r ≈ g ≈ b) = off
                elements[idx].toggleState = "off"
            }
        }
    }

    /// Probe the backgroundColor of the view/layer at a given point.
    /// Checks the hit view itself plus up to 3 ancestors.
    private func probeBackgroundColor(at point: CGPoint, in window: UIWindow) -> CGColor? {
        guard let hitView = window.hitTest(point, with: nil) else { return nil }

        // Walk up to 3 levels to find a view with a non-clear backgroundColor
        var view: UIView? = hitView
        for _ in 0..<4 {
            guard let v = view else { break }

            // Check view's backgroundColor first
            if let uiColor = v.backgroundColor {
                var r: CGFloat = 0
                var g: CGFloat = 0
                var b: CGFloat = 0
                var a: CGFloat = 0
                uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
                if a > 0.1 { return uiColor.cgColor }
            }

            // Check the layer's backgroundColor
            if let layerBg = v.layer.backgroundColor {
                let color = UIColor(cgColor: layerBg)
                var r: CGFloat = 0
                var g: CGFloat = 0
                var b: CGFloat = 0
                var a: CGFloat = 0
                color.getRed(&r, green: &g, blue: &b, alpha: &a)
                if a > 0.1 { return layerBg }
            }

            // Check sublayers (SwiftUI renders backgrounds on sublayers, not the view)
            if let sublayers = v.layer.sublayers {
                for sublayer in sublayers {
                    if let bg = sublayer.backgroundColor {
                        let color = UIColor(cgColor: bg)
                        var r: CGFloat = 0
                        var g: CGFloat = 0
                        var b: CGFloat = 0
                        var a: CGFloat = 0
                        color.getRed(&r, green: &g, blue: &b, alpha: &a)
                        if a > 0.1 { return bg }
                    }
                }
            }

            view = v.superview
        }
        return nil
    }

    /// Check if a CGColor represents a "distinct" background (not clear, not white, not very transparent).
    private func isDistinctBackground(_ color: CGColor) -> Bool {
        guard let c = rgbComponents(of: color) else { return false }

        if c.a < 0.15 { return false }  // Nearly transparent

        let r = c.r
        let g = c.g
        let b = c.b
        // White or very light gray is not "distinct" (background)
        if r > 0.95 && g > 0.95 && b > 0.95 { return false }

        // Very dark (near black) on dark mode could be background too — skip
        // But we keep it since dark mode selected states are often colored

        return true
    }

    // MARK: - Chart Axis Label Detection

    /// Detect chart time axis labels: "12 AM", "6 PM", "12AM", "6PM", "12am", etc.
    /// These are generated by iOS Charts and pollute the non-interactive text list.
    func isChartTimeLabel(_ text: String) -> Bool {
        let upper = text.uppercased()
        // Match patterns: "12 AM", "6PM", "12AM", etc.
        // Also handles "12 AM" with non-breaking space
        let stripped = upper.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
        guard stripped.hasSuffix("AM") || stripped.hasSuffix("PM") else { return false }
        let numPart = stripped.dropLast(2)
        guard let hour = Int(numPart), hour >= 0, hour <= 12 else { return false }
        return true
    }
}

// MARK: - Spatial Data Structures for O(1) Lookups

/// Hash-based spatial dedup: O(1) insert and O(1) contains, replacing O(n) array scans.
/// Uses a grid of cells — two points within `cellSize` pts are considered duplicates.
struct SpatialHash {
    private let cellSize: CGFloat
    private var cells: Set<Int64> = []

    init(cellSize: CGFloat = 5) {
        self.cellSize = cellSize
    }

    /// Pack two Int32 grid coordinates into one Int64 key.
    /// cy uses bitPattern cast so negative values occupy the low 32 bits without sign-extension.
    private func key(x: CGFloat, y: CGFloat) -> Int64 {
        let cx = Int32(floor(x / cellSize))
        let cy = Int32(floor(y / cellSize))
        return Int64(cx) << 32 | Int64(bitPattern: UInt64(UInt32(bitPattern: cy)))
    }

    mutating func insert(x: CGFloat, y: CGFloat) {
        cells.insert(key(x: x, y: y))
    }

    /// Check if a point is within cellSize of any previously inserted point.
    /// Checks the point's cell and all 8 neighbors to handle boundary cases.
    func contains(x: CGFloat, y: CGFloat) -> Bool {
        let cx = Int32(floor(x / cellSize))
        let cy = Int32(floor(y / cellSize))
        for dx: Int32 in -1...1 {
            for dy: Int32 in -1...1 {
                let k = Int64(cx + dx) << 32 | Int64(bitPattern: UInt64(UInt32(bitPattern: cy + dy)))
                if cells.contains(k) { return true }
            }
        }
        return false
    }
}

/// Y-band index for non-interactive text elements.
/// Groups element indices by Y-coordinate band for O(1) range lookups.
struct SpatialTextIndex {
    private var bands: [Int: [Int]] = [:]  // band key → element indices
    private let bandSize: CGFloat

    init(elements: [MapModeIntrospector.MapElement], bandSize: CGFloat = 10) {
        self.bandSize = bandSize
        for (i, elem) in elements.enumerated() {
            let key = Int(floor(elem.center.y / bandSize))
            bands[key, default: []].append(i)
        }
    }

    /// Return all element indices whose Y falls within the given range.
    func candidates(inYRange range: ClosedRange<CGFloat>) -> [Int] {
        let minBand = Int(floor(range.lowerBound / bandSize))
        let maxBand = Int(floor(range.upperBound / bandSize))
        var result: [Int] = []
        for band in minBand...maxBand {
            if let indices = bands[band] {
                result.append(contentsOf: indices)
            }
        }
        return result
    }
}

/// Spatial index of CGRects for fast containment checks.
/// Grid-based: each rect is inserted into all cells it covers.
struct SpatialFrameIndex {
    private var cells: [Int64: [CGRect]] = [:]
    private let cellSize: CGFloat

    init(frames: [CGRect], cellSize: CGFloat = 40) {
        self.cellSize = cellSize
        for frame in frames {
            let minCX = Int32(floor(frame.minX / cellSize))
            let maxCX = Int32(floor(frame.maxX / cellSize))
            let minCY = Int32(floor(frame.minY / cellSize))
            let maxCY = Int32(floor(frame.maxY / cellSize))
            for cx in minCX...maxCX {
                for cy in minCY...maxCY {
                    let key = Int64(cx) << 32 | Int64(bitPattern: UInt64(UInt32(bitPattern: cy)))
                    cells[key, default: []].append(frame)
                }
            }
        }
    }

    /// Check if any indexed frame fully contains the given frame (and isn't identical to it).
    func containsParent(of child: CGRect) -> Bool {
        let cx = Int32(floor(child.midX / cellSize))
        let cy = Int32(floor(child.midY / cellSize))
        let key = Int64(cx) << 32 | Int64(bitPattern: UInt64(UInt32(bitPattern: cy)))
        guard let candidates = cells[key] else { return false }
        return candidates.contains { parent in
            parent != child && parent.contains(child)
        }
    }
}
