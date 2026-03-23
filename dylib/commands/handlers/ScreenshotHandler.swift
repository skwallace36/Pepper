import UIKit

/// Handles {"cmd": "screenshot"} — in-process screen capture via UIGraphicsImageRenderer.
///
/// Faster than `xcrun simctl io screenshot` because it renders directly inside the app
/// process with no IPC or temp-file overhead. Supports per-view snapshots by targeting
/// a specific element.
///
/// Params:
///   - element (String, optional): accessibility ID of view to capture
///   - text (String, optional): label text of view to capture
///   - quality (String, optional): "standard" (70% JPEG) or "high" (95% JPEG). Default "standard".
///   - scale (String, optional): "1x" or "2x". Default "1x".
///
/// Returns:
///   - image: base64-encoded JPEG string
///   - width / height: logical dimensions (points)
///   - format: "jpeg"
///   - scope: "fullscreen" | "element"
struct ScreenshotHandler: PepperHandler {
    let commandName = "screenshot"
    let timeout: TimeInterval = 5.0

    func handle(_ command: PepperCommand) -> PepperResponse {
        let qualityStr = command.params?["quality"]?.stringValue ?? "standard"
        let jpegQuality: CGFloat = qualityStr == "high" ? 0.95 : 0.70
        let scaleStr = command.params?["scale"]?.stringValue ?? "1x"
        let renderScale: CGFloat = scaleStr == "2x" ? 2.0 : 1.0

        let hasElement = command.params?["element"]?.stringValue != nil
        let hasText = command.params?["text"]?.stringValue != nil

        if hasElement || hasText {
            return captureElement(command, jpegQuality: jpegQuality, renderScale: renderScale)
        }
        return captureFullScreen(command, jpegQuality: jpegQuality, renderScale: renderScale)
    }

    // MARK: - Full-screen capture

    private func captureFullScreen(
        _ command: PepperCommand,
        jpegQuality: CGFloat,
        renderScale: CGFloat
    ) -> PepperResponse {
        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window")
        }

        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }

        return encodeResponse(
            image: image, command: command, jpegQuality: jpegQuality,
            width: bounds.width, height: bounds.height, scope: "fullscreen"
        )
    }

    // MARK: - Per-element capture

    private func captureElement(
        _ command: PepperCommand,
        jpegQuality: CGFloat,
        renderScale: CGFloat
    ) -> PepperResponse {
        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window")
        }

        let (result, errorMsg) = PepperElementResolver.resolve(params: command.params, in: window)
        guard let resolved = result else {
            return .error(id: command.id, message: errorMsg ?? "Element not found")
        }

        let targetView = resolved.view
        let frameInWindow = targetView.convert(targetView.bounds, to: window)

        // Guard against zero-size views
        guard frameInWindow.width > 0, frameInWindow.height > 0 else {
            return .error(id: command.id, message: "Element has zero size")
        }

        // Render the full window then crop to the element's frame.
        // This is more reliable than rendering the view directly, because
        // drawHierarchy on a subview can miss overlays and transforms.
        let windowBounds = window.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        let renderer = UIGraphicsImageRenderer(bounds: windowBounds, format: format)
        let fullImage = renderer.image { _ in
            window.drawHierarchy(in: windowBounds, afterScreenUpdates: false)
        }

        guard let cgFull = fullImage.cgImage else {
            return .error(id: command.id, message: "Failed to render window")
        }

        // Convert point frame to pixel rect at render scale
        let pixelRect = CGRect(
            x: frameInWindow.origin.x * renderScale,
            y: frameInWindow.origin.y * renderScale,
            width: frameInWindow.width * renderScale,
            height: frameInWindow.height * renderScale
        )

        // Clamp to image bounds
        let imgW = CGFloat(cgFull.width)
        let imgH = CGFloat(cgFull.height)
        let clampedRect = pixelRect.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

        guard !clampedRect.isEmpty else {
            return .error(id: command.id, message: "Element is off-screen")
        }

        guard let cropped = cgFull.cropping(to: clampedRect) else {
            return .error(id: command.id, message: "Failed to crop to element bounds")
        }

        let croppedImage = UIImage(cgImage: cropped, scale: renderScale, orientation: .up)

        return encodeResponse(
            image: croppedImage, command: command, jpegQuality: jpegQuality,
            width: frameInWindow.width, height: frameInWindow.height, scope: "element"
        )
    }

    // MARK: - Encoding

    private func encodeResponse(
        image: UIImage,
        command: PepperCommand,
        jpegQuality: CGFloat,
        width: CGFloat,
        height: CGFloat,
        scope: String
    ) -> PepperResponse {
        guard let jpegData = image.jpegData(compressionQuality: jpegQuality) else {
            return .error(id: command.id, message: "JPEG encoding failed")
        }

        let b64 = jpegData.base64EncodedString()

        return .ok(id: command.id, data: [
            "image": AnyCodable(b64),
            "width": AnyCodable(Int(width)),
            "height": AnyCodable(Int(height)),
            "format": AnyCodable("jpeg"),
            "scope": AnyCodable(scope),
            "size_bytes": AnyCodable(jpegData.count),
        ])
    }
}
