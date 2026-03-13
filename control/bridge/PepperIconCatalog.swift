import UIKit
import os

/// Matches on-screen icon buttons against the app's icon asset catalog using perceptual hashing.
///
/// On first use, loads all icon assets from the app bundle (configured via PepperAppConfig),
/// renders each to a 17x16 grayscale bitmap, and computes a dHash (difference hash).
/// When `identify(frame:)` is called, the screen region is captured, hashed, and compared
/// against the catalog.
final class PepperIconCatalog {
    static let shared = PepperIconCatalog()

    private var logger: Logger { PepperLogger.logger(category: "icon-catalog") }

    struct IconMatch {
        let iconName: String    // Icon asset name (e.g. "close-icon")
        let heuristic: String?  // Mapped heuristic label (e.g. "close_button") or nil
        let distance: Int       // Hamming distance (0 = exact match)
    }

    // Catalog: dHash → asset name (internal for extension access)
    var catalog: [Data: String] = [:]
    // Pre-sorted catalog for deterministic iteration (Swift Dictionary order is
    // non-deterministic across process launches due to ASLR)
    var sortedCatalog: [(key: Data, value: String)] = []
    var catalogBundle: String?
    private(set) var built = false

    private init() {}

    // MARK: - Catalog Build

    /// Build the catalog lazily on first use.
    func ensureBuilt() {
        guard !built else { return }
        build()
    }

    private func build() {
        let bundle = findAppAssetsBundle()
        catalogBundle = bundle.bundlePath
        logger.info("Icon catalog: using bundle \(bundle.bundlePath)")

        // Merge configured icon names with dynamically discovered ones from the asset catalog
        let configuredNames = Set(Self.allIconNames)
        let discoveredNames = discoverIconNames(in: bundle)
        let allNames = Array(configuredNames.union(discoveredNames)).sorted()
        let dynamicCount = discoveredNames.subtracting(configuredNames).count
        let newIcons = discoveredNames.subtracting(configuredNames).sorted()
        logger.info("Icon catalog: \(allNames.count) total icons (\(configuredNames.count) configured + \(dynamicCount) discovered). Discovery found \(discoveredNames.count) in asset catalog.")
        if dynamicCount > 0 {
            logger.info("Icon catalog: new icons from discovery: \(newIcons.prefix(20).joined(separator: ", "))")
        }

        var loaded = 0
        var failedLoad: [String] = []
        var failedHash: [String] = []
        for name in allNames {
            // Try bundle first, then main, then nil (searches all)
            let image = UIImage(named: name, in: bundle, with: nil)
                ?? UIImage(named: name, in: Bundle.main, with: nil)
                ?? UIImage(named: name)
            guard let image = image else {
                failedLoad.append(name)
                continue
            }
            // Template images need to be rendered with a tint color to produce visible pixels.
            // Render at multiple fill ratios:
            // - 0.55: standard padded buttons
            // - 0.65: bg-subtracted icons in circular frames (24pt icon/38pt frame)
            // - 0.90: inscribed-square capture of circled icons (scale 0.7)
            var anyFillOk = false
            for fill in [0.55, 0.65, 0.90] as [CGFloat] {
                let rendered = renderForHashing(image, fill: fill)
                guard let hash = computeDHash(image: rendered) else { continue }
                // Avoid cross-icon collision: keep the first name for a given hash
                if let existing = catalog[hash], existing != name { continue }
                catalog[hash] = name
                anyFillOk = true
            }
            if !anyFillOk { failedHash.append(name); continue }
            loaded += 1
        }

        sortedCatalog = catalog.sorted(by: { $0.value < $1.value })
        built = true
        logger.info("Icon catalog built: \(loaded)/\(allNames.count) icons loaded (\(dynamicCount) discovered dynamically)")
        if !failedLoad.isEmpty {
            logger.warning("Icon catalog: \(failedLoad.count) failed to load: \(failedLoad.prefix(10).joined(separator: ", "))")
        }
        if !failedHash.isEmpty {
            logger.warning("Icon catalog: \(failedHash.count) failed to hash: \(failedHash.joined(separator: ", "))")
        }
    }

    /// Render a (possibly template) image as dark-on-light for hashing.
    /// Template images have no inherent color — they're alpha masks. Without this,
    /// the dHash would be all-zero for template images.
    ///
    /// Renders the icon at 24x24 with consistent padding (matching typical on-screen
    /// button padding where the icon fills ~55% of the frame).
    private func renderForHashing(_ image: UIImage, fill: CGFloat = 0.55) -> UIImage {
        let canvasSize: CGFloat = 24
        let size = CGSize(width: canvasSize, height: canvasSize)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let iconSize = canvasSize * fill
            let padding = (canvasSize - iconSize) / 2
            let iconRect = CGRect(x: padding, y: padding, width: iconSize, height: iconSize)
            image.withTintColor(.black, renderingMode: .alwaysTemplate).draw(in: iconRect)
        }
    }

    /// Find the app's asset bundle by name from PepperAppConfig.
    private func findAppAssetsBundle() -> Bundle {
        guard let bundleName = PepperAppConfig.shared.assetBundleName else {
            logger.warning("No asset bundle name configured, falling back to main bundle")
            return Bundle.main
        }

        // 1. Scan allBundles for one containing the configured name
        for b in Bundle.allBundles {
            if b.bundlePath.contains(bundleName) {
                return b
            }
        }

        // 2. Search main bundle's path for SPM resource bundles
        let mainPath = Bundle.main.bundlePath
        if let enumerator = FileManager.default.enumerator(atPath: mainPath) {
            while let path = enumerator.nextObject() as? String {
                if path.contains(bundleName) && path.hasSuffix(".bundle") {
                    let fullPath = (mainPath as NSString).appendingPathComponent(path)
                    if let b = Bundle(path: fullPath) {
                        return b
                    }
                }
            }
        }

        // 3. Fallback to main bundle
        logger.warning("\(bundleName) bundle not found, falling back to main bundle")
        return Bundle.main
    }

    // MARK: - Dynamic Discovery

    /// Discover icon asset names from the compiled asset catalog (.car) using CoreUI private API.
    /// Falls back to empty set if the API isn't available (no impact on configured icons).
    private func discoverIconNames(in bundle: Bundle) -> Set<String> {
        // CUICatalog is a private CoreUI class that manages compiled .car asset catalogs.
        // We use it to enumerate all image names without needing a hardcoded list.
        guard let cuiCatalogClass = NSClassFromString("CUICatalog") else {
            logger.info("Icon discovery: CUICatalog class not available")
            return []
        }

        // Find the Assets.car file in the bundle
        let carPath: String
        if let path = bundle.path(forResource: "Assets", ofType: "car") {
            carPath = path
        } else if let path = Bundle.main.path(forResource: "Assets", ofType: "car") {
            carPath = path
        } else {
            logger.info("Icon discovery: no Assets.car found")
            return []
        }

        // Initialize CUICatalog with the .car file URL
        let url = URL(fileURLWithPath: carPath) as NSURL
        let catalog: AnyObject

        // Use ObjC runtime to call [[CUICatalog alloc] initWithURL:error:]
        // Swift forbids .alloc() directly, so we go through objc_msgSend.
        let allocSel = NSSelectorFromString("alloc")
        guard let rawInstance = (cuiCatalogClass as AnyObject).perform(allocSel)?.takeUnretainedValue() else {
            logger.info("Icon discovery: CUICatalog alloc failed")
            return []
        }

        let initSel = NSSelectorFromString("initWithURL:error:")
        guard rawInstance.responds(to: initSel) else {
            logger.info("Icon discovery: CUICatalog doesn't respond to initWithURL:error:")
            return []
        }

        typealias InitMethod = @convention(c) (AnyObject, Selector, NSURL, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let imp = rawInstance.method(for: initSel)
        let initFunc = unsafeBitCast(imp, to: InitMethod.self)
        var error: NSError?
        guard let result = initFunc(rawInstance, initSel, url, &error) else {
            logger.info("Icon discovery: CUICatalog init failed: \(error?.localizedDescription ?? "unknown")")
            return []
        }
        catalog = result

        // Get all image names via allImageNames selector
        let allNamesSel = NSSelectorFromString("allImageNames")
        guard catalog.responds(to: allNamesSel),
              let names = catalog.perform(allNamesSel)?.takeUnretainedValue() as? [String] else {
            logger.info("Icon discovery: allImageNames not available")
            return []
        }

        // Filter for icon assets using configured suffix, or accept all if no suffix configured
        let iconNames: [String]
        if let suffix = PepperAppConfig.shared.iconNameSuffix {
            iconNames = names.filter { $0.hasSuffix(suffix) }
        } else {
            iconNames = names
        }
        logger.info("Icon discovery: found \(iconNames.count) icon assets out of \(names.count) total images")
        return Set(iconNames)
    }

    // MARK: - Identification

    /// Debug: identify with extra info for the identify_icons command.
    struct ScaleResult {
        let scale: CGFloat
        let method: String   // "dhash" or "bgsub"
        let hashHex: String
        let bestName: String
        let bestDistance: Int
    }

    struct DebugMatch {
        let match: IconMatch?
        let bestDistance: Int
        let bestName: String?
        let hashHex: String
        let scaleResults: [ScaleResult]
    }

    func identifyDebug(frame: CGRect) -> DebugMatch? {
        ensureBuilt()
        guard let window = UIWindow.pepper_keyWindow else { return nil }
        guard frame.width >= 6 && frame.height >= 6 else { return nil }

        // Square non-square frames (same as identify())
        let effectiveFrame: CGRect
        let ratio = frame.width / frame.height
        if ratio < 0.8 || ratio > 1.25 {
            let side = min(frame.width, frame.height)
            effectiveFrame = CGRect(
                x: frame.midX - side / 2, y: frame.midY - side / 2,
                width: side, height: side
            )
        } else {
            effectiveFrame = frame
        }

        var overallBestName: String?
        var overallBestDistance = Int.max
        var bestHashHex = ""
        var bestMethod = "dhash"
        var scaleResults: [ScaleResult] = []

        // 0.7 = inscribed square of circular backgrounds.
        // 1.0/1.5/1.82 = expanding for padded icons with varying fill ratios.
        for scale in [0.7, 1.0, 1.5, 1.82] as [CGFloat] {
            guard let hash = captureAndHash(frame: effectiveFrame, window: window, scale: scale) else { continue }
            let invertedHash = Data(hash.map { ~$0 })
            let hashHex = hash.map { String(format: "%02x", $0) }.joined()

            var scaleBest = ("", Int.max)
            for (catalogHash, name) in sortedCatalog {
                let dist = min(
                    hammingDistance(hash, catalogHash),
                    hammingDistance(invertedHash, catalogHash)
                )
                if dist < scaleBest.1 { scaleBest = (name, dist) }
                if dist < overallBestDistance {
                    overallBestDistance = dist
                    overallBestName = name
                    bestHashHex = hashHex
                    bestMethod = "dhash"
                }
            }
            scaleResults.append(ScaleResult(
                scale: scale, method: "dhash", hashHex: hashHex,
                bestName: scaleBest.0, bestDistance: scaleBest.1
            ))
        }

        // Background subtraction pass: only for frames >= 30pt (small icons produce
        // too-sparse hashes at 13×12 resolution, causing false positives)
        if effectiveFrame.width >= 30 || effectiveFrame.height >= 30 { for scale in [0.7, 1.0, 1.15, 1.5] as [CGFloat] {
            guard let hash = captureAndHashBgSub(frame: effectiveFrame, window: window, scale: scale) else { continue }
            let hashHex = hash.map { String(format: "%02x", $0) }.joined()
            var scaleBest = ("", Int.max)
            for (catalogHash, name) in sortedCatalog {
                // Skip sparse catalog entries — prevents sparse↔sparse false positives
                let catBits = catalogHash.reduce(0) { $0 + $1.nonzeroBitCount }
                if catBits < 12 { continue }
                let dist = hammingDistance(hash, catalogHash)
                if dist < scaleBest.1 { scaleBest = (name, dist) }
                if dist < overallBestDistance {
                    overallBestDistance = dist
                    overallBestName = name
                    bestHashHex = hashHex
                    bestMethod = "bgsub"
                }
            }
            scaleResults.append(ScaleResult(
                scale: scale, method: "bgsub", hashHex: hashHex,
                bestName: scaleBest.0, bestDistance: scaleBest.1
            ))
        } }

        // Apply method-appropriate threshold: bg-sub hashes are sparser, need wider tolerance
        let matchThreshold = bestMethod == "bgsub" ? 8 : 5
        var match: IconMatch?
        if overallBestDistance <= matchThreshold, let name = overallBestName {
            match = IconMatch(iconName: name, heuristic: Self.resolveHeuristic(for: name), distance: overallBestDistance)
        }
        if match == nil {
            match = identifyByThreshold(frame: effectiveFrame, window: window)
        }

        return DebugMatch(match: match, bestDistance: overallBestDistance, bestName: overallBestName,
                          hashHex: bestHashHex, scaleResults: scaleResults)
    }

    /// Identify an icon at the given screen frame.
    /// Returns nil if no match found within the hamming distance threshold.
    ///
    /// Tries multiple capture scales to handle icons that fill different percentages
    /// of their frame. The catalog renders icons at 55% fill, but on-screen frames
    /// may be tight (100% fill). Expanding the capture adds synthetic padding.
    func identify(frame: CGRect) -> IconMatch? {
        ensureBuilt()
        guard let window = UIWindow.pepper_keyWindow else { return nil }
        guard frame.width >= 6 && frame.height >= 6 else { return nil }

        // Square non-square frames: icons are always square but accessibility frames
        // may not be (e.g., 28x36). Use the smaller dimension centered on the midpoint.
        let effectiveFrame: CGRect
        let ratio = frame.width / frame.height
        if ratio < 0.8 || ratio > 1.25 {
            let side = min(frame.width, frame.height)
            effectiveFrame = CGRect(
                x: frame.midX - side / 2, y: frame.midY - side / 2,
                width: side, height: side
            )
        } else {
            effectiveFrame = frame
        }

        // Try all scales, keep the best (lowest distance) match.
        // Scale 0.7 = inscribed square of circular backgrounds.
        // 1.0/1.5/1.82 = expanding for padded icons with varying fill ratios.
        var bestMatch: IconMatch?
        for scale in [0.7, 1.0, 1.5, 1.82] as [CGFloat] {
            if let match = identifyAtScale(frame: effectiveFrame, window: window, scale: scale) {
                if match.distance == 0 { return match } // Perfect → short-circuit
                if bestMatch == nil || match.distance < bestMatch!.distance {
                    bestMatch = match
                }
            }
        }
        if bestMatch != nil { return bestMatch }

        // Fallback: background subtraction for icons on circular/colored backgrounds.
        // Only for frames >= 30pt — smaller icons produce too-sparse bg-sub hashes that
        // accidentally match simple catalog icons (subtract-icon, close-icon).
        // Threshold 8: bg-sub hashes are sparser (binary thresholding loses anti-aliasing).
        if effectiveFrame.width >= 30 || effectiveFrame.height >= 30 {
            for scale in [0.7, 1.0, 1.15, 1.5] as [CGFloat] {
                if let hash = captureAndHashBgSub(frame: effectiveFrame, window: window, scale: scale),
                   let match = matchHash(hash, threshold: 8, minCatalogBits: 12) {
                    if match.distance == 0 { return match }
                    if bestMatch == nil || match.distance < bestMatch!.distance {
                        bestMatch = match
                    }
                }
            }
        }

        // Fallback: threshold-based matching for complex backgrounds (maps, gradients)
        return bestMatch ?? identifyByThreshold(frame: effectiveFrame, window: window)
    }

    /// Attempt identification at a single capture scale.
    private func identifyAtScale(frame: CGRect, window: UIWindow, scale: CGFloat) -> IconMatch? {
        guard let hash = captureAndHash(frame: frame, window: window, scale: scale) else { return nil }
        // Threshold 5: valid matches are typically d=0-3, false positives start at d=6.
        // Tightened from 8 to reduce false positives (more-horiz matching nav arrows).
        return matchHash(hash, threshold: 5)
    }

    /// Match a hash against the catalog. Returns nil if best distance exceeds threshold.
    /// `minCatalogBits`: skip catalog entries with fewer set bits (prevents sparse→sparse false positives).
    func matchHash(_ hash: Data, threshold: Int, minCatalogBits: Int = 0) -> IconMatch? {
        let invertedHash = Data(hash.map { ~$0 })

        if minCatalogBits == 0 {
            if let name = catalog[hash] {
                return IconMatch(iconName: name, heuristic: Self.resolveHeuristic(for: name), distance: 0)
            }
            if let name = catalog[invertedHash] {
                return IconMatch(iconName: name, heuristic: Self.resolveHeuristic(for: name), distance: 0)
            }
        }

        var bestName: String?
        var bestDistance = Int.max
        var secondBestDistance = Int.max

        // Sort by icon name for deterministic iteration — Swift Dictionary order
        // is non-deterministic across process launches (ASLR), so tied distances
        // would produce different winners on each look without sorting.
        for (catalogHash, name) in sortedCatalog {
            if minCatalogBits > 0 {
                let catBits = catalogHash.reduce(0) { $0 + $1.nonzeroBitCount }
                if catBits < minCatalogBits { continue }
            }
            let dist = min(
                hammingDistance(hash, catalogHash),
                hammingDistance(invertedHash, catalogHash)
            )
            if dist < bestDistance {
                if bestName != name { secondBestDistance = bestDistance }
                bestDistance = dist
                bestName = name
            } else if dist < secondBestDistance && name != bestName {
                secondBestDistance = dist
            }
        }

        // Accept at threshold, or at threshold+1 if confidence gap to second-best is >= 4 bits.
        // This catches near-miss icons (d=6) when they're clearly the only plausible match.
        if let name = bestName {
            let gap = secondBestDistance - bestDistance
            let effectiveThreshold = gap >= 4 ? threshold + 1 : threshold
            if bestDistance <= effectiveThreshold {
                return IconMatch(iconName: name, heuristic: Self.resolveHeuristic(for: name), distance: bestDistance)
            }
        }
        return nil
    }

}
