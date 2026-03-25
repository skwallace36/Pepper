import UIKit

/// Captures the current key window hierarchy to a CGImage.
///
/// Runs on main thread (UIKit requirement). Returns a raw CGImage
/// with no JPEG encoding — suitable for Vision framework input or
/// any pixel-level processing.
enum PepperWindowCapture {

    /// Captures the full key window at the given scale.
    /// - Parameter scale: Render scale (1.0 = 1x, 2.0 = 2x). Default 1.0.
    /// - Returns: The captured `CGImage`, or `nil` if no key window or rendering fails.
    static func captureWindow(scale: CGFloat = 1.0) -> CGImage? {
        guard let window = UIWindow.pepper_keyWindow else { return nil }
        return captureWindow(window, scale: scale)
    }

    /// Captures a specific window at the given scale.
    /// - Parameters:
    ///   - window: The window to capture.
    ///   - scale: Render scale (1.0 = 1x, 2.0 = 2x). Default 1.0.
    /// - Returns: The captured `CGImage`, or `nil` if rendering fails.
    static func captureWindow(_ window: UIWindow, scale: CGFloat = 1.0) -> CGImage? {
        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        return image.cgImage
    }
}
