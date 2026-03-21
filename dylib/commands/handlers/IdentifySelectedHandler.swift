import UIKit

/// Handles {"cmd": "identify_selected", "params": {"labels": ["Day", "Week", "Month"]}}
/// Also supports single-label auto-discovery: {"labels": ["Day"]} — finds siblings
/// automatically by looking for other accessibility labels in the same horizontal band.
///
/// For each label, finds its accessibility frame, renders that screen region to
/// pixels, and computes visual fingerprints. The outlier across siblings is
/// identified as "selected".
///
/// Adaptive scoring pipeline:
/// 1. Detects color scheme (dark/light) from median background brightness across all regions
/// 2. Samples background using median of edge strips (robust to gradients, rounded corners, shadows)
/// 3. Computes ink threshold adaptively from the background/foreground contrast in each region
/// 4. Detects underlines/indicators in the bottom 15% (tighter than old 25%)
/// 5. Scores outliers using weighted metrics with adaptive thresholds
struct IdentifySelectedHandler: PepperHandler {
    let commandName = "identify_selected"

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let labelsRaw = command.params?["labels"]?.arrayValue else {
            return .error(id: command.id, message: "Missing required param: labels (array of strings)")
        }
        var labels = labelsRaw.compactMap { $0.stringValue }
        guard !labels.isEmpty else {
            return .error(id: command.id, message: "labels array must not be empty")
        }

        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window")
        }

        // Phase 1: Get accessibility frames for each label
        struct LabelMatch {
            let label: String
            let accFrame: CGRect
        }

        // Auto-discover siblings when given a single label
        if labels.count == 1 {
            if let siblings = discoverSiblings(for: labels[0]) {
                labels = siblings
            }
        }

        var labelMatches: [LabelMatch] = []

        for label in labels {
            if let frame = PepperSwiftUIBridge.shared.findAccessibilityElementFrame(
                label: label, exact: true
            ) {
                labelMatches.append(LabelMatch(label: label, accFrame: frame))
            }
        }

        guard labelMatches.count >= 2 else {
            let found = labelMatches.map(\.label)
            return .ok(id: command.id, data: [
                "selected": AnyCodable(NSNull()),
                "reason": AnyCodable("only found \(found.count) of \(labels.count) labels: \(found)")
            ])
        }

        // Phase 2: Render the window to a snapshot image
        let scale = UIScreen.main.scale
        let windowBounds = window.bounds
        let renderer = UIGraphicsImageRenderer(bounds: windowBounds)
        let snapshot = renderer.image { ctx in
            window.drawHierarchy(in: windowBounds, afterScreenUpdates: false)
        }

        guard let cgImage = snapshot.cgImage else {
            return .error(id: command.id, message: "Failed to render window snapshot")
        }

        // Phase 3: Extract pixel data for each region
        var regions: [RegionAnalysis] = []
        var debugLines: [String] = []

        for m in labelMatches {
            let analysis = analyzeRegion(
                from: cgImage,
                region: m.accFrame,
                scale: scale,
                label: m.label
            )
            regions.append(analysis)
        }

        // Phase 4: Detect color scheme from system trait collection (not pixel guessing)
        let isDarkMode = UITraitCollection.current.userInterfaceStyle == .dark

        for r in regions {
            debugLines.append(String(format: "%@: bg=%.3f brightness=%.3f ink=%.3f edgeInk=%.3f sat=%.3f chromaDist=%.3f",
                                     r.label, r.bgBrightness, r.avgBrightness, r.inkCoverage,
                                     r.bottomEdgeInk, r.avgSaturation, r.chromaDistance))
        }
        debugLines.append(isDarkMode ? "scheme=dark" : "scheme=light")

        // Phase 5: Weighted outlier scoring with adaptive thresholds
        var scores: [String: CGFloat] = [:]

        // Brightness outlier — in dark mode, selected text is brighter (white vs gray);
        // in light mode, selected text is darker (black vs gray) or more contrasty.
        // Either way the outlier metric works, but threshold differs.
        let brightnessThreshold: CGFloat = isDarkMode ? 0.02 : 0.025
        scoreOutlier(regions.map { ($0.label, $0.avgBrightness) }, into: &scores,
                     threshold: brightnessThreshold, weight: 1.0)

        // Ink coverage outlier — bolder/heavier text has more ink pixels.
        // In dark mode, ink detection is harder (lower contrast), so use a smaller threshold.
        let inkThreshold: CGFloat = isDarkMode ? 0.01 : 0.015
        scoreOutlier(regions.map { ($0.label, $0.inkCoverage) }, into: &scores,
                     threshold: inkThreshold, weight: 1.2)

        // Bottom edge ink — detects underline indicators below text.
        // Weight higher because an underline is a strong selection signal.
        scoreOutlier(regions.map { ($0.label, $0.bottomEdgeInk) }, into: &scores,
                     threshold: 0.02, weight: 1.5)

        // Saturation outlier — colored text vs gray/white text.
        // Weight moderately — some apps use color for all text.
        scoreOutlier(regions.map { ($0.label, $0.avgSaturation) }, into: &scores,
                     threshold: 0.015, weight: 1.0)

        // Chroma distance — how far the average foreground color is from gray.
        // Detects blue/accent-colored selected text vs neutral unselected text.
        scoreOutlier(regions.map { ($0.label, $0.chromaDistance) }, into: &scores,
                     threshold: 0.015, weight: 1.3)

        // Find winner — highest score with clear margin over runner-up
        var selected: String? = nil
        let sortedScores = scores.sorted { $0.value > $1.value }
        if let winner = sortedScores.first, winner.value > 0 {
            if sortedScores.count < 2 || winner.value > sortedScores[1].value * 1.2 {
                selected = winner.key
            }
        }

        // Draw overlay highlights
        let showOverlays = command.params?["highlight"]?.boolValue ?? true
        if showOverlays {
            for m in labelMatches {
                let isWinner = m.label == selected
                let color: UIColor = isWinner
                    ? UIColor(red: 0.133, green: 0.773, blue: 0.369, alpha: 1)
                    : UIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5)
                let overlayLabel = isWinner ? "Selected: \(m.label)" : m.label
                PepperOverlayView.shared.show(
                    frame: m.accFrame,
                    color: color,
                    label: overlayLabel,
                    duration: 2.0
                )
            }
        }

        // Convert scores to serializable format (round to 2 decimal places for readability)
        let scoreDict = scores.mapValues { AnyCodable(Double(round($0 * 100) / 100)) }

        return .ok(id: command.id, data: [
            "selected": AnyCodable(selected as Any),
            "scores": AnyCodable(scoreDict),
            "scheme": AnyCodable(isDarkMode ? "dark" : "light"),
            "debug": AnyCodable(debugLines)
        ])
    }

    // MARK: - Sibling Discovery

    /// Given a single label, find other accessibility elements in the same
    /// horizontal band — these are siblings in a tab bar / segmented control.
    private func discoverSiblings(for targetLabel: String) -> [String]? {
        guard let targetFrame = PepperSwiftUIBridge.shared.findAccessibilityElementFrame(
            label: targetLabel, exact: true
        ) else { return nil }

        let screenBounds = UIScreen.main.bounds
        let allElements = PepperSwiftUIBridge.shared.collectAccessibilityElements()

        let targetMidY = targetFrame.midY
        let yTolerance: CGFloat = 8  // points
        let heightTolerance: CGFloat = 10  // points

        var siblings: [String] = []
        var seen = Set<String>()

        for element in allElements {
            guard let label = element.label, !label.isEmpty else { continue }
            guard !seen.contains(label) else { continue }
            let frame = element.frame
            // Must be on-screen
            guard screenBounds.intersects(frame) else { continue }
            // Must be in same horizontal band (similar Y midpoint)
            guard abs(frame.midY - targetMidY) < yTolerance else { continue }
            // Must be similar height (same kind of element)
            guard abs(frame.height - targetFrame.height) < heightTolerance else { continue }
            // Skip very wide elements (likely container, not individual label)
            guard frame.width < screenBounds.width * 0.6 else { continue }

            siblings.append(label)
            seen.insert(label)
        }

        // Need at least 2 (target + at least 1 sibling)
        guard siblings.count >= 2 else { return nil }
        return siblings
    }

    // MARK: - Region Analysis

    /// Complete analysis result for a single label's pixel region.
    private struct RegionAnalysis {
        let label: String
        let bgBrightness: CGFloat       // Estimated background brightness (median of edge samples)
        let avgBrightness: CGFloat       // Average pixel brightness
        let inkCoverage: CGFloat         // Fraction of non-background pixels (adaptive threshold)
        let bottomEdgeInk: CGFloat       // Ink in bottom 15% — detects underlines
        let avgSaturation: CGFloat       // Average color saturation
        let chromaDistance: CGFloat       // Distance of average foreground color from neutral gray
    }

    /// Analyze a screen region's pixels with adaptive background detection.
    private func analyzeRegion(
        from image: CGImage,
        region: CGRect,
        scale: CGFloat,
        label: String
    ) -> RegionAnalysis {
        // Convert point coords to pixel coords
        let px = Int(region.origin.x * scale)
        let py = Int(region.origin.y * scale)
        let pw = max(1, Int(region.width * scale))
        let ph = max(1, Int(region.height * scale))

        // Clamp to image bounds
        let imgW = image.width
        let imgH = image.height
        let x0 = max(0, min(px, imgW - 1))
        let y0 = max(0, min(py, imgH - 1))
        let x1 = min(x0 + pw, imgW)
        let y1 = min(y0 + ph, imgH)

        guard x1 > x0, y1 > y0 else {
            return RegionAnalysis(label: label, bgBrightness: 0.5, avgBrightness: 0,
                                  inkCoverage: 0, bottomEdgeInk: 0, avgSaturation: 0, chromaDistance: 0)
        }

        // Crop and rasterize
        let cropRect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        guard let cropped = image.cropping(to: cropRect) else {
            return RegionAnalysis(label: label, bgBrightness: 0.5, avgBrightness: 0,
                                  inkCoverage: 0, bottomEdgeInk: 0, avgSaturation: 0, chromaDistance: 0)
        }

        let w = cropped.width
        let h = cropped.height
        let bytesPerPixel = 4
        let bytesPerRow = w * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: w * h * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return RegionAnalysis(label: label, bgBrightness: 0.5, avgBrightness: 0,
                                  inkCoverage: 0, bottomEdgeInk: 0, avgSaturation: 0, chromaDistance: 0)
        }

        context.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Step 1: Adaptive background estimation — sample edge strips (top/bottom/left/right
        // edges, 2px thick) and take the median brightness. This is far more robust than
        // corner sampling because it handles gradients, rounded corners, and drop shadows.
        let bgBrightness = estimateBackground(pixelData, w: w, h: h)

        // Step 2: Adaptive ink threshold — set at 40% of the distance from background to
        // the opposite extreme (0 or 1). This handles both dark-on-light and light-on-dark.
        let inkThreshold: CGFloat
        if bgBrightness > 0.5 {
            // Light background — ink is darker
            inkThreshold = bgBrightness * 0.4  // e.g., bg=0.95 -> threshold=0.38 contrast
        } else {
            // Dark background — ink is brighter
            inkThreshold = (1.0 - bgBrightness) * 0.4  // e.g., bg=0.1 -> threshold=0.36 contrast
        }

        // Step 3: Scan all pixels
        var totalBrightness: CGFloat = 0
        var totalSaturation: CGFloat = 0
        var inkPixels: CGFloat = 0
        var bottomInkPixels: CGFloat = 0
        let totalPixels = CGFloat(w * h)
        // Bottom 15% — tighter window catches underlines without including body text
        let bottomStart = h * 85 / 100
        var bottomTotalPixels: CGFloat = 0

        // Track foreground color for chroma analysis
        var fgR: CGFloat = 0, fgG: CGFloat = 0, fgB: CGFloat = 0
        var fgCount: CGFloat = 0

        for row in 0..<h {
            for col in 0..<w {
                let offset = (row * w + col) * bytesPerPixel
                let r = CGFloat(pixelData[offset]) / 255.0
                let g = CGFloat(pixelData[offset + 1]) / 255.0
                let b = CGFloat(pixelData[offset + 2]) / 255.0

                let brightness = 0.299 * r + 0.587 * g + 0.114 * b
                totalBrightness += brightness

                // Saturation (max-min range in RGB)
                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                totalSaturation += (maxC - minC)

                // Ink detection with adaptive threshold
                let isInk = abs(brightness - bgBrightness) > inkThreshold
                if isInk {
                    inkPixels += 1
                    fgR += r; fgG += g; fgB += b
                    fgCount += 1
                }

                if row >= bottomStart {
                    bottomTotalPixels += 1
                    if isInk { bottomInkPixels += 1 }
                }
            }
        }

        let avgBrightness = totalPixels > 0 ? totalBrightness / totalPixels : 0
        let inkCoverage = totalPixels > 0 ? inkPixels / totalPixels : 0
        let bottomEdgeInk = bottomTotalPixels > 0 ? bottomInkPixels / bottomTotalPixels : 0
        let avgSaturation = totalPixels > 0 ? totalSaturation / totalPixels : 0

        // Chroma distance: how far the average foreground color is from neutral gray.
        // Selected text often uses an accent color (blue, brand color) while unselected is gray.
        let chromaDistance: CGFloat
        if fgCount > 0 {
            let avgR = fgR / fgCount
            let avgG = fgG / fgCount
            let avgB = fgB / fgCount
            let gray = (avgR + avgG + avgB) / 3.0
            // Euclidean distance from the gray point in RGB space
            let dr = avgR - gray
            let dg = avgG - gray
            let db = avgB - gray
            chromaDistance = sqrt(dr * dr + dg * dg + db * db)
        } else {
            chromaDistance = 0
        }

        return RegionAnalysis(
            label: label,
            bgBrightness: bgBrightness,
            avgBrightness: avgBrightness,
            inkCoverage: inkCoverage,
            bottomEdgeInk: bottomEdgeInk,
            avgSaturation: avgSaturation,
            chromaDistance: chromaDistance
        )
    }

    // MARK: - Background Estimation

    /// Estimate background brightness by sampling edge strips and taking the median.
    /// Samples the outermost 2-pixel-thick strips on all 4 edges, collects their
    /// brightness values, and returns the median. This is robust to:
    /// - Rounded corners (only a few corner pixels are wrong, median ignores them)
    /// - Gradients (median tracks the dominant edge color)
    /// - Drop shadows (shadows are on one edge; other 3 edges dominate the median)
    private func estimateBackground(_ data: [UInt8], w: Int, h: Int) -> CGFloat {
        var samples: [CGFloat] = []
        samples.reserveCapacity(2 * (w + h) * 2) // rough upper bound

        let stripWidth = min(2, min(w, h))

        // Top and bottom strips
        for row in 0..<stripWidth {
            for col in 0..<w {
                samples.append(pixelBrightness(data, col: col, row: row, w: w))
            }
        }
        for row in (h - stripWidth)..<h {
            for col in 0..<w {
                samples.append(pixelBrightness(data, col: col, row: row, w: w))
            }
        }

        // Left and right strips (excluding corners already counted)
        for row in stripWidth..<(h - stripWidth) {
            for col in 0..<stripWidth {
                samples.append(pixelBrightness(data, col: col, row: row, w: w))
            }
            for col in (w - stripWidth)..<w {
                samples.append(pixelBrightness(data, col: col, row: row, w: w))
            }
        }

        guard !samples.isEmpty else { return 0.5 }
        return medianValue(samples)
    }

    /// Get brightness of a single pixel.
    private func pixelBrightness(_ data: [UInt8], col: Int, row: Int, w: Int) -> CGFloat {
        let offset = (row * w + col) * 4
        guard offset + 2 < data.count else { return 0.5 }
        let r = CGFloat(data[offset]) / 255.0
        let g = CGFloat(data[offset + 1]) / 255.0
        let b = CGFloat(data[offset + 2]) / 255.0
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    /// Compute the median of an array of values.
    private func medianValue(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0.5 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }

    // MARK: - Scoring

    /// Score a single metric: if one value is the sole outlier, add `weight` to its score.
    /// Uses the standard deviation to set adaptive thresholds — the minimum threshold
    /// ensures noise doesn't trigger false positives, while the ratio check ensures
    /// the outlier is clearly separated from the pack.
    private func scoreOutlier(
        _ values: [(String, CGFloat)],
        into scores: inout [String: CGFloat],
        threshold: CGFloat,
        weight: CGFloat
    ) {
        guard values.count >= 2 else { return }
        let mean = values.map(\.1).reduce(0, +) / CGFloat(values.count)
        let deviations = values.map { ($0.0, abs($0.1 - mean)) }
        let sorted = deviations.sorted { $0.1 > $1.1 }

        // The biggest deviation must exceed the minimum threshold
        guard sorted[0].1 > threshold else { return }

        // And it must be clearly separated from the second-biggest deviation.
        // For 2 elements: sole outlier guaranteed (only 1 can be furthest).
        // For 3+ elements: the top outlier must be at least 1.4x the runner-up.
        if sorted.count >= 2 && sorted[1].1 > 0 {
            guard sorted[0].1 > sorted[1].1 * 1.4 else { return }
        }

        scores[sorted[0].0, default: 0] += weight
    }
}
