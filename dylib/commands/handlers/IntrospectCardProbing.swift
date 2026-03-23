import UIKit

// MARK: - Card Detection via CALayer Probing

extension IntrospectHandler {

    /// Detect tappable card containers invisible to standard element discovery.
    ///
    /// SwiftUI views with `.contentShape(Rectangle()).onTapGesture {}` render all
    /// content inside a single `PlatformGroupContainer` — no individual UIViews per
    /// card. But `.clipShape(RoundedRectangle(cornerRadius:))` from `.homeCard()`
    /// DOES create CALayers with cornerRadius + masksToBounds.
    ///
    /// This phase walks the CALayer tree to find card-shaped layers, then groups
    /// uncovered NI text that falls within each card's frame into single interactive
    /// card elements.
    ///
    /// Runs after Phase 4a½ (gesture container grouping) and before Phase 4b
    /// (text adoption) so it doesn't interfere with either.
    func probeUncoveredTextForCards(
        _ interactive: inout [MapElement],
        nonInteractive: inout [MapElement],
        screenBounds: CGRect
    ) {
        guard let window = UIWindow.pepper_keyWindow else { return }
        guard nonInteractive.count >= 2 else { return }

        let screenArea = screenBounds.width * screenBounds.height

        // Step 1: Find NI text not inside any interactive element's frame (10pt tolerance).
        let uncoveredSet = Set(
            nonInteractive.indices.filter { i in
                let c = nonInteractive[i].center
                return !interactive.contains {
                    $0.frame.insetBy(dx: -10, dy: -10).contains(c)
                }
            })
        guard uncoveredSet.count >= 2 else { return }

        // Step 2: Walk the CALayer tree to find card-shaped layers.
        var cardFrames: [CGRect] = []
        findCardLayers(
            in: window.layer, window: window, screenBounds: screenBounds,
            screenArea: screenArea, results: &cardFrames, depth: 0)

        guard !cardFrames.isEmpty else { return }

        // Step 3: For each card frame, collect uncovered NI text inside it.
        // Sort card frames smallest-first so inner cards claim text before outer wrappers.
        cardFrames.sort { ($0.width * $0.height) < ($1.width * $1.height) }
        var claimedIndices = Set<Int>()

        for cardFrame in cardFrames {
            let expandedFrame = cardFrame.insetBy(dx: -5, dy: -5)
            var contained: [Int] = []

            for idx in uncoveredSet where !claimedIndices.contains(idx) {
                if expandedFrame.contains(nonInteractive[idx].center) {
                    contained.append(idx)
                }
            }

            guard contained.count >= 2 else { continue }

            // Sort by Y then X; topmost text becomes the card label.
            contained.sort { a, b in
                let ay = nonInteractive[a].center.y
                let by = nonInteractive[b].center.y
                if abs(ay - by) > 3 { return ay < by }
                return nonInteractive[a].center.x < nonInteractive[b].center.x
            }
            guard let topLabel = nonInteractive[contained[0]].label else { continue }

            let center = CGPoint(x: cardFrame.midX, y: cardFrame.midY)
            interactive.append(
                MapElement(
                    label: topLabel,
                    type: "button",
                    center: center,
                    frame: cardFrame,
                    hitReachable: true,
                    visible: 1.0,
                    heuristic: "card",
                    iconName: nil,
                    isInteractive: true,
                    value: nil,
                    traits: [],
                    scrollContext: nil,
                    labelSource: "text",
                    gestureContainerFrame: cardFrame
                ))

            claimedIndices.formUnion(contained)
        }

        // Step 4: Remove claimed NI text (reverse order for safe removal).
        for idx in claimedIndices.sorted().reversed() {
            nonInteractive.remove(at: idx)
        }
    }

    // MARK: - CALayer Card Detection

    /// Recursively walk the CALayer tree finding layers that look like card containers.
    ///
    /// Card signal: cornerRadius >= 8, masksToBounds, 80+ pt wide, 50-250pt tall,
    /// not circular (avatars, progress rings), less than 50% of screen area.
    private func findCardLayers(
        in layer: CALayer,
        window: UIWindow,
        screenBounds: CGRect,
        screenArea: CGFloat,
        results: inout [CGRect],
        depth: Int
    ) {
        guard depth < 40 else { return }

        let bounds = layer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        // Convert layer center to window coordinates
        let centerInLayer = CGPoint(x: bounds.midX, y: bounds.midY)
        let centerInWindow = layer.convert(centerInLayer, to: window.layer)
        let frameInWindow = CGRect(
            x: centerInWindow.x - bounds.width / 2,
            y: centerInWindow.y - bounds.height / 2,
            width: bounds.width,
            height: bounds.height
        )

        let area = frameInWindow.width * frameInWindow.height

        // Card criteria: rounded corners + clipping + card-sized + on screen.
        // Min 50pt tall (filters map callout badges) and max 250pt tall
        // (filters section wrappers that clip their content).
        if layer.cornerRadius >= 8 && layer.masksToBounds,
            frameInWindow.width >= 80, frameInWindow.height >= 50,
            frameInWindow.height <= 250,
            area < screenArea * 0.5,
            screenBounds.intersects(frameInWindow)
        {
            // Skip near-circular layers (avatar images, progress rings):
            // cards have both dimensions > 80pt or clear rectangular shape.
            let minDim = min(frameInWindow.width, frameInWindow.height)
            let maxDim = max(frameInWindow.width, frameInWindow.height)
            let isCircular = abs(minDim - maxDim) < 10 && minDim < 80
            if !isCircular {
                results.append(frameInWindow)
            }
        }

        // Recurse into sublayers
        guard let sublayers = layer.sublayers else { return }
        for sublayer in sublayers {
            findCardLayers(
                in: sublayer, window: window, screenBounds: screenBounds,
                screenArea: screenArea, results: &results, depth: depth + 1)
        }
    }
}
