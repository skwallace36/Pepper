import UIKit
import os

/// Owns the "map" mode introspection pipeline — the engine behind the `look` command.
///
/// Takes a PepperCommand and returns structured screen state: interactive elements
/// grouped into rows, non-interactive text, scroll containers, keyboard state,
/// and system dialog detection.
///
/// Extracted from IntrospectHandler so the handler delegates to this independent type
/// instead of sharing internals via extensions.
struct MapModeIntrospector {
    var logger: Logger { PepperLogger.logger(category: "introspect") }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func run(_ command: PepperCommand) -> PepperResponse {
        // Layout settle: force pending CoreAnimation and UIKit layout to complete.
        // CATransaction.flush() synchronously commits all pending layer changes.
        // The RunLoop spin lets SwiftUI propagate any state changes triggered by
        // the flush (e.g., @State updates that queue new layout passes).
        CATransaction.flush()
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.016))

        let bridge = PepperSwiftUIBridge.shared
        let bandSize: CGFloat = CGFloat(command.params?["band"]?.intValue ?? 40)
        let detailMode = command.params?["detail"]?.stringValue ?? "summary"
        let isSummary = detailMode != "full"
        let enableOCR = command.params?["ocr"]?.boolValue ?? false

        // Detect topmost presented modal/sheet. For full-screen modals, scope
        // element collection to that VC's view subtree. For sheets (half-height
        // overlays), collect from the full window since both parent and sheet
        // content are visible and interactive — hit-test filtering handles
        // which elements are actually reachable.
        let modalRootView: UIView? = {
            guard let rootVC = UIWindow.pepper_keyWindow?.rootViewController else { return nil }
            var vc = rootVC
            while let presented = vc.presentedViewController {
                vc = presented
            }
            guard vc !== rootVC else { return nil }
            // Only scope for full-screen modals; sheets leave parent visible
            let isFullScreen =
                vc.modalPresentationStyle == .fullScreen
                || vc.modalPresentationStyle == .overFullScreen
                || vc.modalPresentationStyle == .overCurrentContext
            if isFullScreen { return vc.view }
            // Also scope if the presented view covers ≥90% of the screen
            let vcFrame = vc.view.convert(vc.view.bounds, to: nil)
            let screenH = UIScreen.main.bounds.height
            if vcFrame.height >= screenH * 0.9 { return vc.view }
            return nil  // Sheet — don't scope, collect from full window
        }()

        // Phase 1: Collect all accessibility elements (labeled), depth-filtered.
        // When scoped to a modal root, pass alreadyScoped to skip re-collecting
        // from the same VC inside annotateDepth (avoids a redundant tree walk).
        let accElements = bridge.annotateDepth(
            bridge.collectAccessibilityElements(from: modalRootView),
            alreadyScoped: modalRootView != nil)

        // Phase 2: Collect all interactive elements (labeled + unlabeled, with hit-test)
        let interactiveElements = bridge.discoverInteractiveElements(
            rootView: modalRootView, hitTestFilter: true, maxElements: 500)

        // Build a label-keyed lookup for O(1) access to accessibility values.
        // The merge loop previously did a linear scan of all accElements per
        // interactive element — O(n*m). Grouping by label first reduces the
        // inner search to the (typically 1-2) elements sharing the same label.
        var accByLabel: [String: [PepperAccessibilityElement]] = [:]
        for acc in accElements {
            guard let label = acc.label else { continue }
            accByLabel[label, default: []].append(acc)
        }

        // Phase 3: Merge into a unified list, deduplicated by center proximity
        var mergedInteractive: [MapElement] = []
        var mergedNonInteractive: [MapElement] = []
        var coveredCenters = SpatialHash(cellSize: 5)

        // Add interactive elements first (they have hit_reachable info)
        let screenBounds = UIScreen.main.bounds
        for elem in interactiveElements {
            // Accessibility-sourced buttons are trusted even when hit-test fails —
            // SwiftUI overlays (FABs, floating buttons) often fail UIKit hit-test
            // because they're rendered via internal gesture routing, not the view tree.
            let trustA11y = !elem.hitReachable && elem.source == "accessibility" && elem.traits.contains("button")
            guard elem.hitReachable || trustA11y else { continue }
            guard elem.frame != .zero, elem.frame.width > 0 else { continue }
            // Skip off-screen elements (horizontal scroll content, etc.)
            guard screenBounds.intersects(elem.frame) else { continue }
            // Skip decorative thin bars/lines (< 5pt tall or wide)
            if elem.frame.height < 5 || elem.frame.width < 5 { continue }
            // Skip dismiss gesture recognizers: elements whose frame area exceeds
            // 2x the screen area are full-screen gesture handlers (e.g. UIDimmingView
            // dismiss tap targets) that leak into the element list. Remove unconditionally.
            let elemArea = elem.frame.width * elem.frame.height
            let screenArea = screenBounds.width * screenBounds.height
            if elemArea > screenArea * 2.0 { continue }
            // Skip full-screen container elements (layout wrappers, > 80% screen area)
            if elemArea > screenArea * 0.8, elem.label == nil { continue }
            // Skip scroll bar indicators (adjustable trait, thin bars)
            if elem.traits.contains("adjustable"),
                let label = elem.label,
                label.lowercased().contains("scroll bar")
            {
                continue
            }
            // Skip sheet grabber handles (accessibility artifacts)
            if let label = elem.label, label == "Sheet Grabber" {
                continue
            }
            // Skip center duplicates (same element found by multiple discovery phases).
            // Text inputs are never deduped — a UITextField behind a button at the
            // same center is a different element (e.g. sheet text field vs background cell).
            let isTextInput =
                elem.controlType == "textField" || elem.controlType == "textView" || elem.controlType == "searchField"
            if !isTextInput {
                guard !coveredCenters.contains(x: elem.center.x, y: elem.center.y) else { continue }
            }
            // Try to find accessibility value for this element via label-keyed dictionary
            var accValue: String? = {
                guard let label = elem.label,
                      let candidates = accByLabel[label] else { return nil }
                return pepperSanitizeLabel(
                    candidates.first(where: {
                        abs($0.frame.midX - elem.center.x) < 15 && abs($0.frame.midY - elem.center.y) < 15
                    })?.value)
            }()

            // For text fields/views, read the actual .text value from the UIKit view.
            // Accessibility value may not reflect the typed content; this gives us
            // the live text. For secure text fields, report masked bullets.
            if isTextInput, let window = UIWindow.pepper_keyWindow {
                let hitView = window.hitTest(elem.center, with: nil)
                if let tf = hitView as? UITextField ?? hitView?.superview as? UITextField {
                    if tf.isSecureTextEntry {
                        if let text = tf.text, !text.isEmpty {
                            accValue = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"
                        }
                    } else if let text = tf.text, !text.isEmpty {
                        accValue = text
                    }
                } else if let tv = hitView as? UITextView ?? hitView?.superview as? UITextView {
                    if tv.isSecureTextEntry {
                        if let text = tv.text, !text.isEmpty {
                            accValue = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"
                        }
                    } else if let text = tv.text, !text.isEmpty {
                        accValue = text
                    }
                }
            }

            // Determine element type: controlType > button trait > heuristic > default
            let resolvedType: String = {
                if let ct = elem.controlType {
                    // Normalize generic "control" to "button" for the builder
                    return ct == "control" ? "button" : ct
                }
                if elem.traits.contains("button") { return "button" }
                // Promote to "button" if heuristic indicates an actionable element
                if let h = elem.heuristic, h.hasSuffix("_button") || h == "toggle" { return "button" }
                if elem.label != nil { return "button" }
                return "element"
            }()
            // Check accessibility traits for selected state
            let isSelected = elem.traits.contains("selected") ? true : nil

            var mapElem = MapElement(
                label: elem.label,
                type: resolvedType,
                center: elem.center,
                frame: elem.frame,
                hitReachable: elem.hitReachable || trustA11y,
                visible: elem.visible,
                heuristic: elem.heuristic,
                iconName: elem.iconName,
                isInteractive: true,
                value: accValue,
                traits: elem.traits,
                scrollContext: elem.scrollContext,
                labelSource: elem.labelSource,
                gestureContainerFrame: elem.gestureContainerFrame
            )
            mapElem.selected = isSelected
            mergedInteractive.append(mapElem)
            coveredCenters.insert(x: elem.center.x, y: elem.center.y)
        }
        // Add non-interactive accessibility elements (staticText, images, etc.)
        // Filter out noise: single chars ("#", "·", ","), chart axis labels,
        // and pure whitespace that pollute the builder's assertion palette.
        for acc in accElements {
            guard acc.frame != .zero, acc.frame.width > 0 else { continue }
            guard !acc.isInteractive else { continue }
            guard acc.hitReachable else { continue }
            guard let label = acc.label, label.count >= 2 else { continue }
            guard screenBounds.intersects(acc.frame) else { continue }
            // Skip chart axis labels: "12 AM", "6 PM", pure numbers like "0 1 2 3 4 5"
            let trimmed = label.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Skip strings that are just space-separated single digits (chart axes)
            let isDigitAxis =
                trimmed.allSatisfy { $0.isNumber || $0 == " " }
                && trimmed.contains(" ")
            if isDigitAxis { continue }
            // Skip chart time axis labels: "12 AM", "6 PM", "12AM", "6PM"
            if isChartTimeLabel(trimmed) { continue }
            // Skip short measurement labels: "0m", "60min", "0.1mi"
            if trimmed.count <= 6, trimmed.first?.isNumber == true,
                trimmed.hasSuffix("m") || trimmed.hasSuffix("mi") || trimmed.hasSuffix("min")
                    || trimmed.hasSuffix("hr") || trimmed.hasSuffix("lb") || trimmed.hasSuffix("kg")
            {
                continue
            }

            let centerX = acc.frame.midX
            let centerY = acc.frame.midY

            // Skip center duplicates
            guard !coveredCenters.contains(x: centerX, y: centerY) else { continue }

            // Compute visibility for text elements.
            // Skip expensive grid hit-test when annotateDepth already confirmed
            // the element via fingerprint set membership — it's known visible.
            var textVisible: Float = -1
            if acc.depthConfirmed {
                textVisible = 1.0
            } else if let window = UIWindow.pepper_keyWindow {
                textVisible = bridge.checkFrameVisibility(frame: acc.frame, in: window)
            }

            mergedNonInteractive.append(
                MapElement(
                    label: label,
                    type: acc.type,
                    center: CGPoint(x: centerX, y: centerY),
                    frame: acc.frame,
                    hitReachable: false,
                    visible: textVisible,
                    heuristic: nil,
                    iconName: nil,
                    isInteractive: false,
                    value: acc.value,
                    traits: [],
                    scrollContext: nil,
                    labelSource: nil
                ))
            coveredCenters.insert(x: centerX, y: centerY)
        }

        let tabBarProvider = PepperAppConfig.shared.tabBarProvider
        var tabTitles = tabBarProvider?.visibleTabTitles() ?? []
        var tabNamesList = tabBarProvider?.tabNames() ?? []
        var selectedTab = tabBarProvider?.selectedTabName()

        // Generic mode fallback: derive tab info from standard UITabBarController
        if tabTitles.isEmpty, tabBarProvider == nil,
            let tabBarVC = UIWindow.pepper_tabBarController as? UITabBarController,
            let vcs = tabBarVC.viewControllers, !vcs.isEmpty
        {
            tabTitles = vcs.enumerated().map { i, vc in
                vc.tabBarItem.title ?? vc.title ?? "Tab \(i)"
            }
            tabNamesList = tabTitles.map {
                $0.lowercased().replacingOccurrences(of: " ", with: "_")
            }
            if let sel = tabBarVC.selectedViewController {
                selectedTab = (sel.tabBarItem.title ?? sel.title)?
                    .lowercased().replacingOccurrences(of: " ", with: "_")
            }
        }
        let screenH = screenBounds.height
        let screenW = screenBounds.width
        let tabBarMinY: CGFloat = screenH - 60  // Tab bar is always in the bottom ~60pt

        // Phase 4a: Label tab bar items from tab bar provider or UITabBarController.
        // UITabBarButton labels aren't in the accessibility tree; use tab item titles.
        // Strategy: use provider's tabItemFrames for authoritative positions, then
        // match to discovered elements or create synthetic ones for occluded tabs.
        if !tabTitles.isEmpty, let window = UIWindow.pepper_keyWindow {
            let providerFrames: [(center: CGPoint, frame: CGRect)]
            if let provider = tabBarProvider {
                providerFrames = provider.tabItemFrames(in: window)
            } else if let tabBar = (UIWindow.pepper_tabBarController as? UITabBarController)?.tabBar {
                // Generic mode: extract frames from standard UITabBar buttons
                providerFrames = tabBar.subviews
                    .filter { String(describing: type(of: $0)).contains("TabBarButton") }
                    .sorted { $0.frame.origin.x < $1.frame.origin.x }
                    .map { button in
                        let center = button.convert(
                            CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
                        let frame = button.convert(button.bounds, to: window)
                        return (center: center, frame: frame)
                    }
            } else {
                providerFrames = []
            }

            if providerFrames.count == tabTitles.count {
                // Provider knows exact tab positions — match or create elements.
                for (order, tabFrame) in providerFrames.enumerated() where order < tabTitles.count {
                    let isTabSelected: Bool? = {
                        guard let sel = selectedTab, order < tabNamesList.count else { return nil }
                        return tabNamesList[order] == sel ? true : nil
                    }()

                    // Find existing discovered element near this tab position
                    let matchIdx = mergedInteractive.indices.first { i in
                        let e = mergedInteractive[i]
                        return abs(e.center.x - tabFrame.center.x) < 20
                            && abs(e.center.y - tabFrame.center.y) < 20
                            && e.frame.width < 120
                    }

                    if let idx = matchIdx {
                        // Relabel existing element
                        var tabElem = MapElement(
                            label: tabTitles[order], type: mergedInteractive[idx].type,
                            center: mergedInteractive[idx].center, frame: mergedInteractive[idx].frame,
                            hitReachable: mergedInteractive[idx].hitReachable,
                            visible: mergedInteractive[idx].visible,
                            heuristic: "tab_button", iconName: mergedInteractive[idx].iconName,
                            isInteractive: true, value: mergedInteractive[idx].value,
                            traits: mergedInteractive[idx].traits,
                            scrollContext: mergedInteractive[idx].scrollContext,
                            labelSource: "tab"
                        )
                        tabElem.selected = isTabSelected
                        mergedInteractive[idx] = tabElem
                    } else {
                        // Tab was occluded by content — create synthetic element
                        var tabElem = MapElement(
                            label: tabTitles[order], type: "button",
                            center: tabFrame.center, frame: tabFrame.frame,
                            hitReachable: true, visible: 1.0,
                            heuristic: "tab_button", iconName: nil,
                            isInteractive: true, value: nil,
                            traits: ["button"],
                            scrollContext: nil,
                            labelSource: "tab"
                        )
                        tabElem.selected = isTabSelected
                        mergedInteractive.append(tabElem)
                    }
                }
            } else {
                // No provider frames — fall back to candidate matching.
                let candidates = mergedInteractive.indices.filter { i in
                    let e = mergedInteractive[i]
                    guard e.center.y > tabBarMinY else { return false }
                    guard e.frame.width < 120, e.frame.height < 120 else { return false }
                    return true
                }.sorted(by: { mergedInteractive[$0].center.x < mergedInteractive[$1].center.x })

                let tabIndices: [Int]
                if candidates.count >= tabTitles.count {
                    let medianY = candidates.map { mergedInteractive[$0].center.y }
                        .sorted()[candidates.count / 2]
                    let yBand = candidates.filter { i in
                        abs(mergedInteractive[i].center.y - medianY) < 15
                    }
                    let minX = yBand.map { mergedInteractive[$0].center.x }.min() ?? 0
                    let maxX = yBand.map { mergedInteractive[$0].center.x }.max() ?? 0
                    tabIndices = (maxX - minX > screenW * 0.6) ? yBand : []
                } else {
                    tabIndices = []
                }

                for (order, idx) in tabIndices.enumerated() where order < tabTitles.count {
                    let isTabSelected: Bool? = {
                        guard let sel = selectedTab, order < tabNamesList.count else { return nil }
                        return tabNamesList[order] == sel ? true : nil
                    }()

                    var tabElem = MapElement(
                        label: tabTitles[order], type: mergedInteractive[idx].type,
                        center: mergedInteractive[idx].center, frame: mergedInteractive[idx].frame,
                        hitReachable: mergedInteractive[idx].hitReachable,
                        visible: mergedInteractive[idx].visible,
                        heuristic: "tab_button", iconName: mergedInteractive[idx].iconName,
                        isInteractive: true, value: mergedInteractive[idx].value,
                        traits: mergedInteractive[idx].traits,
                        scrollContext: mergedInteractive[idx].scrollContext,
                        labelSource: "tab"
                    )
                    tabElem.selected = isTabSelected
                    mergedInteractive[idx] = tabElem
                }
            }
        }

        // Filter non-interactive text behind the tab bar (scroll content extends
        // into the safe area but is visually occluded by the opaque tab bar).
        // Runs after Phase 4a so tab_button heuristic is available. Only filter
        // when tab bar items were actually labeled — on full-screen presentations
        // (maps, sheets) the tab bar is hidden but the provider's tabTitles may
        // still be populated from the previous screen.
        let hasTabBarElements = mergedInteractive.contains { $0.heuristic == "tab_button" }
        if hasTabBarElements {
            mergedNonInteractive.removeAll { $0.center.y > tabBarMinY }
        }

        // Snapshot all NI text before pipeline phases start claiming/removing entries.
        // The working array (mergedNonInteractive) is mutated during card probing,
        // text adoption, and container cleanup. The snapshot preserves the full set
        // for serialization — every discovered text stays in the output as a coverage
        // layer and for test assertions (has_text), even when grouped into cards/cells.
        let allDiscoveredText = mergedNonInteractive

        // Phase 4a½: Group gesture container children.
        // SwiftUI `.contentShape().onTapGesture {}` containers appear as unlabeled
        // interactive elements with their child texts as separate NI entries.
        // Must run before Phase 4b so text adoption doesn't steal individual texts.
        groupGestureContainerChildren(
            &mergedInteractive, nonInteractive: &mergedNonInteractive, screenBounds: screenBounds)

        // Phase 4a¾: Probe uncovered text for tappable card containers.
        // SwiftUI cards with .contentShape().onTapGesture{} are invisible to
        // gesture recognizer discovery. Detect them via hit-test + ancestor walk
        // for views with cornerRadius + clipping (from .clipShape()).
        probeUncoveredTextForCards(
            &mergedInteractive, nonInteractive: &mergedNonInteractive, screenBounds: screenBounds)

        // Phase 4b: Adopt text labels for remaining unlabeled interactive elements.
        // Pass 1: Text center inside element frame (with 5pt tolerance).
        // Pass 2: Label text above text fields (form pattern).
        // Pass 3: Row-adjacent text to the left of small controls (settings pattern).
        // Process cells first (by area descending) so they claim primary labels
        // before small icons can steal text via Pass 3.
        // Skip content_area containers (large scroll wrappers) — these are infrastructure
        // that Phase 4c removes when unlabeled. Allow unlabeled_interactive through: if
        // text adoption succeeds, the element is a real button (e.g. thumbnail in a sheet).
        // If it stays unlabeled, Phase 4c still removes it.
        let unlabeledOrder = mergedInteractive.indices
            .filter {
                guard mergedInteractive[$0].label == nil else { return false }
                let h = mergedInteractive[$0].heuristic
                let isCell = mergedInteractive[$0].type == "cell"
                if !isCell && h == "content_area" { return false }
                return true
            }
            .sorted { a, b in
                let aCell = mergedInteractive[a].type == "cell"
                let bCell = mergedInteractive[b].type == "cell"
                if aCell != bCell { return aCell }
                let aArea = mergedInteractive[a].frame.width * mergedInteractive[a].frame.height
                let bArea = mergedInteractive[b].frame.width * mergedInteractive[b].frame.height
                return aArea > bArea
            }
        // Build spatial index of non-interactive text by Y-band for O(1) lookup.
        // Key = Y coordinate rounded to 10pt bands. Each band collects text indices.
        let textIndex = SpatialTextIndex(elements: mergedNonInteractive, bandSize: 10)
        // Track consumed NI indices — can't remove during iteration because the
        // spatial index holds original indices that would become stale after removal.
        var consumedNI = Set<Int>()

        for i in unlabeledOrder {
            guard mergedInteractive[i].label == nil else { continue }
            let iFrame = mergedInteractive[i].frame.insetBy(dx: -5, dy: -5)
            let isCell = mergedInteractive[i].type == "cell"
            var bestIdx: Int?
            var bestScore: CGFloat = .greatestFiniteMagnitude
            // Pass 1: Text center inside element frame
            for j in textIndex.candidates(inYRange: iFrame.minY...iFrame.maxY) {
                guard !consumedNI.contains(j) else { continue }
                guard let txt = mergedNonInteractive[j].label, txt.count >= 2 else { continue }
                let tc = mergedNonInteractive[j].center
                guard iFrame.contains(tc) else { continue }
                let score: CGFloat =
                    isCell
                    ? tc.y
                    : hypot(tc.x - mergedInteractive[i].center.x, tc.y - mergedInteractive[i].center.y)
                if score < bestScore {
                    bestScore = score
                    bestIdx = j
                }
            }
            // Pass 2: For text fields, find label text above (within 70pt).
            if bestIdx == nil
                && (mergedInteractive[i].type == "textField" || mergedInteractive[i].type == "searchField"
                    || mergedInteractive[i].type == "textView")
            {
                let ef = mergedInteractive[i].frame
                for j in textIndex.candidates(inYRange: (ef.minY - 70)...ef.minY) {
                    guard !consumedNI.contains(j) else { continue }
                    guard let txt = mergedNonInteractive[j].label, txt.count >= 2 else { continue }
                    let tc = mergedNonInteractive[j].center
                    guard tc.y < ef.minY, ef.minY - tc.y < 70 else { continue }
                    guard tc.x >= ef.minX - 20 else { continue }
                    let dist = ef.minY - tc.y
                    if dist < bestScore {
                        bestScore = dist
                        bestIdx = j
                    }
                }
            }
            // Pass 3: For small controls, find text to the left in same Y-band.
            // Max 150pt distance to avoid adopting far-away title text (e.g. page
            // title being adopted by an icon button at the opposite edge).
            if bestIdx == nil && mergedInteractive[i].frame.width < 120 {
                let ec = mergedInteractive[i].center
                for j in textIndex.candidates(inYRange: (ec.y - 20)...(ec.y + 20)) {
                    guard !consumedNI.contains(j) else { continue }
                    guard let txt = mergedNonInteractive[j].label, txt.count >= 2 else { continue }
                    let tc = mergedNonInteractive[j].center
                    guard abs(tc.y - ec.y) < 20, tc.x < ec.x, ec.x - tc.x < 150 else { continue }
                    let dist = ec.x - tc.x
                    if dist < bestScore {
                        bestScore = dist
                        bestIdx = j
                    }
                }
            }
            // Pass 4: For buttons < 200pt wide, find text directly below.
            if bestIdx == nil && mergedInteractive[i].frame.width < 200 {
                let ef = mergedInteractive[i].frame
                for j in textIndex.candidates(inYRange: ef.maxY...(ef.maxY + 20)) {
                    guard !consumedNI.contains(j) else { continue }
                    guard let txt = mergedNonInteractive[j].label, txt.count >= 2 else { continue }
                    let tc = mergedNonInteractive[j].center
                    guard tc.y > ef.maxY, tc.y - ef.maxY < 20 else { continue }
                    guard tc.x >= ef.minX - 10, tc.x <= ef.maxX + 10 else { continue }
                    let dist = tc.y - ef.maxY
                    if dist < bestScore {
                        bestScore = dist
                        bestIdx = j
                    }
                }
            }
            if let j = bestIdx, let txt = mergedNonInteractive[j].label {
                consumedNI.insert(j)
                // Clear heuristics that are only meaningful for unlabeled elements —
                // now that we have a text label, these are misleading in the builder.
                let cleanHeuristic: String? = {
                    switch mergedInteractive[i].heuristic {
                    case "content_area", "unlabeled_interactive", "icon_button":
                        return nil
                    default:
                        return mergedInteractive[i].heuristic
                    }
                }()
                mergedInteractive[i] = MapElement(
                    label: txt, type: mergedInteractive[i].type,
                    center: mergedInteractive[i].center, frame: mergedInteractive[i].frame,
                    hitReachable: mergedInteractive[i].hitReachable,
                    visible: mergedInteractive[i].visible,
                    heuristic: cleanHeuristic,
                    iconName: mergedInteractive[i].iconName,
                    isInteractive: true, value: mergedInteractive[i].value,
                    traits: mergedInteractive[i].traits,
                    scrollContext: mergedInteractive[i].scrollContext,
                    labelSource: "text"
                )
            }
        }
        // Remove consumed NI elements in reverse order to preserve indices
        for j in consumedNI.sorted().reversed() {
            mergedNonInteractive.remove(at: j)
        }

        // Phase 4c: Remove unlabeled noise:
        // - Unlabeled cells (spacers)
        // - Unlabeled content_area / unlabeled_interactive heuristics
        //   (non-actionable containers, not useful in builder palette)
        // - Unlabeled elements fully contained within a labeled element
        // Exclude oversized frames (>50% screen area) from containment check —
        // system overlays like UIDimmingView ("dismiss popup") cover the entire
        // window and would swallow all unlabeled elements inside sheets.
        // Build spatial index of labeled frames for O(1) containment checks
        let labeledFrameIndex = SpatialFrameIndex(
            frames: mergedInteractive.compactMap { elem -> CGRect? in
                guard elem.label != nil else { return nil }
                let area = elem.frame.width * elem.frame.height
                if area > screenBounds.width * screenBounds.height * 0.5 { return nil }
                return elem.frame
            },
            cellSize: 40
        )
        mergedInteractive.removeAll { elem in
            guard elem.label == nil, elem.iconName == nil else { return false }
            if elem.type == "cell" { return true }
            if elem.heuristic == "content_area" || elem.heuristic == "unlabeled_interactive" {
                if elem.type == "textField" || elem.type == "searchField" || elem.type == "textView" { return false }
                return true
            }
            return labeledFrameIndex.containsParent(of: elem.frame)
        }

        // Phase 4c½: Promote "element" → "button" for labeled interactive items.
        // Elements that gained labels during Phase 4b adoption need type promotion
        // (type was resolved before label adoption when elem.label was nil).
        for i in mergedInteractive.indices {
            if mergedInteractive[i].type == "element", mergedInteractive[i].label != nil {
                mergedInteractive[i] = MapElement(
                    label: mergedInteractive[i].label, type: "button",
                    center: mergedInteractive[i].center, frame: mergedInteractive[i].frame,
                    hitReachable: mergedInteractive[i].hitReachable,
                    visible: mergedInteractive[i].visible,
                    heuristic: mergedInteractive[i].heuristic,
                    iconName: mergedInteractive[i].iconName,
                    isInteractive: true, value: mergedInteractive[i].value,
                    traits: mergedInteractive[i].traits,
                    scrollContext: mergedInteractive[i].scrollContext,
                    labelSource: mergedInteractive[i].labelSource
                )
            }
        }

        // Phase 4c¾: Assign heuristic from well-known label patterns.
        let labelHeuristics: [String: String] = [
            "Back": "back_button", "back icon": "back_button",
            "close icon": "close_button", "Close": "close_button",
            "close button": "close_button",
        ]
        for i in mergedInteractive.indices {
            guard mergedInteractive[i].heuristic == nil else { continue }
            guard let label = mergedInteractive[i].label else { continue }
            if let h = labelHeuristics[label] {
                mergedInteractive[i] = MapElement(
                    label: label, type: "button",
                    center: mergedInteractive[i].center, frame: mergedInteractive[i].frame,
                    hitReachable: mergedInteractive[i].hitReachable,
                    visible: mergedInteractive[i].visible,
                    heuristic: h,
                    iconName: mergedInteractive[i].iconName,
                    isInteractive: true, value: mergedInteractive[i].value,
                    traits: mergedInteractive[i].traits,
                    scrollContext: mergedInteractive[i].scrollContext,
                    labelSource: mergedInteractive[i].labelSource
                )
            }
        }

        // Phase 4d: Detect tappable option groups in non-interactive text.
        // SwiftUI views with .onTapGesture (radio buttons like Off/Push/Push+Email)
        // appear as staticText in accessibility, not as interactive elements.
        // Detect groups of 2+ short text labels at the same Y and promote them.
        promoteRadioOptionGroups(&mergedInteractive, nonInteractive: &mergedNonInteractive)

        // Phase 4e: Detect segment control groups (Day/Week/Month/Year, Photos/Popular).
        // A row of 2+ short labeled buttons at the same Y, spanning < 80% screen width
        // and each button < 100pt wide. Label them as "segment" type.
        promoteSegmentGroups(&mergedInteractive, screenWidth: screenW)

        // Phase 4f: Toggle label refinement.
        // Toggles often get the description text as their accessibility label
        // (e.g. a long explanation paragraph) when the short header text nearby
        // is what the builder should show.
        // Replace overly long toggle labels with nearby NI text to the left.
        for i in mergedInteractive.indices {
            guard mergedInteractive[i].heuristic == "toggle" else { continue }
            guard let label = mergedInteractive[i].label, label.count > 40 else { continue }
            let ec = mergedInteractive[i].center
            // Find short NI text to the left, in the same Y-band
            var bestIdx: Int?
            var bestDist: CGFloat = .greatestFiniteMagnitude
            for j in mergedNonInteractive.indices {
                guard let txt = mergedNonInteractive[j].label, txt.count >= 2, txt.count <= 40 else { continue }
                let tc = mergedNonInteractive[j].center
                guard abs(tc.y - ec.y) < 25, tc.x < ec.x else { continue }
                let dist = ec.x - tc.x
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = j
                }
            }
            // Also check nearby interactive elements (e.g. "Community sharing" cell)
            var interactiveIdx: Int?
            if bestIdx == nil {
                for j in mergedInteractive.indices {
                    guard j != i else { continue }
                    guard let txt = mergedInteractive[j].label, txt.count >= 2, txt.count <= 40 else { continue }
                    let tc = mergedInteractive[j].center
                    guard abs(tc.y - ec.y) < 25, tc.x < ec.x else { continue }
                    let dist = ec.x - tc.x
                    if dist < bestDist {
                        bestDist = dist
                        interactiveIdx = j
                    }
                }
            }
            let newLabel: String? = {
                if let j = bestIdx { return mergedNonInteractive[j].label }
                if let j = interactiveIdx { return mergedInteractive[j].label }
                return nil
            }()
            if let txt = newLabel {
                mergedInteractive[i] = MapElement(
                    label: txt, type: mergedInteractive[i].type,
                    center: mergedInteractive[i].center, frame: mergedInteractive[i].frame,
                    hitReachable: mergedInteractive[i].hitReachable,
                    visible: mergedInteractive[i].visible,
                    heuristic: mergedInteractive[i].heuristic,
                    iconName: mergedInteractive[i].iconName,
                    isInteractive: true, value: mergedInteractive[i].value,
                    traits: mergedInteractive[i].traits,
                    scrollContext: mergedInteractive[i].scrollContext,
                    labelSource: "text"
                )
                if let j = bestIdx { mergedNonInteractive.remove(at: j) }
            }
        }

        // Phase 4g: Detect selected state for sibling groups via CALayer backgroundColor.
        // For segments, radio options, and other Y-aligned groups, the "selected" item
        // typically has a distinct non-clear backgroundColor on its backing CALayer.
        // Also detect toggle on/off state via backgroundColor.
        if let window = UIWindow.pepper_keyWindow {
            detectSelectedByBackground(&mergedInteractive, window: window)
        }

        // Phase 4h: OCR pass (optional) — capture screen, run Vision text recognition,
        // deduplicate against accessibility elements, and collect survivors into a
        // separate array. Only runs when the caller passes ocr: true.
        var ocrResults: [[String: AnyCodable]] = []
        if enableOCR {
            let screenSize = UIScreen.main.bounds.size
            if let cgImage = PepperWindowCapture.captureWindow() {
                if let observations = PepperOCR.recognizeText(in: cgImage, screenSize: screenSize) {
                    let ocrObs = observations.map { OCRObservation(text: $0.text, bounds: $0.boundingBox) }
                    let survivors = deduplicateOCR(
                        observations: ocrObs,
                        interactive: mergedInteractive,
                        nonInteractive: mergedNonInteractive
                    )
                    // Serialize OCR survivors with metadata (text, center, confidence, rect).
                    // Match confidence from original observations by text+center proximity.
                    for elem in survivors {
                        let conf = observations.first { obs in
                            obs.text == elem.label
                                && abs(obs.boundingBox.midX - elem.center.x) < 2
                                && abs(obs.boundingBox.midY - elem.center.y) < 2
                        }?.confidence ?? 0
                        var entry: [String: AnyCodable] = [
                            "text": AnyCodable(elem.label ?? ""),
                            "center": AnyCodable([
                                "x": AnyCodable(Int(elem.center.x)),
                                "y": AnyCodable(Int(elem.center.y)),
                            ] as [String: AnyCodable]),
                            "confidence": AnyCodable(Double(conf)),
                        ]
                        if !isSummary {
                            entry["rect"] = AnyCodable([
                                "x": AnyCodable(Int(elem.frame.origin.x)),
                                "y": AnyCodable(Int(elem.frame.origin.y)),
                                "w": AnyCodable(Int(elem.frame.width)),
                                "h": AnyCodable(Int(elem.frame.height)),
                            ] as [String: AnyCodable])
                        }
                        ocrResults.append(entry)
                    }
                    logger.info("OCR: \(observations.count) recognized, \(survivors.count) after dedup")
                } else {
                    logger.warning("OCR: text recognition failed")
                }
            } else {
                logger.warning("OCR: window capture failed")
            }
        }

        // Phase 5: Apply spatial filters
        // Scope: resolve an element by label/identifier and use its frame as the filter region.
        let scopeRect: CGRect? = {
            guard let scopeID = command.params?["scope"]?.stringValue,
                let window = UIWindow.pepper_keyWindow
            else { return nil }
            // Try accessibility identifier first
            let resolveParams: [String: AnyCodable] = ["element": AnyCodable(scopeID)]
            let (result, _) = PepperElementResolver.resolve(params: resolveParams, in: window)
            if let r = result, r.tapPoint == nil {
                return r.view.convert(r.view.bounds, to: nil)
            }
            // Fallback: try resolving by text/label
            let textParams: [String: AnyCodable] = ["text": AnyCodable(scopeID)]
            let (textResult, _) = PepperElementResolver.resolve(params: textParams, in: window)
            guard let tr = textResult, tr.tapPoint == nil else { return nil }
            return tr.view.convert(tr.view.bounds, to: nil)
        }()
        if let rect = scopeRect {
            mergedInteractive = mergedInteractive.filter { rect.contains($0.center) }
            mergedNonInteractive = mergedNonInteractive.filter { rect.contains($0.center) }
        }

        if let regionRect = parseRegion(from: command.params) {
            mergedInteractive = mergedInteractive.filter { regionRect.contains($0.center) }
            mergedNonInteractive = mergedNonInteractive.filter { regionRect.contains($0.center) }
        }

        if let nearestDict = command.params?["nearest_to"]?.dictValue,
            let nx = nearestDict["x"]?.doubleValue,
            let ny = nearestDict["y"]?.doubleValue
        {
            let point = CGPoint(x: nx, y: ny)
            let count = nearestDict["count"]?.intValue ?? 5
            let direction = nearestDict["direction"]?.stringValue
            mergedInteractive = spatialFilterMap(
                mergedInteractive, nearestTo: point, direction: direction, count: count)
        }

        // Phase 6: Sort interactive elements by Y, assign ordinal indices for
        // duplicate labels, then group into rows by Y-band
        mergedInteractive.sort { $0.center.y < $1.center.y }
        assignOrdinalIndices(&mergedInteractive)
        let rows = groupIntoRows(mergedInteractive, bandSize: bandSize, summary: isSummary)

        // Phase 7a: Extract screen info + nav bar title (needed before text serialization)
        let screenID: String
        var navTitle: String? = nil
        if let topVC = UIWindow.pepper_topViewController {
            screenID = topVC.pepperScreenID
            // Walk up to find the nearest UINavigationController and its visible title
            var vc: UIViewController? = topVC
            while let current = vc {
                if let navC = current as? UINavigationController {
                    navTitle = navC.navigationBar.topItem?.title
                    break
                }
                if let navC = current.navigationController {
                    navTitle = navC.navigationBar.topItem?.title
                    break
                }
                vc = current.parent
            }
        } else {
            screenID = "unknown"
        }

        // Phase 7b: Serialize ALL discovered text (from the pre-mutation snapshot).
        // Apply spatial filter if present, then detect volatile text.
        // Inject nav bar title into the text list if not already present.
        var textForOutput = allDiscoveredText
        if let title = navTitle, !title.isEmpty {
            let alreadyPresent = textForOutput.contains { $0.label == title }
            if !alreadyPresent {
                textForOutput.append(
                    MapElement(
                        label: title, type: "staticText",
                        center: CGPoint(x: screenW / 2, y: 30),
                        frame: CGRect(x: 0, y: 20, width: screenW, height: 20),
                        hitReachable: false, visible: 1.0,
                        heuristic: nil, iconName: nil,
                        isInteractive: false, value: nil,
                        traits: [], scrollContext: nil, labelSource: "nav_title"
                    ))
            }
        }
        if let rect = scopeRect {
            textForOutput = textForOutput.filter { rect.contains($0.center) }
        }
        if let regionRect = parseRegion(from: command.params) {
            textForOutput = textForOutput.filter { regionRect.contains($0.center) }
        }
        textForOutput.sort { $0.center.y < $1.center.y }
        let volatileKeys = Self.trackVolatileText(&textForOutput)
        let nonInteractiveSerialized = serializeNonInteractive(textForOutput, volatileKeys: volatileKeys, summary: isSummary)
        let screenSize = UIScreen.main.bounds.size

        logger.info(
            "Map introspection: \(mergedInteractive.count) interactive, \(mergedNonInteractive.count) non-interactive, \(rows.count) rows"
        )

        // Quick memory check (microseconds — no overhead)
        var memMB: Double = 0
        var taskInfo = mach_task_basic_info()
        var taskInfoCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let memResult = withUnsafeMutablePointer(to: &taskInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(taskInfoCount)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &taskInfoCount)
            }
        }
        if memResult == KERN_SUCCESS {
            memMB = Double(taskInfo.resident_size) / 1_048_576.0
        }

        var data: [String: AnyCodable] = [
            "screen": AnyCodable(screenID),
            "element_count": AnyCodable(mergedInteractive.count),
            "rows": AnyCodable(rows),
            "non_interactive": AnyCodable(nonInteractiveSerialized),
        ]
        if !isSummary {
            data["screen_size"] = AnyCodable([
                "w": AnyCodable(Int(screenSize.width)),
                "h": AnyCodable(Int(screenSize.height)),
            ])

            // Scroll container summaries: content size, offset, and visible area
            // so formatters can indicate scrollable content and position.
            let scrollViews = ElementDiscoveryBridge.shared.collectScrollViews()
            if !scrollViews.isEmpty {
                let containers: [[String: AnyCodable]] = scrollViews.compactMap { info in
                    let sv = info.scrollView
                    let contentW = Int(sv.contentSize.width)
                    let contentH = Int(sv.contentSize.height)
                    let boundsW = Int(sv.bounds.width)
                    let boundsH = Int(sv.bounds.height)
                    // Skip scroll views that aren't actually scrollable
                    guard contentW > boundsW + 1 || contentH > boundsH + 1 else { return nil }
                    return [
                        "direction": AnyCodable(info.direction),
                        "content_size": AnyCodable([
                            "w": AnyCodable(contentW), "h": AnyCodable(contentH),
                        ] as [String: AnyCodable]),
                        "visible_size": AnyCodable([
                            "w": AnyCodable(boundsW), "h": AnyCodable(boundsH),
                        ] as [String: AnyCodable]),
                        "offset": AnyCodable([
                            "x": AnyCodable(Int(sv.contentOffset.x)),
                            "y": AnyCodable(Int(sv.contentOffset.y)),
                        ] as [String: AnyCodable]),
                        "frame": AnyCodable([
                            AnyCodable(Int(info.frameInWindow.origin.x)),
                            AnyCodable(Int(info.frameInWindow.origin.y)),
                            AnyCodable(Int(info.frameInWindow.width)),
                            AnyCodable(Int(info.frameInWindow.height)),
                        ]),
                    ]
                }
                if !containers.isEmpty {
                    data["scroll_containers"] = AnyCodable(containers.map { AnyCodable($0) })
                }
            }
        }
        if let title = navTitle, !title.isEmpty {
            data["nav_title"] = AnyCodable(title)
        }
        if !isSummary && memMB > 0 {
            data["memory_mb"] = AnyCodable(memMB)
        }
        if bridge.lastInteractiveTruncated || bridge.lastAccessibilityTruncated {
            data["truncated"] = AnyCodable(true)
            data["element_limit"] = AnyCodable(500)
        }
        if !ocrResults.isEmpty {
            data["ocr_results"] = AnyCodable(ocrResults.map { AnyCodable($0) })
        }

        // Keyboard state: surface when keyboard covers the lower screen so agents
        // know tapping covered elements will fail.
        let kbMonitor = PepperKeyboardMonitor.shared
        if kbMonitor.isVisible {
            let frame = kbMonitor.keyboardFrame
            data["keyboard_visible"] = AnyCodable(true)
            data["keyboard_height"] = AnyCodable(Int(frame.height))
        }

        // Leak detection: build a screen fingerprint from element labels
        // so type-erased screens (short generic IDs) get unique keys
        let elementLabels = mergedInteractive.compactMap { $0.label }
            .filter { !$0.isEmpty && $0.count < 60 }
        let screenKey = PepperLeakMonitor.buildScreenKey(
            screenID: screenID,
            elementLabels: elementLabels
        )
        let leaks = PepperLeakMonitor.shared.scanAndDiff(screenKey: screenKey)
        if !leaks.isEmpty {
            data["leaks"] = AnyCodable(leaks)
        }
        // Include the screen key so the agent can see how screens
        // are being identified for leak tracking (full mode only)
        if !isSummary && screenKey != screenID {
            data["screen_key"] = AnyCodable(screenKey)
        }

        // System dialog detection: warn agents when a modal dialog is blocking interaction.
        // Pending dialogs (permission prompts, alerts) overlay the app and prevent taps
        // from reaching underlying elements. Surface this prominently so agents don't
        // waste cycles tapping unreachable controls.
        let interceptor = PepperDialogInterceptor.shared
        let pendingDialogs = interceptor.pending
        if !pendingDialogs.isEmpty {
            let dialogSummaries = pendingDialogs.map { dialog -> [String: AnyCodable] in
                var summary: [String: AnyCodable] = [
                    "dialog_id": AnyCodable(dialog.id),
                    "title": AnyCodable(dialog.title ?? ""),
                    "buttons": AnyCodable(dialog.actions.map { AnyCodable($0.title ?? "") }),
                ]
                if let message = dialog.message, !message.isEmpty {
                    summary["message"] = AnyCodable(message)
                }
                return summary
            }
            data["system_dialog_blocking"] = AnyCodable(
                [
                    "warning": AnyCodable("\u{26a0}\u{fe0f} system_dialog_blocking"),
                    "description": AnyCodable(
                        "A system dialog is covering the app. UI elements behind it are not interactable until the dialog is resolved."
                    ),
                    "dialogs": AnyCodable(dialogSummaries.map { AnyCodable($0) }),
                    "suggested_actions": AnyCodable([
                        AnyCodable("dialog dismiss button=\"<button_title>\" — dismiss with a specific button"),
                        AnyCodable("dialog auto_dismiss — auto-dismiss permission dialogs"),
                        AnyCodable("simulator permissions — pre-grant permissions to avoid dialogs"),
                    ]),
                ] as [String: AnyCodable])
        } else if interceptor.systemDialogSuspected {
            // SpringBoard system dialog detected via key window resignation.
            // The in-process interceptor can't capture SpringBoard dialogs (they
            // render outside the app process), but PepperWindowMonitor noticed the
            // app lost key window status with no app-side modal pending.
            data["system_dialog_blocking"] = AnyCodable(
                [
                    "warning": AnyCodable("\u{26a0}\u{fe0f} system_dialog_suspected"),
                    "description": AnyCodable(
                        "A system dialog (e.g. permission prompt) appears to be overlaying the app. UI elements may not be interactable."
                    ),
                    "dialogs": AnyCodable([
                        AnyCodable(
                            [
                                "title": AnyCodable("System Dialog (detected via window monitor)"),
                                "buttons": AnyCodable([] as [String]),
                            ] as [String: AnyCodable])
                    ]),
                    "suggested_actions": AnyCodable([
                        AnyCodable("dialog detect_system — run full system dialog detection"),
                        AnyCodable("dialog dismiss_system — auto-detect and dismiss system dialog"),
                        AnyCodable("simulator permissions — pre-grant permissions to avoid dialogs"),
                    ]),
                ] as [String: AnyCodable])
        }

        return .ok(id: command.id, data: data)
    }

}
