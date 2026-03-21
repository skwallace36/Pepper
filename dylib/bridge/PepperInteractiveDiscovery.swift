import UIKit

// MARK: - Interactive Element Discovery

extension PepperSwiftUIBridge {

    /// Discover ALL interactive elements (labeled + unlabeled) in one unified list.
    /// Combines enhanced accessibility walk with UIView hierarchy walk, deduplicates,
    /// and optionally filters by hit-test reachability.
    ///
    /// This is the backend for `introspect mode:interactive`.
    func discoverInteractiveElements(rootView: UIView? = nil, hitTestFilter: Bool = true, maxElements: Int = 500) -> [PepperInteractiveElement] {
        // Return cached result if no UI-mutating events have occurred and TTL hasn't expired.
        // Only use cache when using default root (no scoping).
        if rootView == nil, let cached = cachedInteractive, cached.gen == cacheGeneration,
           CFAbsoluteTimeGetCurrent() - cached.time < cacheTTL {
            lastInteractiveTruncated = cached.truncated
            return cached.elements
        }

        ensureAccessibilityActive()

        guard let window = UIWindow.pepper_keyWindow else { return [] }

        let walkRoot: UIView = rootView ?? window

        // Phase 1: Enhanced accessibility walk (includes unlabeled interactive elements)
        var accElements: [PepperAccessibilityElement] = []
        walkAccessibilityTree(element: walkRoot, depth: 0, maxDepth: 20, includeUnlabeled: true, into: &accElements)
        accElements = accElements.filter { element in
            let cls = element.className
            if PepperClassFilter.isInternalClass(cls) { return false }
            return true
        }

        // Track truncation across phases
        var truncated = accElements.count >= Self.maxElementCount

        // Convert interactive accessibility elements to unified format, track for dedup
        var results: [PepperInteractiveElement] = []
        var dedup = ElementDedup()

        for acc in accElements where acc.isInteractive && acc.frame != .zero && acc.frame.width > 0 {
            guard results.count < maxElements else { break }
            let labeled = acc.label != nil && !acc.label!.isEmpty
            var iconName: String? = nil
            let heuristic = labeled ? nil : inferHeuristic(
                className: acc.className,
                frame: acc.frame,
                gestures: [],
                label: acc.label,
                view: nil,
                iconName: &iconName
            )
            // staticText trait means the label is rendered visible text (UILabel, SwiftUI Text)
            let labelSource: String? = labeled
                ? (acc.traits.contains("staticText") || acc.traits.contains("link") ? "text" : "a11y")
                : nil
            results.append(PepperInteractiveElement(
                className: acc.className,
                label: acc.label,
                center: CGPoint(x: acc.frame.midX, y: acc.frame.midY),
                frame: acc.frame,
                labeled: labeled,
                source: "accessibility",
                gestures: acc.traits.contains("button") ? ["tap"] : [],
                isControl: false,
                controlType: nil,
                hitReachable: true,
                heuristic: heuristic,
                iconName: iconName,
                traits: acc.traits,
                labelSource: labelSource
            ))
            dedup.markSeen(frame: acc.frame)
        }

        // Phase 2: UIView hierarchy walk for interactive views not in accessibility tree
        var viewElements: [(view: UIView, gestures: [String], isGestureContainer: Bool)] = []
        walkViewHierarchyForInteractive(view: walkRoot, maxElements: maxElements, into: &viewElements)

        // Phase 2b: Walk topmost VC's view if it's not already covered.
        // SwiftUI .sheet() presents content that may not be in the window's subview tree.
        if rootView == nil, let topVC = UIWindow.pepper_topViewController {
            let topView = topVC.view!
            let alreadyCovered = topView.isDescendant(of: walkRoot)
            if !alreadyCovered {
                walkViewHierarchyForInteractive(view: topView, maxElements: maxElements, into: &viewElements)
            }
        }

        // Phase 2→3: Merge & dedup — add view-hierarchy elements not already covered
        for (view, gestures, gestureContainer) in viewElements {
            guard results.count < maxElements else { break }
            let viewFrame = view.convert(view.bounds, to: nil)
            guard viewFrame != .zero, viewFrame.width > 0, viewFrame.height > 0 else { continue }

            // Skip Pepper overlay elements
            let className = String(describing: type(of: view))
            if PepperClassFilter.isInternalClass(className) { continue }

            // Dedup: ObjectIdentifier for views + frame overlap for other elements
            guard !dedup.isDuplicate(frame: viewFrame, view: view) else { continue }

            let label = view.accessibilityLabel
            let labeled = label != nil && !label!.isEmpty
            let isControl = view is UIControl
            let controlType = classifyControlType(view)
            let source = isControl ? "uiControl" : "gestureRecognizer"
            var iconName: String? = nil
            let heuristic = labeled ? nil : inferHeuristic(
                className: className,
                frame: viewFrame,
                gestures: gestures,
                label: label,
                view: view,
                iconName: &iconName
            )

            let labelSource: String? = labeled
                ? Self.classifyLabelSource(view: view, label: label!)
                : nil
            results.append(PepperInteractiveElement(
                className: className,
                label: label,
                center: CGPoint(x: viewFrame.midX, y: viewFrame.midY),
                frame: viewFrame,
                labeled: labeled,
                source: source,
                gestures: gestures,
                isControl: isControl,
                controlType: controlType,
                hitReachable: true,
                heuristic: heuristic,
                iconName: iconName,
                traits: [],
                labelSource: labelSource
            ))
            if gestureContainer {
                results[results.count - 1].gestureContainerFrame = viewFrame
            }
            dedup.markSeen(frame: viewFrame, view: view)
        }

        // Phase 3: CALayer-based discovery for SwiftUI custom controls.
        // SwiftUI views with .onTapGesture and custom shapes (e.g., custom toggles)
        // don't create UIView children or UIKit gesture recognizers, but their
        // shapes may render as individual CALayers with distinctive properties.
        discoverLayerControls(in: walkRoot, window: window, dedup: &dedup, results: &results, maxElements: maxElements)

        // Phase 4: Hit-test filter + visibility scoring + scroll context enrichment
        if hitTestFilter {
            for i in results.indices {
                // Layer-sourced elements bypass hit-test — SwiftUI routes taps
                // internally (not through UIKit's hit-test chain), so ImageLayers
                // for .onTapGesture buttons always fail UIKit hit-test.
                if results[i].source == "layer" { continue }
                let (reachable, vis) = checkVisibility(for: results[i], in: window)
                results[i].hitReachable = reachable
                results[i].visible = vis
            }
        }
        for i in results.indices {
            results[i].scrollContext = scrollContext(forElementFrame: results[i].frame)
        }

        // Phase 5: Enrich with view controller context
        for i in results.indices {
            if let hitView = window.hitTest(results[i].center, with: nil),
               let vc = findOwningViewController(for: hitView) {
                results[i].viewController = String(describing: type(of: vc))
                results[i].presentationContext = presentationContext(of: vc)
            }
        }

        truncated = truncated || results.count >= maxElements

        // Only cache for default-root calls
        if rootView == nil {
            lastInteractiveTruncated = truncated
            cachedInteractive = (gen: cacheGeneration, elements: results, truncated: truncated, time: CFAbsoluteTimeGetCurrent())
        }
        return results
    }

    // MARK: - Element Deduplication

    /// Tracks seen elements for deduplication across discovery phases.
    /// Uses ObjectIdentifier for view-backed elements (definitive) and frame overlap
    /// for accessibility/layer elements (80% area intersection threshold).
    struct ElementDedup {
        var seenViewIDs = Set<ObjectIdentifier>()
        var coveredFrames: [CGRect] = []

        /// Check if a new element at the given frame is a duplicate of an already-seen element.
        func isDuplicate(frame: CGRect, view: UIView? = nil) -> Bool {
            // ObjectIdentifier check for view-backed elements — definitive
            if let view = view, seenViewIDs.contains(ObjectIdentifier(view)) {
                return true
            }

            let area = frame.width * frame.height
            // For zero-size frames: center proximity fallback
            if area < 1 {
                return coveredFrames.contains { existing in
                    abs(existing.midX - frame.midX) < 5 && abs(existing.midY - frame.midY) < 5
                }
            }

            // Frame overlap: intersection area > 80% of BOTH elements.
            // Using only the smaller area caused cells to dedup with buttons inside them.
            for existing in coveredFrames {
                let intersection = existing.intersection(frame)
                guard !intersection.isNull else { continue }
                let intersectionArea = intersection.width * intersection.height
                let existingArea = existing.width * existing.height
                let largerArea = max(existingArea, area)
                if largerArea > 0 && intersectionArea / largerArea > 0.8 {
                    return true
                }
            }
            return false
        }

        /// Mark an element as seen.
        mutating func markSeen(frame: CGRect, view: UIView? = nil) {
            if let view = view {
                seenViewIDs.insert(ObjectIdentifier(view))
            }
            coveredFrames.append(frame)
        }
    }

    // MARK: - Interactive Discovery Helpers

    /// Recursively walk the UIView hierarchy collecting interactive views.
    private func walkViewHierarchyForInteractive(view: UIView, maxElements: Int, into results: inout [(view: UIView, gestures: [String], isGestureContainer: Bool)]) {
        guard results.count < maxElements else { return }
        guard !view.isHidden, view.alpha > 0.01 else { return }

        if isViewInteractive(view) {
            let gestures = extractGestureTypes(from: view)
            results.append((view: view, gestures: gestures, isGestureContainer: isGestureContainer(view)))
        }


        for subview in view.subviews {
            guard results.count < maxElements else { return }
            walkViewHierarchyForInteractive(view: subview, maxElements: maxElements, into: &results)
        }
    }

    /// Walk the CALayer sublayer tree looking for interactive controls rendered
    /// without UIView backing. SwiftUI custom controls (custom toggles, sliders,
    /// checkboxes) using .onTapGesture render shapes via CALayer only.
    /// Detects toggles, sliders, and checkboxes by shape/size/sublayer heuristics.
    private func discoverLayerControls(in view: UIView, window: UIWindow, dedup: inout ElementDedup, results: inout [PepperInteractiveElement], maxElements: Int) {
        let screenBounds = UIScreen.main.bounds
        // Collect existing interactive frames — ImageLayer icon_buttons inside these
        // are decorative (e.g., like/share icons inside post cells, gear icons inside
        // pet cards). Only toggles/sliders/checkboxes bypass this filter.
        let existingFrames = results.map { $0.frame }
        walkLayerTree(layer: view.layer, window: window, screenBounds: screenBounds, dedup: &dedup, results: &results, existingInteractiveFrames: existingFrames, maxElements: maxElements, depth: 0)
    }

    private func walkLayerTree(layer: CALayer, window: UIWindow, screenBounds: CGRect, dedup: inout ElementDedup, results: inout [PepperInteractiveElement], existingInteractiveFrames: [CGRect], maxElements: Int, depth: Int) {
        guard results.count < maxElements, depth < 40 else { return }

        if let heuristic = classifyLayerControl(layer) {
            let bounds = layer.bounds
            let centerInLayer = CGPoint(x: bounds.midX, y: bounds.midY)
            let centerInWindow = layer.convert(centerInLayer, to: window.layer)

            let frameInWindow = CGRect(
                x: centerInWindow.x - bounds.width / 2,
                y: centerInWindow.y - bounds.height / 2,
                width: bounds.width,
                height: bounds.height
            )

            // Skip ImageLayer icon_buttons inside existing interactive elements
            // (decorative icons in cells/cards). Toggles/sliders/checkboxes are
            // real controls and bypass this filter.
            let isDecorativeIcon = heuristic == "icon_button" && existingInteractiveFrames.contains { $0.contains(centerInWindow) }

            if !isDecorativeIcon && !dedup.isDuplicate(frame: frameInWindow) && screenBounds.contains(centerInWindow) {
                results.append(PepperInteractiveElement(
                    className: String(describing: type(of: layer)),
                    label: nil,
                    center: centerInWindow,
                    frame: frameInWindow,
                    labeled: false,
                    source: "layer",
                    gestures: ["tap"],
                    isControl: false,
                    controlType: nil,
                    hitReachable: true,
                    heuristic: heuristic,
                    iconName: nil,
                    traits: [],
                    labelSource: nil
                ))
                dedup.markSeen(frame: frameInWindow)
            }
        }

        // Recurse into sublayers
        guard let sublayers = layer.sublayers else { return }
        for sublayer in sublayers {
            walkLayerTree(layer: sublayer, window: window, screenBounds: screenBounds, dedup: &dedup, results: &results, existingInteractiveFrames: existingInteractiveFrames, maxElements: maxElements, depth: depth + 1)
        }
    }

    /// Classify a CALayer as an interactive control based on shape heuristics.
    /// Returns a heuristic label ("toggle", "slider", "checkbox") or nil.
    private func classifyLayerControl(_ layer: CALayer) -> String? {
        let bounds = layer.bounds
        let cr = layer.cornerRadius
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return nil }

        // Small ImageLayers (16-30pt, square-ish) are potential icon buttons.
        // SwiftUI icons rendered via Image() have no backgroundColor/border —
        // they're pure image content. Hit-test filter (Phase 4) weeds out
        // decorative images that aren't tap targets.
        let className = String(describing: type(of: layer))
        if className.contains("ImageLayer")
            && w >= 16 && w <= 30 && h >= 16 && h <= 30
            && abs(w - h) < 6 {
            return "icon_button"
        }

        let hasFill = layer.backgroundColor != nil || layer.borderWidth > 0
        guard hasFill else { return nil }

        let isCapsule = cr > 0 && abs(cr - h / 2) < 3

        // Toggle: capsule shape, wider than tall, interactive dimensions.
        // Standard UISwitch: 51x31. Custom toggles vary (~30pt).
        // Raised min height from 18→26 to exclude small decorative pills (23pt).
        if isCapsule && w >= 35 && w <= 100 && h >= 26 && h <= 50 && w > h {
            // Higher confidence if layer has a circular sublayer (the knob)
            if let sublayers = layer.sublayers, sublayers.contains(where: { sub in
                let sb = sub.bounds
                return sb.width > 8 && abs(sb.width - sb.height) < 3
                    && abs(sub.cornerRadius - sb.width / 2) < 2
            }) {
                return "toggle"
            }
            // Still a toggle candidate even without visible knob sublayer —
            // SwiftUI may flatten the layer tree in some rendering paths.
            return "toggle"
        }

        // Slider track: very wide, thin, fully rounded ends.
        // Track dimensions: width > 100, height 3-12, capsule shape.
        if isCapsule && w > 100 && h >= 3 && h <= 12 {
            return "slider"
        }

        // Checkbox: small square-ish with rounded corners and border.
        // Dimensions 16-34 x 16-34, aspect ratio near 1:1.
        if w >= 16 && w <= 34 && h >= 16 && h <= 34
            && abs(w - h) < 4
            && cr >= 2 && cr <= 10
            && layer.borderWidth > 0 {
            return "checkbox"
        }

        return nil
    }

    /// Check if a UIView is interactive based on its type and gesture recognizers.
    private func isViewInteractive(_ view: UIView) -> Bool {
        // UIControl subclasses (UIButton, UISwitch, UISegmentedControl, etc.)
        if view is UIControl { return true }

        // Collection/table view cells are tappable via parent view selection.
        // SwiftUI List/ForEach backs into UICollectionView; cells aren't UIControls
        // but are interactive targets for row selection and navigation.
        if view is UICollectionViewCell || view is UITableViewCell { return true }

        // Check gesture recognizers for taps and long presses
        if let recognizers = view.gestureRecognizers {
            for recognizer in recognizers where recognizer.isEnabled {
                let className = String(describing: type(of: recognizer))

                // Standard UIKit tap/longPress gestures
                if recognizer is UITapGestureRecognizer { return true }
                if recognizer is UILongPressGestureRecognizer {
                    // Exclude scroll view's default long press
                    if view is UIScrollView { continue }
                    return true
                }

                // SwiftUI private gesture classes
                if className.contains("ButtonGesture") || className.contains("TapGesture") {
                    return true
                }
            }
        }

        // Class name heuristic: views named *Button* with user interaction
        if view.isUserInteractionEnabled {
            let className = String(describing: type(of: view))
            if className.contains("Button") && !(view is UIScrollView) {
                return true
            }
            // Known interactive visual view types (Lottie animations with .onTapGesture)
            if view.bounds.width <= 80 && view.bounds.height <= 80 {
                if className.contains("AnimationView") || className.contains("Lottie") {
                    return true
                }
            }
        }

        return false
    }

    /// Check if a view is a gesture container (not a UIControl/cell) that uses
    /// SwiftUI `.contentShape().onTapGesture {}` to make a container tappable.
    /// These containers' child Text elements should be grouped, not separate.
    private func isGestureContainer(_ view: UIView) -> Bool {
        if view is UIControl { return false }
        if view is UICollectionViewCell || view is UITableViewCell { return false }
        guard let recognizers = view.gestureRecognizers else { return false }
        return recognizers.contains { r in
            guard r.isEnabled else { return false }
            if r is UITapGestureRecognizer { return true }
            let cn = String(describing: type(of: r))
            return cn.contains("ButtonGesture") || cn.contains("TapGesture")
        }
    }
}