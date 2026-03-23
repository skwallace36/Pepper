import UIKit

// MARK: - Capture, Hashing, and Debug

extension PepperIconCatalog {

    /// Identify an icon by extracting its foreground shape via brightness thresholding.
    /// Works for icons on complex backgrounds (maps, gradients) where pixel-level
    /// hashing fails. Captures the region, separates bright/dark foreground from
    /// the background, then hashes the binary silhouette.
    func identifyByThreshold(frame: CGRect, window: UIWindow) -> IconMatch? {
        guard let hash = captureThresholdHash(frame: frame, window: window) else { return nil }
        // Same threshold as normal matching — was 14 (too loose), then 10, then 7.
        // Even threshold 7 produced false positives (nav arrows→next-icon).
        return matchHash(hash, threshold: 5)
    }

    /// Capture a screen region, extract the foreground icon shape via brightness
    /// thresholding, and compute its dHash.
    func captureThresholdHash(frame: CGRect, window: UIWindow) -> Data? {
        // Capture with slight padding to get background context
        let pad: CGFloat = 4
        let captureFrame = frame.insetBy(dx: -pad, dy: -pad)
        let size = 24
        let renderSize = CGSize(width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: renderSize)
        let captured = renderer.image { ctx in
            let sx = renderSize.width / captureFrame.width
            let sy = renderSize.height / captureFrame.height
            ctx.cgContext.scaleBy(x: sx, y: sy)
            ctx.cgContext.translateBy(x: -captureFrame.origin.x, y: -captureFrame.origin.y)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }

        // Convert to grayscale pixels
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: size * size)
        guard
            let ctx = CGContext(
                data: &pixels, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else { return nil }
        UIGraphicsPushContext(ctx)
        captured.draw(in: CGRect(origin: .zero, size: renderSize))
        UIGraphicsPopContext()

        // Compute histogram to find foreground/background
        var brightCount = 0
        var darkCount = 0
        for p in pixels {
            if p > 200 { brightCount += 1 }
            if p < 55 { darkCount += 1 }
        }

        // Skip if no clear foreground-background separation
        let total = size * size
        guard brightCount > total / 10 || darkCount > total / 10 else { return nil }

        // Foreground = extreme pixels (bright icon on dark bg, or dark icon on light bg)
        let isBrightIcon = brightCount > darkCount

        // Create thresholded image: foreground → black, background → white
        // This matches the catalog's dark-on-light rendering
        var thresholded = [UInt8](repeating: 255, count: total)
        for i in 0..<total {
            if isBrightIcon {
                if pixels[i] > 180 { thresholded[i] = 0 }
            } else {
                if pixels[i] < 75 { thresholded[i] = 0 }
            }
        }

        // Convert thresholded pixels to image for dHash
        guard
            let threshCtx = CGContext(
                data: &thresholded, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ), let cgImage = threshCtx.makeImage()
        else { return nil }

        return computeDHash(image: UIImage(cgImage: cgImage))
    }

    /// Capture a screen region and compute its dHash.
    /// Scale > 1.0 expands the capture region (adding context around the icon)
    /// to approximate the catalog's padded rendering.
    func captureAndHash(frame: CGRect, window: UIWindow, scale: CGFloat = 1.0) -> Data? {
        let scaledW = frame.width * scale
        let scaledH = frame.height * scale
        let captureFrame = CGRect(
            x: frame.midX - scaledW / 2,
            y: frame.midY - scaledH / 2,
            width: scaledW,
            height: scaledH
        )

        let renderSize = CGSize(width: 24, height: 24)
        let renderer = UIGraphicsImageRenderer(size: renderSize)
        let image = renderer.image { ctx in
            let scaleX = renderSize.width / captureFrame.width
            let scaleY = renderSize.height / captureFrame.height
            ctx.cgContext.scaleBy(x: scaleX, y: scaleY)
            ctx.cgContext.translateBy(x: -captureFrame.origin.x, y: -captureFrame.origin.y)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }

        return computeDHash(image: image)
    }

    /// Capture a screen region, remove the dominant background via histogram mode,
    /// and compute dHash of the foreground silhouette. Handles icons rendered on
    /// circular/colored backgrounds where the background contaminates standard dHash.
    ///
    /// Unlike `identifyByThreshold` (fixed brightness cutoffs), this uses the actual
    /// dominant color as the reference — correctly handling 3-class images where both
    /// the app background and decorative circle are similar brightness.
    func captureAndHashBgSub(frame: CGRect, window: UIWindow, scale: CGFloat) -> Data? {
        // Same capture as captureAndHash
        let scaledW = frame.width * scale
        let scaledH = frame.height * scale
        let captureFrame = CGRect(
            x: frame.midX - scaledW / 2, y: frame.midY - scaledH / 2,
            width: scaledW, height: scaledH
        )
        let renderSize = CGSize(width: 24, height: 24)
        let renderer = UIGraphicsImageRenderer(size: renderSize)
        let image = renderer.image { ctx in
            let scaleX = renderSize.width / captureFrame.width
            let scaleY = renderSize.height / captureFrame.height
            ctx.cgContext.scaleBy(x: scaleX, y: scaleY)
            ctx.cgContext.translateBy(x: -captureFrame.origin.x, y: -captureFrame.origin.y)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return computeDHashBgSub(image: image)
    }

    /// Compute dHash after removing the dominant background color.
    /// Same pixel extraction pipeline as `computeDHash` (proven to work), but adds
    /// mode-based background subtraction before hash computation.
    ///
    /// Polarity-invariant: both bright-on-dark and dark-on-light icons produce
    /// dark foreground on white background, matching the catalog's rendering.
    func computeDHashBgSub(image: UIImage) -> Data? {
        let w = 13
        let h = 12
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard
            let context = CGContext(
                data: &pixels, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else { return nil }
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(origin: .zero, size: CGSize(width: w, height: h)))
        UIGraphicsPopContext()

        // Histogram mode = dominant background color
        var histogram = [Int](repeating: 0, count: 256)
        for p in pixels { histogram[Int(p)] += 1 }
        guard let maxEntry = histogram.enumerated().max(by: { $0.element < $1.element }) else { return nil }
        let mode = UInt8(maxEntry.offset)

        // Binary: foreground (far from mode) → 0, background (near mode) → 255
        // Threshold 30: captures anti-aliased edges for fuller silhouettes.
        let total = w * h
        for i in 0..<total {
            pixels[i] = abs(Int(pixels[i]) - Int(mode)) > 30 ? 0 : 255
        }

        // Sanity: 5-60% foreground for a meaningful shape
        let fgCount = pixels.filter { $0 == 0 }.count
        guard fgCount > total / 20 && fgCount < total * 3 / 5 else { return nil }

        // Compute dHash from binary pixels (same as computeDHash)
        var hashBytes = [UInt8](repeating: 0, count: 18)
        var bitIndex = 0
        for row in 0..<h {
            for col in 0..<(w - 1) {
                if pixels[row * w + col] > pixels[row * w + col + 1] {
                    hashBytes[bitIndex / 8] |= (1 << (7 - (bitIndex % 8)))
                }
                bitIndex += 1
            }
        }

        // Require minimum 7 bits: low-bit hashes (< 7) match too many simple icons
        // (subtract-icon, close-icon) and produce false positives.
        let bitCount = hashBytes.reduce(0) { $0 + $1.nonzeroBitCount }
        guard bitCount >= 7 else { return nil }

        return Data(hashBytes)
    }

    // MARK: - dHash

    /// Compute a 144-bit difference hash (dHash) from an image.
    /// Resizes to 13x12 grayscale, compares adjacent horizontal pixels.
    /// 12 rows x 12 comparisons = 144 bits = 18 bytes.
    ///
    /// 13x12 is a sweet spot: enough resolution to distinguish similar icons
    /// (like qr-code vs more-horiz), while tolerant of rendering differences.
    func computeDHash(image: UIImage) -> Data? {
        let w = 13
        let h = 12
        let size = CGSize(width: w, height: h)

        // Render to grayscale bitmap
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard
            let context = CGContext(
                data: &pixels, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else { return nil }

        UIGraphicsPushContext(context)
        image.draw(in: CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()

        // Compare adjacent pixels horizontally: left > right → 1, else → 0
        // 12 rows x 12 comparisons = 144 bits = 18 bytes
        var hashBytes = [UInt8](repeating: 0, count: 18)
        var bitIndex = 0

        for row in 0..<h {
            for col in 0..<(w - 1) {
                let left = pixels[row * w + col]
                let right = pixels[row * w + col + 1]
                if left > right {
                    hashBytes[bitIndex / 8] |= (1 << (7 - (bitIndex % 8)))
                }
                bitIndex += 1
            }
        }

        return Data(hashBytes)
    }

    /// Hamming distance between two hashes (count of differing bits).
    func hammingDistance(_ a: Data, _ b: Data) -> Int {
        guard a.count == b.count else { return Int.max }
        var dist = 0
        for i in 0..<a.count {
            var xor = a[i] ^ b[i]
            while xor != 0 {
                dist += 1
                xor &= (xor - 1)  // Clear lowest set bit
            }
        }
        return dist
    }

    // MARK: - Debug Info

    struct CatalogInfo {
        let built: Bool
        let iconCount: Int
        let bundlePath: String?
    }

    func catalogInfo() -> CatalogInfo {
        CatalogInfo(built: built, iconCount: catalog.count, bundlePath: catalogBundle)
    }

    /// Debug: return all catalog hashes for a specific icon name.
    func catalogHashesForIcon(name: String) -> [String: AnyCodable] {
        ensureBuilt()
        var hashes: [[String: AnyCodable]] = []
        for (hash, catName) in catalog where catName == name {
            let hex = hash.map { String(format: "%02x", $0) }.joined()
            hashes.append([
                "hash": AnyCodable(hex),
                "bits_set": AnyCodable(hash.reduce(0) { $0 + $1.nonzeroBitCount }),
            ])
        }
        return [
            "name": AnyCodable(name),
            "hashes": AnyCodable(hashes),
            "count": AnyCodable(hashes.count),
        ]
    }
}
